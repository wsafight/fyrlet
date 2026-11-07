"""Compact ``delta-v1`` patches. Views are never mutated in place: every call returns new containers."""

from __future__ import annotations

from typing import Any

MAX_ITEMS = 100


class InvalidDelta(ValueError):
    pass


def _record(value: Any) -> bool:
    return isinstance(value, dict) and isinstance(value.get("id"), str)


def _array(patch: dict[str, Any], key: str) -> list[Any]:
    value = patch.get(key, [])
    if not isinstance(value, list) or len(value) > MAX_ITEMS:
        raise InvalidDelta(key)
    return value


def _parse_change(change: Any) -> tuple[str, dict[str, Any], list[str]]:
    if not isinstance(change, list) or len(change) not in (2, 3) or not isinstance(change[0], str) \
            or not isinstance(change[1], dict) or "id" in change[1]:
        raise InvalidDelta("change")
    cleared = change[2] if len(change) == 3 else []
    if not isinstance(cleared, list) or len(set(cleared)) != len(cleared) or not all(
        isinstance(key, str) and key != "id" and key not in change[1] for key in cleared
    ):
        raise InvalidDelta("change")
    return change[0], change[1], cleared


def _replace(previous: dict[str, Any], fields: dict[str, Any], cleared: list[str]) -> dict[str, Any]:
    updated = {**previous, **fields}
    for key in cleared:
        updated.pop(key, None)
    return updated


def apply_delta(data: Any, patch: Any) -> list[dict[str, Any]]:
    if not isinstance(data, list) or len(data) > MAX_ITEMS or not isinstance(patch, dict) \
            or any(key not in ("a", "c", "r", "o") for key in patch):
        raise InvalidDelta("patch")
    records: dict[str, dict[str, Any]] = {}
    for entry in data:
        if not _record(entry) or entry["id"] in records:
            raise InvalidDelta("view")
        records[entry["id"]] = entry
    touched: set[str] = set()

    def touch(identifier: str) -> None:
        if identifier in touched:
            raise InvalidDelta("duplicate")
        touched.add(identifier)

    for identifier in _array(patch, "r"):
        if not isinstance(identifier, str) or identifier not in records:
            raise InvalidDelta("remove")
        touch(identifier)
        del records[identifier]
    for added in _array(patch, "a"):
        if not _record(added) or added["id"] in records:
            raise InvalidDelta("add")
        touch(added["id"])
        records[added["id"]] = added
    for change in _array(patch, "c"):
        identifier, fields, cleared = _parse_change(change)
        if identifier not in records:
            raise InvalidDelta("change")
        touch(identifier)
        records[identifier] = _replace(records[identifier], fields, cleared)
    order = _array(patch, "o") if "o" in patch else [entry["id"] for entry in data]
    if len(records) > MAX_ITEMS or len(order) != len(records) or len(set(order)) != len(order) \
            or not all(isinstance(identifier, str) and identifier in records for identifier in order):
        raise InvalidDelta("order")
    return [records[identifier] for identifier in order]
