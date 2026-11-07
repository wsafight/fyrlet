package com.fyrlet;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Compact {@code delta-v1} patches.
 *
 * <p>Views are immutable: every call returns new containers and never modifies the input view. A patch
 * assigns a field with JSON {@code null} to store null; only the {@code cleared} list deletes fields.</p>
 */
final class Delta {

    private static final int MAX_ITEMS = 100;

    private Delta() {
    }

    /**
     * Applies {@code patch} to {@code data}.
     *
     * @param data the current array view
     * @param patch the compact patch
     * @return the new array view, or {@code null} when the patch is invalid
     */
    static JsonElement apply(JsonElement data, JsonElement patch) {
        try {
            return applyOrThrow(data, patch);
        } catch (InvalidDelta ignored) {
            return null;
        }
    }

    private static JsonElement applyOrThrow(JsonElement data, JsonElement patch) {
        if (data == null || !data.isJsonArray() || patch == null || !patch.isJsonObject()) {
            throw InvalidDelta.INSTANCE;
        }
        JsonArray view = data.getAsJsonArray();
        JsonObject changes = patch.getAsJsonObject();
        if (view.size() > MAX_ITEMS) {
            throw InvalidDelta.INSTANCE;
        }
        for (String key : changes.keySet()) {
            if (!key.equals("a") && !key.equals("c") && !key.equals("r") && !key.equals("o")) {
                throw InvalidDelta.INSTANCE;
            }
        }

        Map<String, JsonObject> records = new LinkedHashMap<>();
        List<String> ids = new ArrayList<>(view.size());
        for (JsonElement value : view) {
            JsonObject record = asObject(value);
            String id = record == null ? null : id(record);
            if (id == null || records.putIfAbsent(id, record) != null) {
                throw InvalidDelta.INSTANCE;
            }
            ids.add(id);
        }

        Set<String> touched = new LinkedHashSet<>();

        JsonArray removed = list(changes, "r");
        if (removed != null) {
            for (JsonElement value : removed) {
                if (!Json.isString(value)) {
                    throw InvalidDelta.INSTANCE;
                }
                String id = value.getAsString();
                if (records.remove(id) == null) {
                    throw InvalidDelta.INSTANCE;
                }
                touch(touched, id);
            }
        }

        JsonArray added = list(changes, "a");
        if (added != null) {
            for (JsonElement value : added) {
                JsonObject record = asObject(value);
                String id = record == null ? null : id(record);
                if (id == null || records.containsKey(id)) {
                    throw InvalidDelta.INSTANCE;
                }
                touch(touched, id);
                records.put(id, record);
            }
        }

        JsonArray updates = list(changes, "c");
        if (updates != null) {
            for (JsonElement change : updates) {
                if (change == null || !change.isJsonArray()) {
                    throw InvalidDelta.INSTANCE;
                }
                JsonArray parts = change.getAsJsonArray();
                if ((parts.size() != 2 && parts.size() != 3) || !Json.isString(parts.get(0))) {
                    throw InvalidDelta.INSTANCE;
                }
                JsonObject fields = asObject(parts.get(1));
                if (fields == null || fields.has("id")) {
                    throw InvalidDelta.INSTANCE;
                }
                String id = parts.get(0).getAsString();
                JsonObject previous = records.get(id);
                if (previous == null) {
                    throw InvalidDelta.INSTANCE;
                }
                touch(touched, id);

                List<String> cleared = new ArrayList<>();
                if (parts.size() == 3) {
                    JsonElement rawCleared = parts.get(2);
                    if (rawCleared == null || !rawCleared.isJsonArray()) {
                        throw InvalidDelta.INSTANCE;
                    }
                    Set<String> seen = new LinkedHashSet<>();
                    for (JsonElement name : rawCleared.getAsJsonArray()) {
                        if (!Json.isString(name)) {
                            throw InvalidDelta.INSTANCE;
                        }
                        String key = name.getAsString();
                        if (key.equals("id") || fields.has(key) || !seen.add(key)) {
                            throw InvalidDelta.INSTANCE;
                        }
                        cleared.add(key);
                    }
                }
                records.put(id, replaceRecord(previous, fields, cleared));
            }
        }

        List<String> order;
        if (changes.has("o")) {
            JsonArray explicitOrder = list(changes, "o");
            if (explicitOrder == null) {
                throw InvalidDelta.INSTANCE;
            }
            order = new ArrayList<>(explicitOrder.size());
            for (JsonElement value : explicitOrder) {
                if (!Json.isString(value)) {
                    throw InvalidDelta.INSTANCE;
                }
                order.add(value.getAsString());
            }
        } else {
            order = ids;
        }

        Set<String> seen = new LinkedHashSet<>();
        for (String id : order) {
            if (!records.containsKey(id) || !seen.add(id)) {
                throw InvalidDelta.INSTANCE;
            }
        }
        if (records.size() > MAX_ITEMS || order.size() != records.size()) {
            throw InvalidDelta.INSTANCE;
        }

        JsonArray result = new JsonArray(order.size());
        for (String id : order) {
            result.add(records.get(id));
        }
        return result;
    }

    private static JsonArray list(JsonObject patch, String key) {
        JsonElement value = patch.get(key);
        if (value == null) {
            return null;
        }
        if (!value.isJsonArray() || value.getAsJsonArray().size() > MAX_ITEMS) {
            throw InvalidDelta.INSTANCE;
        }
        return value.getAsJsonArray();
    }

    private static JsonObject asObject(JsonElement value) {
        return value != null && value.isJsonObject() ? value.getAsJsonObject() : null;
    }

    private static String id(JsonObject record) {
        JsonElement id = record.get("id");
        return Json.isString(id) ? id.getAsString() : null;
    }

    private static void touch(Set<String> touched, String id) {
        if (!touched.add(id)) {
            throw InvalidDelta.INSTANCE;
        }
    }

    private static JsonObject replaceRecord(JsonObject previous, JsonObject fields, List<String> cleared) {
        JsonObject updated = new JsonObject();
        for (Map.Entry<String, JsonElement> entry : previous.entrySet()) {
            updated.add(entry.getKey(), entry.getValue());
        }
        for (Map.Entry<String, JsonElement> entry : fields.entrySet()) {
            updated.add(entry.getKey(), entry.getValue());
        }
        for (String key : cleared) {
            updated.remove(key);
        }
        return updated;
    }

    /** Internal marker for an invalid patch. */
    private static final class InvalidDelta extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private static final InvalidDelta INSTANCE = new InvalidDelta();

        private InvalidDelta() {
            super(null, null, false, false);
        }
    }
}
