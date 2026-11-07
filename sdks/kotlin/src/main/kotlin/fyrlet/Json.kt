package fyrlet

import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive

/** Shared Gson instance and small JSON accessors used by the SDK. */
internal object FyrletJson {
    val gson: Gson = Gson()
}

/** Returns the string value, or null when the element is absent, null or not a JSON string. */
internal fun JsonElement?.stringOrNull(): String? =
    if (this != null && isJsonPrimitive && asJsonPrimitive.isString) asString else null

/** Returns the member as a string, or null when it is absent, null or not a JSON string. */
internal fun JsonObject.stringOrNull(name: String): String? = get(name).stringOrNull()

/**
 * Returns the member as a JavaScript-safe integer, matching the protocol's integer restriction.
 * Fractions, non-numbers and values beyond 2^53 are rejected.
 */
internal fun JsonElement?.longOrNull(): Long? {
    if (this == null || !isJsonPrimitive) return null
    val primitive: JsonPrimitive = asJsonPrimitive
    if (!primitive.isNumber) return null
    val number = try {
        primitive.asDouble
    } catch (_: NumberFormatException) {
        return null
    }
    if (!number.isFinite() || number != Math.floor(number) || Math.abs(number) > MAX_SAFE_INTEGER) return null
    return number.toLong()
}

internal fun JsonObject.longOrNull(name: String): Long? = get(name).longOrNull()

private const val MAX_SAFE_INTEGER = 9_007_199_254_740_992.0 // 2^53
