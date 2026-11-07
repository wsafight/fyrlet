package fyrlet

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject

/**
 * Compact `delta-v1` patches. Views are immutable: applying a patch never mutates the input and always
 * returns new containers for changed records.
 */
internal object Delta {
    private const val MAX_ITEMS = 100
    private val PATCH_KEYS = setOf("a", "c", "r", "o")

    /**
     * Applies [patch] to [data] and returns the resulting array, or null when the patch is invalid.
     * A null [data] or a non-array view is invalid.
     */
    fun apply(data: JsonElement?, patch: JsonElement?): JsonArray? {
        if (data == null || patch == null || !data.isJsonArray || !patch.isJsonObject) return null
        val view = data.asJsonArray
        val changes = patch.asJsonObject
        if (view.size() > MAX_ITEMS) return null
        for (key in changes.keySet()) if (key !in PATCH_KEYS) return null

        val records = LinkedHashMap<String, JsonObject>()
        val ids = ArrayList<String>(view.size())
        for (entry in view) {
            val id = recordId(entry) ?: return null
            if (records.putIfAbsent(id, entry.asJsonObject) != null) return null
            ids.add(id)
        }

        val touched = HashSet<String>()
        fun touch(id: String): Boolean = touched.add(id)

        val removed = patchList(changes, "r") ?: return null
        for (value in removed) {
            val id = value.stringOrNull() ?: return null
            if (!records.containsKey(id) || !touch(id)) return null
            records.remove(id)
        }

        val added = patchList(changes, "a") ?: return null
        for (value in added) {
            val id = recordId(value) ?: return null
            if (records.containsKey(id) || !touch(id)) return null
            records[id] = value.asJsonObject
        }

        val updates = patchList(changes, "c") ?: return null
        for (change in updates) {
            if (!change.isJsonArray) return null
            val parts = change.asJsonArray
            if (parts.size() != 2 && parts.size() != 3) return null
            val id = parts[0].stringOrNull() ?: return null
            if (!parts[1].isJsonObject) return null
            val fields = parts[1].asJsonObject
            if (fields.has("id")) return null
            val previous = records[id] ?: return null
            if (!touch(id)) return null
            val cleared = ArrayList<String>()
            if (parts.size() == 3) {
                if (!parts[2].isJsonArray) return null
                for (name in parts[2].asJsonArray) {
                    val key = name.stringOrNull() ?: return null
                    if (key == "id" || fields.has(key) || cleared.contains(key)) return null
                    cleared.add(key)
                }
            }
            val updated = JsonObject()
            for ((key, value) in previous.entrySet()) updated.add(key, value)
            for ((key, value) in fields.entrySet()) updated.add(key, value)
            for (key in cleared) updated.remove(key)
            records[id] = updated
        }

        val order: List<String>
        if (changes.has("o")) {
            val explicit = patchList(changes, "o") ?: return null
            val list = ArrayList<String>(explicit.size)
            for (value in explicit) list.add(value.stringOrNull() ?: return null)
            order = list
        } else {
            order = ids
        }

        val seen = HashSet<String>(order.size)
        for (id in order) {
            if (!records.containsKey(id) || !seen.add(id)) return null
        }
        if (records.size > MAX_ITEMS || order.size != records.size) return null

        val result = JsonArray(order.size)
        for (id in order) result.add(records.getValue(id))
        return result
    }

    private fun recordId(value: JsonElement): String? {
        if (!value.isJsonObject) return null
        return value.asJsonObject.stringOrNull("id")
    }

    /** Returns the named patch list; an absent key yields an empty list, an invalid value yields null. */
    private fun patchList(patch: JsonObject, key: String): List<JsonElement>? {
        if (!patch.has(key)) return emptyList()
        val value = patch.get(key)
        if (value == null || !value.isJsonArray) return null
        val array = value.asJsonArray
        if (array.size() > MAX_ITEMS) return null
        return array.toList()
    }
}
