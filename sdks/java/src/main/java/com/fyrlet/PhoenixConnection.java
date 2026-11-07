package com.fyrlet;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.net.http.WebSocketHandshakeException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** One authenticated Phoenix socket. Frame callbacks run in arrival order on the WebSocket thread. */
final class PhoenixConnection implements WebSocket.Listener {

    private static final Duration HEARTBEAT_INTERVAL = Duration.ofSeconds(30);

    /** Receives decoded non-reply frames. */
    @FunctionalInterface
    interface FrameListener {
        void onFrame(PhoenixConnection connection, Wire.Frame frame);
    }

    /** Receives the single terminal event of a connection that was established. */
    @FunctionalInterface
    interface CloseListener {
        void onClose(PhoenixConnection connection, ApiException failure);
    }

    /** Receives exactly one of {@code ok}, {@code error} or {@code timeout}. */
    @FunctionalInterface
    interface Reply {
        void reply(String status, JsonObject response);
    }

    private final Duration timeout;
    private final ScheduledExecutorService scheduler;
    private final Executor async;
    private final FrameListener onFrame;
    private final CloseListener onClose;

    private final Object lock = new Object();
    private final Object writeLock = new Object();
    private final Object partialLock = new Object();
    private final Map<String, Pending> pending = new HashMap<>();
    private final StringBuilder partial = new StringBuilder();
    private WebSocket socket;
    private ScheduledFuture<?> heartbeat;
    private int refs;
    private long partialBytes;
    private boolean closed;

    private PhoenixConnection(Duration timeout, ScheduledExecutorService scheduler, Executor async,
                              FrameListener onFrame, CloseListener onClose) {
        this.timeout = timeout;
        this.scheduler = scheduler;
        this.async = async;
        this.onFrame = onFrame;
        this.onClose = onClose;
    }

    /**
     * Opens one authenticated socket and starts its reader and heartbeat.
     *
     * @return the established connection
     * @throws ApiException when the socket cannot be opened or the session is rejected
     */
    static PhoenixConnection open(String endpoint, String projectId, String token, Duration timeout,
                                  ScheduledExecutorService scheduler, Executor async,
                                  FrameListener onFrame, CloseListener onClose) throws ApiException {
        PhoenixConnection connection = new PhoenixConnection(timeout, scheduler, async, onFrame, onClose);
        CompletableFuture<WebSocket> opening;
        try {
            opening = HttpClient.newHttpClient().newWebSocketBuilder()
                    .connectTimeout(timeout)
                    .subprotocols("phoenix", Wire.authProtocol(token))
                    .buildAsync(URI.create(Wire.socketUrl(endpoint, projectId)), connection);
        } catch (IllegalArgumentException error) {
            throw ApiException.network();
        }

        try {
            WebSocket webSocket = opening.get(timeout.toMillis(), TimeUnit.MILLISECONDS);
            connection.attach(webSocket);
            return connection;
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            connection.close();
            throw ApiException.network("The socket connection was interrupted");
        } catch (TimeoutException error) {
            connection.close();
            throw ApiException.network();
        } catch (ExecutionException error) {
            connection.close();
            Throwable cause = error.getCause() == null ? error : error.getCause();
            if (cause instanceof WebSocketHandshakeException handshake) {
                int status = handshake.getResponse() == null ? 0 : handshake.getResponse().statusCode();
                if (status == 401 || status == 403) {
                    throw new ApiException("UNAUTHENTICATED", "The socket rejected the session", false, status,
                            null, new JsonObject(), cause);
                }
            }
            throw ApiException.network();
        } catch (RuntimeException error) {
            connection.close();
            throw ApiException.network();
        }
    }

    private void attach(WebSocket webSocket) {
        boolean start;
        synchronized (lock) {
            if (closed) {
                start = false;
            } else if (socket == null) {
                socket = webSocket;
                start = true;
            } else {
                start = false;
            }
        }
        if (start) {
            webSocket.request(Long.MAX_VALUE);
            scheduleHeartbeat();
        } else {
            synchronized (lock) {
                if (closed) {
                    try {
                        webSocket.abort();
                    } catch (RuntimeException ignored) {
                        // best effort
                    }
                }
            }
        }
    }

    // ---- outbound frames ------------------------------------------------------------------------

    private String nextRef() {
        synchronized (lock) {
            refs++;
            return Integer.toString(refs);
        }
    }

