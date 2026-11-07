package fyrlet

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParseException
import com.google.gson.JsonParser
import java.nio.charset.StandardCharsets
import java.util.Base64

/** One Phoenix v2 transport frame. */
internal data class Frame(
    val joinRef: String?,
    val ref: String?,
    val topic: String,
    val event: String,
    val payload: JsonObject,
)

/** The Phoenix v2 JSON wire format, including the outbound `{"batch":[...]}` wrapper. */
internal object Wire {
    const val MAX_BATCH = 64
    const val MAX_MESSAGE_BYTES = 4 * 1024 * 1024

    /**
     * Decodes one frame or a batch wrapper, validating the whole message before any member is dispatched.
     * Returns null for an empty batch, an oversized batch, an extra wrapper key or any malformed member.
     */
    fun decodeFrames(raw: String): List<Frame>? {
        val root = try {
            JsonParser.parseString(raw)
        } catch (_: JsonParseException) {
            return null
        }
        val members: List<JsonElement>
        if (root.isJsonObject) {
            val wrapper = root.asJsonObject
            if (wrapper.size() != 1 || !wrapper.has("batch")) return null
            val batch = wrapper.get("batch")
            if (!batch.isJsonArray) return null
            members = batch.asJsonArray.toList()
        } else {
            members = listOf(root)
        }
        if (members.isEmpty() || members.size > MAX_BATCH) return null

        val frames = ArrayList<Frame>(members.size)
        for (member in members) {
            if (!member.isJsonArray) return null
            val parts = member.asJsonArray
            if (parts.size() != 5) return null
            val joinRef = optionalRef(parts[0]) ?: return null
            val ref = optionalRef(parts[1]) ?: return null
            val topic = parts[2].stringOrNull() ?: return null
            val event = parts[3].stringOrNull() ?: return null
            if (!parts[4].isJsonObject) return null
            frames.add(Frame(joinRef.value, ref.value, topic, event, parts[4].asJsonObject))
        }
        return frames
    }

    /** Returns `ws(s)://host/socket/websocket?project_id=...&vsn=2.0.0`. */
    fun socketUrl(endpoint: String, projectId: String): String =
        "ws" + endpoint.removePrefix("http") + "/socket/websocket?project_id=" +
            FyrletHttp.queryEscape(projectId) + "&vsn=2.0.0"

    /** Encodes the user token exactly as the Phoenix JS `authToken` option does. */
    fun authProtocol(token: String): String =
        "base64url.bearer.phx." + Base64.getUrlEncoder().withoutPadding()
            .encodeToString(token.toByteArray(StandardCharsets.UTF_8))

    /** Builds a five-element Phoenix frame array. The payload must be a non-null object. */
    fun frame(joinRef: String?, ref: String?, topic: String, event: String, payload: JsonElement): JsonArray {
        val array = JsonArray(5)
        array.add(joinRef?.let { com.google.gson.JsonPrimitive(it) } ?: JsonNull.INSTANCE)
        array.add(ref?.let { com.google.gson.JsonPrimitive(it) } ?: JsonNull.INSTANCE)
        array.add(topic)
        array.add(event)
        array.add(payload)
        return array
    }

    /** Wraps a parsed ref: null (valid) or a string. Returns null when the value is neither. */
    private fun optionalRef(value: JsonElement): RefResult? {
        if (value.isJsonNull) return RefResult(null)
        val text = value.stringOrNull() ?: return null
        return RefResult(text)
    }

    private class RefResult(val value: String?)
}
