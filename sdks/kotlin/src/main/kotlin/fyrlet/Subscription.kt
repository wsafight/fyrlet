package fyrlet

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.reflect.TypeToken
import java.lang.reflect.Type
import java.util.concurrent.ScheduledFuture

/** The lifecycle of a subscription. */
enum class SubscriptionStatus(val wire: String) {
    /** The initial connection. */
    CONNECTING("connecting"),

    /** The subscription holds a current snapshot. */
    READY("ready"),

    /** The previous data is retained while the connection is rebuilt. */
    RECOVERING("recovering"),

    /** Terminal: data is cleared and [SubscriptionState.error] explains why. */
    ERROR("error"),

    /** Terminal: the subscription or client was closed. */
    CLOSED("closed"),
}

/** The project and user a client is bound to. */
internal data class Identity(val projectId: String, val subjectId: String)

/**
 * What a subscription listener sees.
 *
 * [data] is decoded JSON and must be treated as read-only: a later delta creates new containers and never
 * modifies a value that was already delivered. It is retained while the subscription is
 * [SubscriptionStatus.RECOVERING] and cleared on [SubscriptionStatus.ERROR] and [SubscriptionStatus.CLOSED].
 */
data class SubscriptionState(
    val status: SubscriptionStatus = SubscriptionStatus.CONNECTING,
    val data: JsonElement? = null,
    val error: ApiException? = null,
    val generation: String? = null,
    val seq: Long = 0,
) {
    /**
     * Copies [data] into your own type. Typically `state.decode<List<Item>>()`.
     */
    fun <T> decode(type: Type): T? = data?.let { FyrletJson.gson.fromJson(it, type) }
}

/**
 * Copies [data] into [T]. For example `state.decode<List<Item>>()`.
 */
inline fun <reified T> SubscriptionState.decode(): T? =
    decode(object : TypeToken<T>() {}.type)

/** Internal outcome of applying a snapshot or delta. */
internal sealed interface ApplyResult {
    /** Acknowledge this generation and sequence number. */
    data class Ack(val generation: String, val seq: Long) : ApplyResult

    /** The delta sequence has a gap: the connection must be rebuilt and rejoined. */
    data object Reconnect : ApplyResult
}

/** One retained subscription. All mutable fields are guarded by the client lock. */
internal class Entry(
    val id: String,
    val name: String,
    val params: JsonElement,
    val wantDelta: Boolean,
) {
    val topic: String get() = "subscription:$id"

    var state: SubscriptionState = SubscriptionState()
    var listeners: MutableMap<Int, (SubscriptionState) -> Unit> = LinkedHashMap()
    var nextListener: Int = 0
    var connection: Connection? = null
    var joinFailures: Int = 0
    var delta: Boolean = false
    var rejoin: ScheduledFuture<*>? = null

    /**
     * Validates and applies a full snapshot. Returns the ack to send, or null when the snapshot belongs to an
     * older generation of the current join.
     */
    fun applySnapshot(payload: JsonObject?, identity: Identity?, initial: Boolean): ApplyResult.Ack? {
        val generation = payload?.stringOrNull("generation")
        val subscriptionId = payload?.stringOrNull("subscription_id")
        val projectId = payload?.stringOrNull("project_id")
        val subjectId = payload?.stringOrNull("subject_id")
        val seq = payload?.longOrNull("seq")
        val version = payload?.longOrNull("protocol_version")
        if (payload == null || version != PROTOCOL_VERSION || subscriptionId != id || identity == null ||
            projectId != identity.projectId || subjectId != identity.subjectId ||
            generation == null || seq == null || seq < 1 || !payload.has("data")
        ) {
            throw apiError("PROTOCOL_ERROR", "Invalid subscription snapshot")
        }
        if (!initial && generation != (state.generation ?: "")) return null
        if (initial) delta = payload.stringOrNull("delivery") == "delta-v1"
        if (initial || seq > state.seq) {
            state = SubscriptionState(
                status = SubscriptionStatus.READY,
                data = payload.get("data")?.takeUnless { it.isJsonNull },
                generation = generation,
                seq = seq,
            )
        }
        return ApplyResult.Ack(generation, seq)
    }

    /**
     * Applies a `delta-v1` patch. Returns null for an old generation, the ack to resend for a duplicate, or
     * [ApplyResult.Reconnect] on a sequence gap.
     */
    fun applyDelta(payload: JsonObject?): ApplyResult? {
        if (payload == null) return null
        val generation = payload.stringOrNull("g") ?: return null
        if (generation != (state.generation ?: "")) return null
        val seq = payload.longOrNull("s")
        val base = payload.longOrNull("b")
        if (!delta || seq == null || base == null || seq < 2 || base < 1 || seq != base + 1) {
            throw apiError("PROTOCOL_ERROR", "Invalid subscription delta sequence")
        }
        if (seq <= state.seq) return ApplyResult.Ack(generation, seq)
        if (base != state.seq) return ApplyResult.Reconnect
        val patch = payload.get("p")
        val data = Delta.apply(state.data, patch)
            ?: throw apiError("PROTOCOL_ERROR", "Invalid subscription delta")
        state = SubscriptionState(
            status = SubscriptionStatus.READY,
            data = data,
            generation = generation,
            seq = seq,
        )
        return ApplyResult.Ack(generation, seq)
    }

    companion object {
        const val PROTOCOL_VERSION = 1L
    }
}

/**
 * A handle to one realtime subscription. All methods are safe for concurrent use.
 */
class Subscription internal constructor(
    private val client: FyrletClient,
    internal val entry: Entry,
) {
    /** The current state; [SubscriptionState.data] is retained while recovering. */
    val state: SubscriptionState get() = client.subscriptionState(entry)

    /**
     * Registers a listener. It receives the current state first and then every change, serially on a dedicated
     * thread, so it may call back into the client. Listener exceptions are reported through
     * [FyrletOptions.onListenerError] and never break the client.
     *
     * @return a function that removes this listener.
     */
    fun onChange(listener: (SubscriptionState) -> Unit): () -> Unit = client.addListener(entry, listener)

    /** Alias for [onChange], matching the naming used by the other Fyrlet SDKs. */
    fun on_change(listener: (SubscriptionState) -> Unit): () -> Unit = onChange(listener)

    /**
     * Asks the server for a fresh snapshot. Returns once the server accepted the request; the data itself
     * arrives through [onChange].
     */
    fun refresh() = client.refreshSubscription(entry)

    /** Ends this subscription. Safe to call more than once. */
    fun unsubscribe() = client.unsubscribe(entry)
}
