package fyrlet

import com.google.gson.JsonArray
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.net.http.WebSocketHandshakeException
import java.time.Duration
import java.util.concurrent.CompletionStage
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Receives a push reply status ("ok", "error" or "timeout") exactly once. */
internal typealias Reply = (status: String, response: JsonObject?) -> Unit

/**
 * One authenticated Phoenix socket. Frames are delivered in order on the socket reader thread; connection
 * callbacks are dispatched on a worker so a caller may hold the client lock when closing the socket.
 */
internal class Connection private constructor(
    private val timeout: Duration,
    private val scheduler: ScheduledExecutorService,
    private val callbacks: Executor,
    private val onFrame: (Connection, Frame) -> Unit,
    private val onClose: (Connection, ApiException?) -> Unit,
) {
    private class PendingReply(val reply: Reply) {
        var timer: ScheduledFuture<*>? = null
    }

    private val lock = Any()
    private var socket: WebSocket? = null
    private val pending = HashMap<String, PendingReply>()
    private var refs = 0
    private var closed = false
    private var failure: ApiException = interrupted()
    private var buffer = StringBuilder()
    private var heartbeat: ScheduledFuture<*>? = null

    private val listener = object : WebSocket.Listener {
        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
            var pendingText: String? = null
            var oversized: ApiException? = null
            synchronized(lock) {
                if (closed) return null
                buffer.append(data)
                if (buffer.length > Wire.MAX_MESSAGE_BYTES) {
                    oversized = interrupted()
                } else if (last) {
                    pendingText = buffer.toString()
                    buffer = StringBuilder()
                }
            }
            val invalid = oversized
            val raw = pendingText
            if (invalid != null) {
                shutdown(invalid, notify = true)
                webSocket.abort()
                return null
            }
            if (raw != null) {
                val frames = Wire.decodeFrames(raw)
                if (frames == null) {
                    shutdown(ApiException("PROTOCOL_ERROR", "Invalid transport frame"), notify = true)
                    webSocket.abort()
                    return null
                }
                // Frames are validated as a whole before any member is dispatched.
                for (frame in frames) dispatch(frame)
            }
            try {
                webSocket.request(1)
            } catch (_: IllegalStateException) {
                // The socket was closed while dispatching.
            }
            return null
        }

        override fun onBinary(webSocket: WebSocket, data: java.nio.ByteBuffer, last: Boolean): CompletionStage<*>? {
            shutdown(ApiException("PROTOCOL_ERROR", "Invalid transport frame"), notify = true)
            webSocket.abort()
            return null
        }

        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletionStage<*>? {
            shutdown(currentFailure(), notify = true)
            return null
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            shutdown(currentFailure(), notify = true)
        }
    }

    fun attach(webSocket: WebSocket) {
        synchronized(lock) { socket = webSocket }
    }

    private fun nextRef(): String = synchronized(lock) { (++refs).toString() }

    private fun register(ref: String, reply: Reply): Boolean {
        synchronized(lock) {
            if (closed) return false
            val entry = PendingReply(reply)
            entry.timer = scheduler.schedule({
                val waiter = synchronized(lock) { pending.remove(ref) }
                waiter?.reply?.invoke("timeout", null)
            }, timeout.toMillis(), TimeUnit.MILLISECONDS)
            pending[ref] = entry
            return true
        }
    }

    private fun unregister(ref: String) {
        synchronized(lock) {
            pending.remove(ref)?.timer?.cancel(false)
        }
    }

    /** Sends an event; [reply] receives "ok", "error" or "timeout" exactly once. Returns a failure if unsent. */
    fun push(topic: String, event: String, payload: JsonObject, reply: Reply): ApiException? {
        val ref = nextRef()
        if (!register(ref, reply)) return interrupted()
        val failure = send(Wire.frame(null, ref, topic, event, payload))
        if (failure != null) unregister(ref)
        return failure
    }

    /** Joins a topic. Returns a failure if the join frame could not be sent. */
    fun join(topic: String, payload: JsonObject, reply: Reply): ApiException? {
        val ref = nextRef()
        if (!register(ref, reply)) return interrupted()
        val failure = send(Wire.frame(ref, ref, topic, "phx_join", payload))
        if (failure != null) unregister(ref)
        return failure
    }

    /** Sends a one-way event with no ref, such as an ACK. */
    fun notify(topic: String, event: String, payload: JsonObject): ApiException? =
        send(Wire.frame(null, null, topic, event, payload))

    /** Leaves a topic. */
    fun leave(topic: String) {
        send(Wire.frame(null, nextRef(), topic, "phx_leave", JsonObject()))
    }

    fun close() = shutdown(null, notify = false)

    private fun send(parts: JsonArray): ApiException? {
        val webSocket = synchronized(lock) { socket }
        if (webSocket == null) return interrupted()
        val text = FyrletJson.gson.toJson(parts)
        return try {
            webSocket.sendText(text, true).get(timeout.toMillis(), TimeUnit.MILLISECONDS)
            null
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            shutDownInterrupted()
        } catch (_: ExecutionException) {
            shutDownInterrupted()
        } catch (_: TimeoutException) {
            shutDownInterrupted()
        } catch (_: IllegalStateException) {
            shutDownInterrupted()
        } catch (_: IllegalArgumentException) {
            shutDownInterrupted()
        }
    }

    private fun shutDownInterrupted(): ApiException {
        val error = interrupted()
        shutdown(error, notify = true)
        return error
    }

    private fun dispatch(frame: Frame) {
        if (frame.event == "phx_reply" && frame.ref != null) {
            val waiter = synchronized(lock) { pending.remove(frame.ref) }
            if (waiter != null) {
                waiter.timer?.cancel(false)
                val status = frame.payload.stringOrNull("status") ?: "error"
                val response = frame.payload.get("response")
                    ?.takeIf { it.isJsonObject }
                    ?.asJsonObject
                waiter.reply(status, response)
            }
            return
        }
        onFrame(this, frame)
    }

    private fun startHeartbeat() {
        val task = scheduler.scheduleAtFixedRate({
            push("phoenix", "heartbeat", JsonObject()) { status, _ ->
                if (status == "timeout") shutdown(apiError("NETWORK_ERROR", "Heartbeat timed out", retryable = true), notify = true)
            }
        }, HEARTBEAT_SECONDS, HEARTBEAT_SECONDS, TimeUnit.SECONDS)
        synchronized(lock) {
            if (closed) task.cancel(false) else heartbeat = task
        }
    }

    private fun currentFailure(): ApiException = synchronized(lock) { failure }

    /**
     * Closes the socket once. Pending replies and the close notification run on the callback executor because
     * the caller may hold the client lock that those callbacks take.
     */
    private fun shutdown(error: ApiException?, notify: Boolean) {
        val waiters: List<PendingReply>
        val webSocket: WebSocket?
        synchronized(lock) {
            if (closed) return
            closed = true
            if (error != null) failure = error
            heartbeat?.cancel(false)
            heartbeat = null
            waiters = pending.values.toList()
            pending.clear()
            buffer = StringBuilder()
            webSocket = socket
        }
        for (waiter in waiters) waiter.timer?.cancel(false)
        try {
            webSocket?.abort()
        } catch (_: Exception) {
            // Best effort.
        }
        for (waiter in waiters) {
            val reply = waiter.reply
            try {
                callbacks.execute { reply("timeout", null) }
            } catch (_: RejectedExecutionException) {
                reply("timeout", null)
            }
        }
        if (notify) {
            val actual = error ?: currentFailure()
            try {
                callbacks.execute { onClose(this, actual) }
            } catch (_: RejectedExecutionException) {
                // The client is being torn down.
            }
        }
    }

    companion object {
        private const val HEARTBEAT_SECONDS = 30L

        /**
         * Opens one authenticated socket. A 401/403 handshake becomes `UNAUTHENTICATED`; any other failure
         * becomes a retryable `NETWORK_ERROR`.
         */
        fun dial(
            httpClient: HttpClient,
            endpoint: String,
            projectId: String,
            token: String,
            timeout: Duration,
            scheduler: ScheduledExecutorService,
            callbacks: Executor,
            onFrame: (Connection, Frame) -> Unit,
            onClose: (Connection, ApiException?) -> Unit,
        ): Connection {
            val connection = Connection(timeout, scheduler, callbacks, onFrame, onClose)
            val builder = httpClient.newWebSocketBuilder()
                .connectTimeout(timeout)
                .subprotocols("phoenix", Wire.authProtocol(token))
            val webSocket = try {
                builder.buildAsync(URI(Wire.socketUrl(endpoint, projectId)), connection.listener)
                    .get(timeout.toMillis(), TimeUnit.MILLISECONDS)
            } catch (error: ExecutionException) {
                throw handshakeFailure(error.cause, timeout)
            } catch (_: TimeoutException) {
                throw apiError("NETWORK_ERROR", "The service could not be reached", retryable = true)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                throw apiError("NETWORK_ERROR", "The service could not be reached", retryable = true)
            }
            connection.attach(webSocket)
            connection.startHeartbeat()
            return connection
        }

        private fun handshakeFailure(cause: Throwable?, timeout: Duration): ApiException {
            if (cause is WebSocketHandshakeException) {
                val status = cause.response.statusCode()
                if (status == 401 || status == 403) {
                    return ApiException("UNAUTHENTICATED", "The socket rejected the session", status = status)
                }
            }
            return apiError("NETWORK_ERROR", "The service could not be reached", retryable = true)
        }

        private fun interrupted(): ApiException =
            apiError("NETWORK_ERROR", "The connection was interrupted", retryable = true)
    }
}