    private boolean register(String ref, Reply reply) {
        final Pending entry = new Pending(reply);
        synchronized (lock) {
            if (closed) {
                return false;
            }
            pending.put(ref, entry);
        }
        try {
            entry.timer = scheduler.schedule(() -> {
                synchronized (lock) {
                    if (pending.get(ref) != entry) {
                        return;
                    }
                    pending.remove(ref);
                }
                entry.reply.reply("timeout", null);
            }, Math.max(1L, timeout.toMillis()), TimeUnit.MILLISECONDS);
        } catch (RejectedExecutionException error) {
            synchronized (lock) {
                pending.remove(ref);
            }
            return false;
        }
        return true;
    }

    private void unregister(String ref) {
        Pending entry;
        synchronized (lock) {
            entry = pending.remove(ref);
        }
        if (entry != null) {
            entry.timer.cancel(false);
        }
    }

    private void send(JsonElement parts) throws ApiException {
        String raw = Json.GSON.toJson(parts);
        synchronized (writeLock) {
            WebSocket current;
            synchronized (lock) {
                current = socket;
                if (closed || current == null) {
                    throw ApiException.network("The connection was interrupted");
                }
            }
            CompletableFuture<WebSocket> write;
            try {
                write = current.sendText(raw, true).orTimeout(Math.max(1L, timeout.toMillis()),
                        TimeUnit.MILLISECONDS);
            } catch (RuntimeException error) {
                ApiException failure = ApiException.network("The connection was interrupted");
                shutdown(failure, true);
                throw failure;
            }
            write.whenComplete((ignored, error) -> {
                if (error != null) {
                    shutdown(ApiException.network("The connection was interrupted"), true);
                }
            });
        }
    }

    /** Sends an event; {@code reply} receives exactly one of ok, error or timeout. */
    void push(String topic, String event, JsonElement payload, Reply reply) throws ApiException {
        String ref = nextRef();
        if (!register(ref, reply)) {
            throw ApiException.network("The connection was interrupted");
        }
        JsonArray parts = new JsonArray();
        parts.add(JsonNull.INSTANCE);
        parts.add(ref);
        parts.add(topic);
        parts.add(event);
        parts.add(payload);
        try {
            send(parts);
        } catch (ApiException error) {
            unregister(ref);
            throw error;
        }
    }

    /** Sends a join frame with the reference used as both join_ref and ref. */
    void join(String topic, JsonElement payload, Reply reply) throws ApiException {
        String ref = nextRef();
        if (!register(ref, reply)) {
            throw ApiException.network("The connection was interrupted");
        }
        JsonArray parts = new JsonArray();
        parts.add(ref);
        parts.add(ref);
        parts.add(topic);
        parts.add("phx_join");
        parts.add(payload);
        try {
            send(parts);
        } catch (ApiException error) {
            unregister(ref);
            throw error;
        }
    }

    /** Sends a one-way event with no ref, such as an ACK. */
    void notify(String topic, String event, JsonElement payload) {
        JsonArray parts = new JsonArray();
        parts.add(JsonNull.INSTANCE);
        parts.add(JsonNull.INSTANCE);
        parts.add(topic);
        parts.add(event);
        parts.add(payload);
        try {
            send(parts);
        } catch (ApiException ignored) {
            // send already shut the connection down
        }
    }

    /** Sends {@code phx_leave}; it is a one-way notification in this SDK. */
    void leave(String topic) {
        JsonArray parts = new JsonArray();
        parts.add(JsonNull.INSTANCE);
        parts.add(nextRef());
        parts.add(topic);
        parts.add("phx_leave");
        parts.add(new JsonObject());
        try {
            send(parts);
        } catch (ApiException ignored) {
            // send already shut the connection down
        }
    }

    // ---- inbound frames -------------------------------------------------------------------------

    @Override
    public void onOpen(WebSocket webSocket) {
        attach(webSocket);
    }

    @Override
    public CompletionStage<?> onText(WebSocket webSocket, CharSequence data, boolean last) {
        String raw = null;
        synchronized (partialLock) {
            partial.append(data);
            partialBytes += data.toString().getBytes(StandardCharsets.UTF_8).length;
            if (partialBytes > Wire.MAX_MESSAGE_BYTES) {
                partial.setLength(0);
                partialBytes = 0;
                shutdown(ApiException.network("The connection was interrupted"), true);
                abort(webSocket);
                return null;
            }
            if (last) {
                raw = partial.toString();
                partial.setLength(0);
                partialBytes = 0;
            }
        }
        if (raw != null) {
            dispatchRaw(raw);
        }
        return null;
    }

