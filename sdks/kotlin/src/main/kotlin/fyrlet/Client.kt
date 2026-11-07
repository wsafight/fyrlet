package fyrlet

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.reflect.TypeToken
import java.lang.reflect.Type
import java.net.http.HttpClient
import java.time.Duration
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.DelayQueue
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern

/** Outcomes of an operation. */
enum class MutationStatus(val wire: String) {
    /** A successful read. */
    COMPLETED("completed"),

    /** A write committed to the database. */
    COMMITTED("committed"),

    /** A Run or ingest request was durably accepted for later execution. */
    ACCEPTED("accepted"),

    /** A definite failure: nothing was written. */
    FAILED("failed"),

    /** The write was dispatched but its result was not seen. Use [Mutation.recover]. */
    UNKNOWN("unknown"),
    ;

    companion object {
        /** Maps a wire outcome to a status, or null when the outcome is not a success outcome. */
        fun fromWire(value: String?): MutationStatus? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * A snapshot of a [Mutation].
 *
 * @property data the business result for a successful status.
 * @property error the failure for [MutationStatus.FAILED] and the [OutcomeUnknownException] for
 *   [MutationStatus.UNKNOWN].
 */
data class MutationState(
    val status: MutationStatus,
    val data: JsonElement? = null,
    val error: ApiException? = null,
)

/** A stored receipt: [MutationStatus.COMMITTED] or [MutationStatus.ACCEPTED] with the original data, or unknown. */
data class RecoveryResult(
    val status: MutationStatus,
    val data: JsonElement? = null,
)

/**
 * Keeps the outcome of one operation so an unknown result can be recovered later. Safe for concurrent use.
 *
 * @property idempotencyKey the key that identifies this operation to the server.
 */
class Mutation internal constructor(
    val idempotencyKey: String,
    initialState: MutationState,
    private val lookup: () -> RecoveryResult,
) {
    private val lock = Any()
    private var current = initialState

    /** The current outcome. */
    val state: MutationState get() = synchronized(lock) { current }

    /**
     * Returns the business result, or throws the original error. An unknown outcome throws
     * [OutcomeUnknownException]; call [recover] before deciding to submit the write again.
     */
    fun result(): JsonElement {
        val snapshot = state
        return when (snapshot.status) {
            MutationStatus.COMPLETED, MutationStatus.COMMITTED, MutationStatus.ACCEPTED ->
                snapshot.data ?: throw apiError("PROTOCOL_ERROR", "The operation has no result")

            else -> throw snapshot.error ?: apiError("PROTOCOL_ERROR", "The operation has no result")
        }
    }

    /**
     * Queries the stored receipt of an unknown write without executing it again. A terminal handle returns its
     * existing state without querying; a recovery failure leaves the unknown state in place and is rethrown.
     */
    fun recover(): MutationState {
        synchronized(lock) {
            if (current.status != MutationStatus.UNKNOWN) return current
            val found = lookup()
            if (found.status != MutationStatus.UNKNOWN) current = MutationState(found.status, found.data)
            return current
        }
    }
}

/**
 * Configuration for a [FyrletClient].
 *
 * @property endpoint the HTTP(S) base URL of the Fyrlet server.
 * @property projectId the project this client is bound to.
 * @property getToken returns a short-lived user session token (`rts_...`). With `forceRefresh` set,
 *   revalidate the host login and obtain a new session, or throw [ApiException] with code `UNAUTHENTICATED`
 *   to stop recovery.
 * @property timeout bounds each HTTP request and socket reply. Default 10 seconds.
 * @property retryDelay returns the backoff before reconnect attempt n (1-based). Default: 250 ms doubling to 30 s.
 * @property delta request `delta-v1` field deltas. Disable to receive full snapshots only.
 * @property capabilities optional capabilities to negotiate, as name to version.
 * @property newId generates idempotency keys and subscription IDs. Default: random UUIDs.
 * @property onListenerError receives exceptions thrown by [Subscription.onChange] listeners.
 * @property httpClient overrides the HTTP client used for requests and sockets. It must not follow redirects.
 */
class FyrletOptions @JvmOverloads constructor(
    val endpoint: String,
    val projectId: String,
    val getToken: (forceRefresh: Boolean) -> String,
    val timeout: Duration = Duration.ofSeconds(10),
    val retryDelay: ((attempt: Int) -> Duration)? = null,
    val delta: Boolean = true,
    val capabilities: Map<String, Int> = emptyMap(),
    val newId: () -> String = { UUID.randomUUID().toString() },
    val onListenerError: ((Throwable) -> Unit)? = null,
    val httpClient: HttpClient? = null,
)

/**
 * A client bound to one project and one user. It is safe for concurrent use.
 *
 * The client owns a background timer, a listener dispatcher thread and (unless [FyrletOptions.httpClient] is
 * supplied) an HTTP executor. Call [close] to release them. The client cannot be reused after closing.
 */
class FyrletClient(options: FyrletOptions) : AutoCloseable {
    private val options: FyrletOptions = options
    private val endpoint: String = FyrletHttp.endpointUrl(options.endpoint)
    private val timeout: Duration =
        if (options.timeout.isZero || options.timeout.isNegative) Duration.ofSeconds(10) else options.timeout
    private val declared: Map<String, Int> = LinkedHashMap(options.capabilities)
    private val newId: () -> String = options.newId

    init {
        require(options.projectId.isNotEmpty()) { "fyrlet: ProjectId is required" }
        for ((name, version) in options.capabilities) {
            require(CAPABILITY_NAME.matcher(name).matches() && version >= 1) {
                "fyrlet: capabilities must be names with a positive integer version"
            }
        }
    }

    private val ownedHttpExecutor: ExecutorService? =
        if (options.httpClient == null) Executors.newCachedThreadPool(daemonFactory("fyrlet-http")) else null
    private val httpClient: HttpClient =
        options.httpClient ?: HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NEVER)
            .connectTimeout(timeout)
            .executor(ownedHttpExecutor!!)
            .build()

    private val scheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor(daemonFactory("fyrlet-timer"))
    private val background: ExecutorService = Executors.newCachedThreadPool(daemonFactory("fyrlet-worker"))

    private val listenerQueue = LinkedBlockingQueue<Any>()
    private val listenerLock = Any()
    private var listenerStopped = false
    private val listenerThread = Thread({ drainListeners() }, "fyrlet-listeners").apply {
        isDaemon = true
        start()
    }
    private val stopMarker = Any()

    private val lock = Any()
    private val tokenLock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private var connection: Connection? = null
    private var identity: Identity? = null
    private var token: String? = null
    private var epoch: Int = 0
    private var connectingEpoch: Int = -1
    private var retries: Int = 0
    private var retryTimer: ScheduledFuture<*>? = null
    private var closed: Boolean = false

    // ---- operations ----------------------------------------------------------------------------

    /**
     * Runs an operation and returns its business result.
     *
     * The SDK generates an idempotency key. After a network interruption the outcome of a write is unknown and
     * the thrown [OutcomeUnknownException] carries the key for [recover]. Reuse that key explicitly if you
     * decide to submit the write again.
     */
    fun call(name: String, input: JsonElement? = null, idempotencyKey: String? = null): JsonElement =
        mutate(name, input, idempotencyKey).result()

    /**
     * Like [call], decoding the result into [T]. Typically `callInto<List<Item>>("inbox.history")`.
     */
    inline fun <reified T> callInto(
        name: String,
        input: JsonElement? = null,
        idempotencyKey: String? = null,
    ): T? = callInto(name, input, idempotencyKey, object : TypeToken<T>() {}.type)

    /** Like [call], decoding the result into a Java [Type]. */
    fun <T> callInto(name: String, input: JsonElement?, idempotencyKey: String?, type: Type): T? =
        FyrletJson.gson.fromJson(call(name, input, idempotencyKey), type)

    /**
     * Like [call] but never throws for a failed operation: inspect the returned [Mutation].
     *
     * An explicit [idempotencyKey] is reused for the authentication retry and for recovery.
     */
    fun mutate(name: String, input: JsonElement? = null, idempotencyKey: String? = null): Mutation {
        val key = idempotencyKey ?: newId()
        val body = JsonObject().apply { add("input", input ?: JsonObject()) }
        val lookup: () -> RecoveryResult = { recoverReceipt(name, body, key) }
        synchronized(lock) {
            if (closed) return Mutation(key, MutationState(MutationStatus.FAILED, error = closedError()), lookup)
        }

        var sent = false
        return try {
            val envelope = execute { token ->
                sent = true
                try {
                    request("POST", operationPath(name), token, body, key)
                } catch (error: ApiException) {
                    // A definite rejection: nothing was written.
                    if (error.status in 400..499 && error.code != "PROTOCOL_ERROR" && error.code != "HTTP_ERROR") {
                        sent = false
                    }
                    throw error
                }
            }
            val status = MutationStatus.fromWire(envelope.outcome)
            if (status == null || status !in SUCCESS_STATUSES) {
                throw apiError("PROTOCOL_ERROR", "Invalid operation outcome")
            }
            Mutation(key, MutationState(status, envelope.data), lookup)
        } catch (error: Throwable) {
            val api = asApiException(error)
            if (sent) {
                Mutation(
                    key,
                    MutationState(MutationStatus.UNKNOWN, error = OutcomeUnknownException(name, key, api)),
                    lookup,
                )
            } else {
                Mutation(key, MutationState(MutationStatus.FAILED, error = api), lookup)
            }
        }
    }

    /** Looks up the stored receipt of a write without executing it. */
    fun recover(name: String, input: JsonElement? = null, idempotencyKey: String): RecoveryResult {
        assertOpen()
        val body = JsonObject().apply { add("input", input ?: JsonObject()) }
        return recoverReceipt(name, body, idempotencyKey)
    }

    /** The business contract this server exports. */
    fun contract(): JsonElement =
        execute { token -> request("GET", "/api/v1/contract", token, null, null) }.data

    private fun recoverReceipt(name: String, body: JsonObject, key: String): RecoveryResult {
        val envelope = execute { token -> request("POST", operationPath(name) + "/recover", token, body, key) }
        return when (envelope.outcome) {
            "unknown" -> {
                if (envelope.data.isJsonNull) RecoveryResult(MutationStatus.UNKNOWN)
                else throw apiError("PROTOCOL_ERROR", "Invalid recovery outcome")
            }

            "committed" -> RecoveryResult(MutationStatus.COMMITTED, envelope.data)
            "accepted" -> RecoveryResult(MutationStatus.ACCEPTED, envelope.data)
            else -> throw apiError("PROTOCOL_ERROR", "Invalid recovery outcome")
        }
    }

    private fun operationPath(name: String): String = "/api/v1/operations/" + FyrletHttp.pathEscape(name)

    /** Performs one authenticated HTTP request bounded by [FyrletOptions.timeout]. */
    private fun request(
        method: String,
        path: String,
        token: String,
        body: JsonElement?,
        key: String?,
    ): Envelope {
        val headers = LinkedHashMap<String, String>()
        headers["authorization"] = "Bearer $token"
        headers["x-project-id"] = options.projectId
        if (key != null) headers["idempotency-key"] = key
        if (declared.isNotEmpty()) {
            headers["x-fyrlet-capabilities"] = declared.entries
                .sortedBy { it.key }
                .joinToString(", ") { "${it.key}=${it.value}" }
        }
        return FyrletHttp.send(httpClient, method, endpoint + path, headers, body, timeout)
    }

    /**
     * Authorizes, runs [perform] and refreshes the token at most once after an authentication failure, reusing
     * the caller's serialized body and idempotency key.
     */
    private fun execute(perform: (String) -> Envelope): Envelope {
        val token = try {
            authorize(false, null)
        } catch (error: Throwable) {
            throw authFailure(asApiException(error))
        }
        val result = try {
            perform(token)
        } catch (first: Throwable) {
            val api = asApiException(first)
            if (api.status != 401 && api.code != "UNAUTHENTICATED") throw authFailure(api)
            assertOpen()
            val fresh = try {
                authorize(true, token)
            } catch (error: Throwable) {
                throw authFailure(asApiException(error))
            }
            try {
                perform(fresh)
            } catch (error: Throwable) {
                throw authFailure(asApiException(error))
            }
        }
        return result
    }

    private fun authFailure(error: ApiException): ApiException {
        if (error.code == "UNAUTHENTICATED" || error.code == "FORBIDDEN") failAll(error)
        return error
    }

    private fun authorize(force: Boolean, stale: String?): String = synchronized(tokenLock) {
        val current = synchronized(lock) {
            if (closed) throw closedError()
            token
        }
        // Another caller already refreshed past the token this one failed with.
        if (current != null && (!force || (stale != null && current != stale))) return current

        var fresh = userToken(force)
        var found = try {
            identityFor(fresh)
        } catch (error: ApiException) {
            if (!force && error.status == 401) {
                fresh = userToken(true)
                identityFor(fresh)
            } else {
                throw error
            }
        }
        synchronized(lock) {
            if (closed) throw closedError()
            val known = identity
            if (found.projectId != options.projectId || (known != null && found.subjectId != known.subjectId)) {
                throw ApiException("FORBIDDEN", "Create a new client when changing accounts")
            }
            identity = found
            token = fresh
            fresh
        }
    }

    private fun userToken(force: Boolean): String {
        val value = try {
            options.getToken(force)
        } catch (error: Throwable) {
            throw asApiException(error)
        }
        assertOpen()
        if (!value.startsWith("rts_")) {
            throw ApiException("UNAUTHENTICATED", "GetToken must return a user session token")
        }
        return value
    }

    private fun identityFor(token: String): Identity {
        val data = request("GET", "/api/v1/identity", token, null, null).data
        if (!data.isJsonObject) throw apiError("PROTOCOL_ERROR", "Invalid identity response")
        val project = data.asJsonObject.stringOrNull("project_id")
        val subject = data.asJsonObject.stringOrNull("subject_id")
        if (project.isNullOrEmpty() || subject.isNullOrEmpty()) {
            throw apiError("PROTOCOL_ERROR", "Invalid identity response")
        }
        return Identity(project, subject)
    }

    private fun assertOpen() {
        synchronized(lock) {
            if (closed) throw closedError()
        }
    }

    // ---- subscriptions -------------------------------------------------------------------------

    /** Starts a realtime subscription. Observe it with [Subscription.onChange]. */
    fun subscribe(name: String, params: JsonElement? = null): Subscription {
        synchronized(lock) {
            if (closed) throw closedError()
            val id = newId()
            if (entries.containsKey(id)) {
                throw IllegalArgumentException("fyrlet: NewId returned a duplicate subscription ID")
            }
            val entry = Entry(id, name, params ?: JsonObject(), options.delta)
            entries[id] = entry
            val conn = connection
            if (conn != null) attach(entry, conn, epoch) else start(false)
            return Subscription(this, entry)
        }
    }

    internal fun subscriptionState(entry: Entry): SubscriptionState = synchronized(lock) { entry.state }

    internal fun addListener(entry: Entry, listener: (SubscriptionState) -> Unit): () -> Unit {
        val id: Int
        synchronized(lock) {
            id = entry.nextListener
            entry.nextListener++
            entry.listeners[id] = listener
            dispatch(listener, entry.state)
        }
        return {
            synchronized(lock) {
                entry.listeners.remove(id)
            }
        }
    }

    internal fun refreshSubscription(entry: Entry) {
        val conn: Connection
        synchronized(lock) {
            conn = entry.connection ?: throw apiError("NOT_READY", "The subscription is not ready")
            if (entry.state.status != SubscriptionStatus.READY) {
                throw apiError("NOT_READY", "The subscription is not ready")
            }
        }
        val done = CompletableFuture<Unit>()
        val failure = conn.push(entry.topic, "refresh", JsonObject()) { status, response ->
            when (status) {
                "ok" -> done.complete(Unit)
                "error" -> done.completeExceptionally(channelError(response))
                else -> done.completeExceptionally(apiError("TIMEOUT", "refresh was not acknowledged", true))
            }
        }
        if (failure != null) throw failure
        try {
            done.join()
        } catch (error: CompletionException) {
            throw asApiException(error.cause ?: error)
        }
    }

    internal fun unsubscribe(entry: Entry) {
        synchronized(lock) {
            if (entries.remove(entry.id) == null) return
            cancelRejoin(entry)
            val conn = entry.connection
            entry.connection = null
            conn?.leave(entry.topic)
            entry.state = entry.state.copy(status = SubscriptionStatus.CLOSED, data = null, error = null)
            emit(entry)
            entry.listeners = LinkedHashMap()
            if (entries.isEmpty()) detach()
        }
    }

    /** Explicitly rebuilds the connection and the retained subscriptions. */
    fun reconnect() {
        val targetEpoch: Int
        val retained: Boolean
        synchronized(lock) {
            if (closed) throw closedError()
            detach()
            recovering()
            targetEpoch = epoch
            retained = entries.isNotEmpty()
        }
        if (!retained) return
        try {
            connect(true, targetEpoch)
        } catch (error: Throwable) {
            synchronized(lock) { connectionFailed(error, targetEpoch) }
            throw asApiException(error)
        }
    }

    /** Releases subscriptions, timers, executors and connections. The client cannot be reused. */
    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            detach()
            for (entry in entries.values) {
                entry.state = SubscriptionState(status = SubscriptionStatus.CLOSED)
                emit(entry)
                entry.listeners = LinkedHashMap()
            }
            entries.clear()
            token = null
        }
        stopListeners()
        scheduler.shutdown()
        background.shutdown()
        ownedHttpExecutor?.shutdown()
    }

    // ---- connection management (callers hold [lock] unless noted) ------------------------------

    private fun start(force: Boolean) {
        val targetEpoch = epoch
        if (connectingEpoch == targetEpoch) return
        connectingEpoch = targetEpoch
        background.execute {
            try {
                connect(force, targetEpoch)
            } catch (error: Throwable) {
                synchronized(lock) { connectionFailed(error, targetEpoch) }
            }
        }
    }

    /** Runs without the client lock held. */
    private fun connect(force: Boolean, targetEpoch: Int) {
        try {
            val token = authorize(force, null)
            synchronized(lock) {
                if (closed || epoch != targetEpoch || entries.isEmpty() || connection != null) return
            }
            val conn = Connection.dial(
                httpClient, endpoint, options.projectId, token, timeout, scheduler, background,
                ::onFrame, ::onClose,
            )
            synchronized(lock) {
                if (closed || epoch != targetEpoch || entries.isEmpty()) {
                    conn.close()
                    return
                }
                connection = conn
                for (entry in entries.values) {
                    if (entry.state.status != SubscriptionStatus.ERROR) attach(entry, conn, targetEpoch)
                }
            }
        } finally {
            synchronized(lock) {
                if (connectingEpoch == targetEpoch) connectingEpoch = -1
            }
        }
    }

    private fun joinPayload(entry: Entry): JsonObject {
        val payload = JsonObject()
        payload.addProperty("protocol_version", Entry.PROTOCOL_VERSION)
        payload.addProperty("name", entry.name)
        payload.add("params", entry.params)
        if (declared.isNotEmpty()) {
            val capabilities = JsonObject()
            for ((name, version) in declared) capabilities.addProperty(name, version)
            payload.add("capabilities", capabilities)
        }
        if (entry.wantDelta) payload.addProperty("delivery", "delta-v1")
        return payload
    }

    private fun current(entry: Entry, conn: Connection, targetEpoch: Int): Boolean =
        !closed && epoch == targetEpoch && entry.connection === conn && entries.containsKey(entry.id)

    private fun attach(entry: Entry, conn: Connection, targetEpoch: Int) {
        entry.connection = conn
        conn.join(entry.topic, joinPayload(entry)) { status, response ->
            synchronized(lock) {
                if (!current(entry, conn, targetEpoch)) return@synchronized
                when (status) {
                    "ok" -> {
                        retries = 0
                        entry.joinFailures = 0
                        receive(entry, conn, snapshot = true, payload = response ?: JsonObject(), initial = true)
                    }

                    "error" -> {
                        val error = channelError(response)
                        when {
                            error.code == "UNAUTHENTICATED" -> transportFailed(conn)
                            // For example the observer was briefly unavailable: retry this subscription only.
                            error.retryable && entry.joinFailures < MAX_JOIN_RETRIES -> {
                                entry.joinFailures++
                                entry.state = entry.state.copy(status = SubscriptionStatus.RECOVERING, error = null)
                                emit(entry)
                                scheduleRejoin(entry, conn, targetEpoch)
                            }

                            else -> fail(entry, error)
                        }
                    }

                    else -> transportFailed(conn)
                }
            }
        }
    }

    private fun scheduleRejoin(entry: Entry, conn: Connection, targetEpoch: Int) {
        cancelRejoin(entry)
        entry.rejoin = scheduler.schedule({
            synchronized(lock) {
                entry.rejoin = null
                if (current(entry, conn, targetEpoch)) attach(entry, conn, targetEpoch)
            }
        }, delay(entry.joinFailures).toMillis(), TimeUnit.MILLISECONDS)
    }

    private fun cancelRejoin(entry: Entry) {
        entry.rejoin?.cancel(false)
        entry.rejoin = null
    }

    private fun delay(attempt: Int): Duration {
        options.retryDelay?.let { return it(attempt) }
        val shift = (attempt - 1).coerceIn(0, 7)
        return Duration.ofMillis(minOf(250L shl shift, 30_000L))
    }

    private fun onFrame(conn: Connection, frame: Frame) {
        synchronized(lock) {
            if (conn !== connection || closed || !frame.topic.startsWith("subscription:")) return
            val entry = entries[frame.topic.removePrefix("subscription:")] ?: return
            if (entry.connection !== conn) return
            when (frame.event) {
                "snapshot" -> receive(entry, conn, snapshot = true, payload = frame.payload, initial = false)
                "delta" -> receive(entry, conn, snapshot = false, payload = frame.payload, initial = false)
                "status" -> {
                    val error = channelError(frame.payload)
                    when {
                        error.code == "UNAUTHENTICATED" -> {
                            for (item in entries.values) item.state = item.state.copy(data = null)
                            transportFailed(conn)
                        }

                        error.retryable -> transportFailed(conn)
                        else -> fail(entry, error)
                    }
                }

                "phx_error" -> transportFailed(conn)
                "phx_close" -> fail(
                    entry,
                    ApiException("SUBSCRIPTION_CLOSED", "The server closed the subscription"),
                )
            }
        }
    }

    private fun onClose(conn: Connection, failure: ApiException?) {
        synchronized(lock) {
            if (conn !== connection || closed) return
            if (failure != null && !failure.retryable) {
                failAllLocked(failure)
                return
            }
            transportFailed(conn)
        }
    }

    private fun receive(entry: Entry, conn: Connection, snapshot: Boolean, payload: JsonObject, initial: Boolean) {
        val before = entry.state
        val result: ApplyResult? = try {
            if (snapshot) entry.applySnapshot(payload, identity, initial) else entry.applyDelta(payload)
        } catch (error: ApiException) {
            fail(entry, error)
            return
        }
        if (result === ApplyResult.Reconnect) {
            transportFailed(conn)
            return
        }
        if (entry.state.seq != before.seq || entry.state.status != before.status ||
            entry.state.generation != before.generation
        ) {
            emit(entry)
        }
        if (result is ApplyResult.Ack) {
            val ack = JsonObject()
            ack.addProperty("g", result.generation)
            ack.addProperty("s", result.seq)
            conn.notify(entry.topic, "ack", ack)
        }
    }

    private fun transportFailed(conn: Connection) {
        if (conn !== connection || closed) return
        detach()
        recovering()
        scheduleRetry()
    }

    private fun connectionFailed(error: Throwable, targetEpoch: Int) {
        if (closed || epoch != targetEpoch || error is InterruptedException) return
        // A foreign error, such as a failing getToken, counts as a retryable network failure.
        val failure = asApiException(error)
        if (!failure.retryable) {
            failAllLocked(failure)
            return
        }
        recovering()
        scheduleRetry()
    }

    private fun scheduleRetry() {
        if (closed || retryTimer != null || entries.isEmpty()) return
        retries++
        retryTimer = scheduler.schedule({
            synchronized(lock) {
                retryTimer = null
                if (!closed && entries.isNotEmpty()) start(true)
            }
        }, delay(retries).toMillis(), TimeUnit.MILLISECONDS)
    }

    private fun recovering() {
        for (entry in entries.values) {
            if (entry.state.status == SubscriptionStatus.ERROR) continue
            entry.state = entry.state.copy(status = SubscriptionStatus.RECOVERING, error = null)
            emit(entry)
        }
    }

    private fun failAll(error: ApiException) {
        synchronized(lock) { failAllLocked(error) }
    }

    private fun failAllLocked(error: ApiException) {
        detach()
        token = null
        for (entry in entries.values) fail(entry, error)
    }

    private fun fail(entry: Entry, error: ApiException) {
        cancelRejoin(entry)
        val conn = entry.connection
        entry.connection = null
        conn?.leave(entry.topic)
        entry.state = entry.state.copy(status = SubscriptionStatus.ERROR, data = null, error = error)
        emit(entry)
    }

    private fun detach() {
        epoch++
        connectingEpoch = -1
        retryTimer?.cancel(false)
        retryTimer = null
        val conn = connection
        connection = null
        for (entry in entries.values) {
            cancelRejoin(entry)
            entry.connection = null
        }
        conn?.close()
    }

    // ---- listener dispatch ---------------------------------------------------------------------

    private fun emit(entry: Entry) {
        for (listener in entry.listeners.values) dispatch(listener, entry.state)
    }

    private fun dispatch(listener: (SubscriptionState) -> Unit, state: SubscriptionState) {
        synchronized(listenerLock) {
            if (listenerStopped) return
            listenerQueue.add(Runnable { listener(state) })
        }
    }

    private fun drainListeners() {
        while (true) {
            val job = try {
                listenerQueue.take()
            } catch (_: InterruptedException) {
                return
            }
            if (job === stopMarker) return
            try {
                (job as Runnable).run()
            } catch (error: Throwable) {
                try {
                    options.onListenerError?.invoke(error)
                } catch (_: Throwable) {
                    // A failing error handler must not break the client.
                }
            }
        }
    }

    private fun stopListeners() {
        synchronized(listenerLock) {
            if (listenerStopped) return
            listenerStopped = true
            listenerQueue.add(stopMarker)
        }
    }

    private fun closedError(): ApiException = apiError("CLIENT_CLOSED", "The client is closed")

    private companion object {
        const val MAX_JOIN_RETRIES = 10
        val CAPABILITY_NAME: Pattern = Pattern.compile("^[a-z][a-z0-9_.-]*$")
        val SUCCESS_STATUSES = setOf(
            MutationStatus.COMPLETED,
            MutationStatus.COMMITTED,
            MutationStatus.ACCEPTED,
        )

        fun daemonFactory(name: String): ThreadFactory = ThreadFactory { runnable ->
            Thread(runnable, name).apply { isDaemon = true }
        }
    }
}
