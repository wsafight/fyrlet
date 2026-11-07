//! Compact `delta-v1` patches. Views are never mutated in place: every call returns new
//! containers, and a delivered [`crate::SubscriptionState`] value stays unchanged forever.

use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::fmt;

/// The maximum number of records in a view or patch list.
pub const MAX_ITEMS: usize = 100;

/// A malformed delta patch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidDelta;

impl fmt::Display for InvalidDelta {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid subscription delta")
    }
}

impl std::error::Error for InvalidDelta {}

type DeltaResult<T> = Result<T, InvalidDelta>;

fn record_id(value: &Value) -> DeltaResult<(&str, &Map<String, Value>)> {
    let record = value.as_object().ok_or(InvalidDelta)?;
    let id = record
        .get("id")
        .and_then(Value::as_str)
        .ok_or(InvalidDelta)?;
    Ok((id, record))
}

fn patch_list<'a>(patch: &'a Map<String, Value>, key: &str) -> DeltaResult<Option<&'a Vec<Value>>> {
    match patch.get(key) {
        None => Ok(None),
        Some(value) => {
            let list = value.as_array().ok_or(InvalidDelta)?;
            if list.len() > MAX_ITEMS {
                return Err(InvalidDelta);
            }
            Ok(Some(list))
        }
    }
}

fn parse_change(change: &Value) -> DeltaResult<(String, Map<String, Value>, Vec<String>)> {
    let parts = change.as_array().ok_or(InvalidDelta)?;
    if parts.len() != 2 && parts.len() != 3 {
        return Err(InvalidDelta);
    }
    let id = parts[0].as_str().ok_or(InvalidDelta)?;
    let fields = parts[1].as_object().ok_or(InvalidDelta)?;
    if fields.contains_key("id") {
        return Err(InvalidDelta);
    }
    let mut cleared = Vec::new();
    if parts.len() == 3 {
        let names = parts[2].as_array().ok_or(InvalidDelta)?;
        let mut seen = HashSet::new();
        for name in names {
            let key = name.as_str().ok_or(InvalidDelta)?;
            if key == "id" || fields.contains_key(key) || !seen.insert(key.to_string()) {
                return Err(InvalidDelta);
            }
            cleared.push(key.to_string());
        }
    }
    Ok((id.to_string(), fields.clone(), cleared))
}

fn replace_record(
    previous: &Map<String, Value>,
    fields: &Map<String, Value>,
    cleared: &[String],
) -> Map<String, Value> {
    let mut updated = previous.clone();
    for (key, value) in fields {
        updated.insert(key.clone(), value.clone());
    }
    for key in cleared {
        updated.remove(key);
    }
    updated
}

/// Applies a compact delta-v1 patch to `view` and returns the new view. Assigning a field `null`
/// is different from deleting it through `cleared`.
pub fn apply_delta(view: &Value, patch: &Value) -> DeltaResult<Vec<Value>> {
    let view = view.as_array().ok_or(InvalidDelta)?;
    let patch = patch.as_object().ok_or(InvalidDelta)?;
    if view.len() > MAX_ITEMS {
        return Err(InvalidDelta);
    }
    for key in patch.keys() {
        if !matches!(key.as_str(), "a" | "c" | "r" | "o") {
            return Err(InvalidDelta);
        }
    }

    let mut records: HashMap<String, Value> = HashMap::with_capacity(view.len());
    let mut ids: Vec<String> = Vec::with_capacity(view.len());
    for entry in view {
        let (id, _) = record_id(entry)?;
        if records.contains_key(id) {
            return Err(InvalidDelta);
        }
        records.insert(id.to_string(), entry.clone());
        ids.push(id.to_string());
    }

    let mut touched: HashSet<String> = HashSet::new();
    let mut touch = |id: &str| -> DeltaResult<()> {
        if !touched.insert(id.to_string()) {
            return Err(InvalidDelta);
        }
        Ok(())
    };

    if let Some(removed) = patch_list(patch, "r")? {
        for value in removed {
            let id = value.as_str().ok_or(InvalidDelta)?;
            if !records.contains_key(id) {
                return Err(InvalidDelta);
            }
            touch(id)?;
            records.remove(id);
        }
    }

    if let Some(added) = patch_list(patch, "a")? {
        for value in added {
            let (id, _) = record_id(value)?;
            if records.contains_key(id) {
                return Err(InvalidDelta);
            }
            touch(id)?;
            records.insert(id.to_string(), value.clone());
        }
    }

    if let Some(changes) = patch_list(patch, "c")? {
        for change in changes {
            let (id, fields, cleared) = parse_change(change)?;
            let previous = records
                .get(&id)
                .and_then(Value::as_object)
                .ok_or(InvalidDelta)?;
            touch(&id)?;
            let updated = replace_record(previous, &fields, &cleared);
            records.insert(id, Value::Object(updated));
        }
    }

    let order: Vec<String> = if patch.contains_key("o") {
        let list = patch_list(patch, "o")?.ok_or(InvalidDelta)?;
        let mut order = Vec::with_capacity(list.len());
        for value in list {
            order.push(value.as_str().ok_or(InvalidDelta)?.to_string());
        }
        order
    } else {
        ids
    };

    let mut seen = HashSet::new();
    for id in &order {
        if !records.contains_key(id) || !seen.insert(id.clone()) {
            return Err(InvalidDelta);
        }
    }
    if records.len() > MAX_ITEMS || order.len() != records.len() {
        return Err(InvalidDelta);
    }

    let mut result = Vec::with_capacity(order.len());
    for id in &order {
        result.push(records.remove(id).expect("order was validated"));
    }
    Ok(result)
}