    @Override
    public CompletionStage<?> onBinary(WebSocket webSocket, java.nio.ByteBuffer data, boolean last) {
        shutdown(new ApiException("PROTOCOL_ERROR", "Invalid transport frame"), true);
        abort(webSocket);
        return null;
    }

    @Override
    public CompletionStage<?> onClose(WebSocket webSocket, int statusCode, String reason) {
        shutdown(ApiException.network("The connection was interrupted"), true);
        return null;
    }

    @Override
    public void onError(WebSocket webSocket, Throwable error) {
        shutdown(ApiException.network("The connection was interrupted"), true);
    }

    private void dispatchRaw(String raw) {
        List<Wire.Frame> frames = Wire.decodeFrames(raw);
        if (frames == null) {
            shutdown(new ApiException("PROTOCOL_ERROR", "Invalid transport frame"), true);
            return;
        }
        for (Wire.Frame frame : frames) {
            dispatch(frame);
        }
    }

    private void dispatch(Wire.Frame frame) {
        if ("phx_reply".equals(frame.event()) && frame.ref() != null) {
            Pending entry;
            synchronized (lock) {
                entry = pending.remove(frame.ref());
            }
            if (entry != null) {
                entry.timer.cancel(false);
                String status = Json.text(frame.payload(), "status");
                if (status == null || status.isEmpty()) {
                    status = "error";
                }
                JsonElement response = frame.payload().get("response");
                JsonObject object = response != null && response.isJsonObject()
                        ? response.getAsJsonObject() : null;
                entry.reply.reply(status, object);
            }
            return;
        }
        onFrame.onFrame(this, frame);
    }

    // ---- lifecycle ------------------------------------------------------------------------------

    private void scheduleHeartbeat() {
        ScheduledFuture<?> future;
        try {
            future = scheduler.scheduleAtFixedRate(this::heartbeat, HEARTBEAT_INTERVAL.toMillis(),
                    HEARTBEAT_INTERVAL.toMillis(), TimeUnit.MILLISECONDS);
        } catch (RejectedExecutionException error) {
            return;
        }
        synchronized (lock) {
            if (closed) {
                future.cancel(false);
            } else {
                heartbeat = future;
            }
        }
    }

    private void heartbeat() {
        synchronized (lock) {
            if (closed) {
                return;
            }
        }
        try {
            push("phoenix", "heartbeat", new JsonObject(), (status, response) -> {
                if ("timeout".equals(status)) {
                    shutdown(ApiException.network("Heartbeat timed out"), true);
                }
            });
        } catch (ApiException ignored) {
            // send already shut the connection down
        }
    }

    void close() {
        shutdown(null, false);
    }

    private void shutdown(ApiException failure, boolean notify) {
        List<Pending> waiters;
        ScheduledFuture<?> beat;
        WebSocket current;
        synchronized (lock) {
            if (closed) {
                return;
            }
            closed = true;
            waiters = new ArrayList<>(pending.values());
            pending.clear();
            beat = heartbeat;
            heartbeat = null;
            current = socket;
            socket = null;
        }
        if (beat != null) {
            beat.cancel(false);
        }
        if (current != null) {
            abort(current);
        }
        for (Pending waiter : waiters) {
            waiter.timer.cancel(false);
            runAsync(() -> {
                try {
                    waiter.reply.reply("timeout", null);
                } catch (RuntimeException ignored) {
                    // listeners must not break shutdown
                }
            });
        }
        if (notify && failure != null) {
            runAsync(() -> onClose.onClose(this, failure));
        }
    }

    private static void abort(WebSocket webSocket) {
        try {
            webSocket.abort();
        } catch (RuntimeException ignored) {
            // best effort
        }
    }

    private void runAsync(Runnable job) {
        try {
            async.execute(job);
        } catch (RejectedExecutionException ignored) {
            // the client is shutting down
        }
    }

    private static final class Pending {
        private final Reply reply;
        private ScheduledFuture<?> timer;

        private Pending(Reply reply) {
            this.reply = reply;
        }
    }
}
