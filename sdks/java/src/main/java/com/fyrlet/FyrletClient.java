package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.net.http.HttpClient;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;
import java.util.function.IntFunction;
import java.util.function.Supplier;
import java.util.regex.Pattern;

/**
 * A client bound to one project and one user.
 *
 * <p>It runs authenticated operations over HTTP and recoverable realtime subscriptions over a Phoenix
 * Channels connection. All public methods are safe for concurrent use.</p>
 *
 * <p>The first authenticated request reads {@code /api/v1/identity} and binds the Subject. Switching
 * accounts on one client fails with {@code FORBIDDEN}; close the client and create a new one instead.</p>
 */
public final class FyrletClient implements AutoCloseable {

    /** Consecutive retryable join failures of one subscription before it is reported as failed. */
    private static final int MAX_JOIN_RETRIES = 10;

    private static final Pattern CAPABILITY_NAME = Pattern.compile("^[a-z][a-z0-9_.-]*$");

    private final String projectId;
    private final String endpoint;
    private final TokenProvider getToken;
    private final Duration timeout;
    private final IntFunction<Duration> retryDelay;
    private final boolean delta;
    private final Map<String, Integer> declared;
    private final HttpClient http;
    private final Supplier<String> newId;
    private final Consumer<Throwable> onListenerError;

    private final Object lock = new Object();
    private final Object tokenLock = new Object();
    private final ScheduledExecutorService scheduler;
    private final ExecutorService events;
    private final ExecutorService async;

    private final Map<String, SubscriptionEntry> entries = new LinkedHashMap<>();
    private PhoenixConnection connection;
    private Identity identity;
    private String token;
    private int epoch;
    private int connectingEpoch = -1;
    private int retries;
    private ScheduledFuture<?> retryTimer;
    private boolean closed;

    /**
     * Validates the options and creates a client. No network access happens until first use.
     *
     * @param options the configuration, copied by this constructor
     * @throws IllegalArgumentException when a required value is missing or invalid
     */
    public FyrletClient(FyrletOptions options) {
        if (options == null) {
            throw new IllegalArgumentException("options are required");
        }
        String project = options.projectId;
        if (project == null || project.isEmpty()) {
            throw new IllegalArgumentException("projectId is required");
        }
        if (options.getToken == null) {
            throw new IllegalArgumentException("getToken is required");
        }
        String base = Wire.endpointUrl(options.endpoint);

        Map<String, Integer> capabilities = options.capabilities == null ? Map.of() : options.capabilities;
        Map<String, Integer> frozenCapabilities = new LinkedHashMap<>();
        for (Map.Entry<String, Integer> entry : capabilities.entrySet()) {
            String name = entry.getKey();
            Integer version = entry.getValue();
            if (name == null || !CAPABILITY_NAME.matcher(name).matches() || version == null || version < 1) {
                throw new IllegalArgumentException(
                        "capabilities must be names with a positive integer version");
            }
            frozenCapabilities.put(name, version);
        }

        Duration resolvedTimeout = options.timeout;
        if (resolvedTimeout == null || resolvedTimeout.isZero() || resolvedTimeout.isNegative()) {
            resolvedTimeout = Duration.ofSeconds(10);
        }

        HttpClient resolvedHttp = options.httpClient;
        if (resolvedHttp != null) {
            FyrletHttp.requireNoRedirects(resolvedHttp);
        } else {
            resolvedHttp = FyrletHttp.newHttpClient(resolvedTimeout);
        }

        this.projectId = project;
        this.endpoint = base;
        this.getToken = options.getToken;
        this.timeout = resolvedTimeout;
        this.retryDelay = options.retryDelay;
        this.delta = options.delta;
        this.declared = Map.copyOf(frozenCapabilities);
        this.http = resolvedHttp;
        this.newId = options.newId == null ? () -> UUID.randomUUID().toString() : options.newId;
        this.onListenerError = options.onListenerError;

        this.scheduler = Executors.newScheduledThreadPool(2, daemonFactory("fyrlet-timer"));
        this.events = Executors.newSingleThreadExecutor(daemonFactory("fyrlet-listeners"));
        this.async = Executors.newCachedThreadPool(daemonFactory("fyrlet-async"));
    }

    private static ThreadFactory daemonFactory(String prefix) {
        AtomicInteger counter = new AtomicInteger();
        return runnable -> {
            Thread thread = new Thread(runnable, prefix + "-" + counter.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        };
    }

    /** The lock guarding subscription state; used by {@link Subscription}. */
    Object gate() {
        return lock;
    }

    // ---- operations -----------------------------------------------------------------------------

    /**
     * Runs an operation and returns its business result.
     *
     * @param name the operation name from the contract
     * @param input the operation input, or {@code null} for an empty object
     * @return the business result
     * @throws ApiException when the operation fails or the outcome is unknown
     */
    public JsonElement call(String name, Object input) throws ApiException {
        return mutate(name, input, null).result();
    }

    /**
     * Runs an operation with an explicit idempotency key.
     *
     * @param name the operation name from the contract
     * @param input the operation input, or {@code null} for an empty object
     * @param idempotencyKey a key to reuse, or {@code null} to generate one
     * @return the business result
     * @throws ApiException when the operation fails or the outcome is unknown
     */
    public JsonElement call(String name, Object input, String idempotencyKey) throws ApiException {
        return mutate(name, input, idempotencyKey).result();
    }

    /**
     * Runs an operation and decodes its result into {@code type}.
     *
     * @param name the operation name from the contract
     * @param input the operation input, or {@code null}
     * @param type the result class
     * @param <T> the result type
     * @return the decoded result, or {@code null} for JSON null
     * @throws ApiException when the operation fails or the outcome is unknown
     */
    public <T> T callInto(String name, Object input, Class<T> type) throws ApiException {
        return decode(call(name, input), type);
    }

    /**
     * Runs an operation with an explicit idempotency key and decodes its result.
     *
     * @param name the operation name from the contract
     * @param input the operation input, or {@code null}
     * @param type the result class
     * @param idempotencyKey a key to reuse, or {@code null} to generate one
     * @param <T> the result type
     * @return the decoded result, or {@code null} for JSON null
     * @throws ApiException when the operation fails or the outcome is unknown
     */
    public <T> T callInto(String name, Object input, Class<T> type, String idempotencyKey)
            throws ApiException {
        return decode(call(name, input, idempotencyKey), type);
    }

    private static <T> T decode(JsonElement data, Class<T> type) {
        if (data == null || data.isJsonNull()) {
            return null;
        }
        return Json.GSON.fromJson(data, type);
    }

    /**
     * Runs an operation and never throws for a failed operation: inspect {@link Mutation#state()}.
     *
     * <p>A definite server rejection leaves the mutation failed. A transport failure after the request
     * was dispatched leaves it unknown with an {@link OutcomeUnknownException}; recover it instead of
     * blindly resubmitting.</p>
     *
     * @param name the operation name from the contract
     * @param input the operation input, or {@code null}
     * @param idempotencyKey a key to reuse, or {@code null} to generate one
     * @return the mutation handle
     */
    public Mutation mutate(String name, Object input, String idempotencyKey) {
        String key = idempotencyKey == null || idempotencyKey.isEmpty() ? newId.get() : idempotencyKey;
        JsonObject body = new JsonObject();
        body.add("input", Json.input(input));
        Mutation.Lookup lookup = () -> recoverReceipt(name, body, key);

        synchronized (lock) {
            if (closed) {
                return new Mutation(key, new MutationState(MutationStatus.FAILED, null, ApiException.closed()),
                        lookup);
            }
        }

        boolean[] sent = {false};
        try {
            FyrletHttp.Envelope envelope = execute(current -> {
                sent[0] = true;
                try {
                    return request("POST", operationPath(name), current, body, key);
                } catch (ApiException error) {
                    // A definite rejection means nothing was written.
                    if (error.status() >= 400 && error.status() < 500
                            && !error.code().equals("PROTOCOL_ERROR") && !error.code().equals("HTTP_ERROR")) {
                        sent[0] = false;
                    }
                    throw error;
                }
            });
            MutationStatus status = MutationStatus.fromWire(envelope.outcome());
            if (status == null || !status.isSuccess()) {
                throw new ApiException("PROTOCOL_ERROR", "Invalid operation outcome");
            }
            return new Mutation(key, new MutationState(status, envelope.data(), null), lookup);
        } catch (ApiException error) {
            if (sent[0]) {
                return new Mutation(key,
                        new MutationState(MutationStatus.UNKNOWN, null,
                                new OutcomeUnknownException(name, key, error)),
                        lookup);
            }
            return new Mutation(key, new MutationState(MutationStatus.FAILED, null, error), lookup);
        }
    }

    /**
     * Runs an operation without an explicit key. See {@link #mutate(String, Object, String)}.
     *
     * @param name the operation name from the contract
     * @param input the operation input, or {@code null}
     * @return the mutation handle
     */
    public Mutation mutate(String name, Object input) {
        return mutate(name, input, null);
    }

    /**
     * Looks up the stored receipt of a write without executing it.
     *
     * @param name the operation name
     * @param input the original input
     * @param idempotencyKey the key used for the write
     * @return the stored outcome, or unknown when no receipt is visible
     * @throws ApiException when the recovery request fails
     */
    public RecoveryResult recover(String name, Object input, String idempotencyKey) throws ApiException {
        JsonObject body = new JsonObject();
        body.add("input", Json.input(input));
        assertOpen();
        return recoverReceipt(name, body, idempotencyKey);
    }

    /**
     * Returns the business contract this server exports.
     *
     * @return the contract JSON
     * @throws ApiException on transport or server failure
     */
    public JsonElement contract() throws ApiException {
        return execute(current -> request("GET", "/api/v1/contract", current, null, null)).data();
    }

    private static String operationPath(String name) {
        return "/api/v1/operations/" + Wire.pathSegment(name);
    }

    private RecoveryResult recoverReceipt(String name, JsonObject body, String key) throws ApiException {
        FyrletHttp.Envelope envelope = execute(
                current -> request("POST", operationPath(name) + "/recover", current, body, key));
        String outcome = envelope.outcome();
        JsonElement data = envelope.data();
        boolean noData = data == null || data.isJsonNull();
        if ("unknown".equals(outcome) && noData) {
            return new RecoveryResult(MutationStatus.UNKNOWN, null);
        }
        if ("committed".equals(outcome)) {
            return new RecoveryResult(MutationStatus.COMMITTED, data);
        }
        if ("accepted".equals(outcome)) {
            return new RecoveryResult(MutationStatus.ACCEPTED, data);
        }
        throw new ApiException("PROTOCOL_ERROR", "Invalid recovery outcome");
    }

    private FyrletHttp.Envelope request(String method, String path, String userToken, JsonElement body,
                                        String key) throws ApiException {
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("authorization", "Bearer " + userToken);
        headers.put("x-project-id", projectId);
        if (key != null && !key.isEmpty()) {
            headers.put("idempotency-key", key);
        }
        if (!declared.isEmpty()) {
            List<String> names = new ArrayList<>(declared.keySet());
            names.sort(String::compareTo);
            List<String> parts = new ArrayList<>(names.size());
            for (String name : names) {
                parts.add(name + "=" + declared.get(name));
            }
            headers.put("x-fyrlet-capabilities", String.join(", ", parts));
        }
        return FyrletHttp.send(http, method, endpoint + path, headers, body, timeout);
    }

    @FunctionalInterface
    private interface Perform {
        FyrletHttp.Envelope perform(String token) throws ApiException;
    }

    /** Authorizes, runs {@code perform} and refreshes the token at most once after an auth failure. */
    private FyrletHttp.Envelope execute(Perform perform) throws ApiException {
        String current;
        try {
            current = authorize(false, null);
        } catch (ApiException error) {
            throw authFailure(error);
        }
        try {
            return perform.perform(current);
        } catch (ApiException error) {
            if (error.status() != 401 && !error.code().equals("UNAUTHENTICATED")) {
                throw authFailure(error);
            }
            try {
                assertOpen();
                String fresh = authorize(true, current);
                return perform.perform(fresh);
            } catch (ApiException retryError) {
                throw authFailure(retryError);
            }
        }
    }

    private ApiException authFailure(ApiException error) {
        if (error.code().equals("UNAUTHENTICATED") || error.code().equals("FORBIDDEN")) {
            failAll(error);
        }
        return error;
    }

    private String authorize(boolean force, String stale) throws ApiException {
        synchronized (tokenLock) {
            String current;
            boolean isClosed;
            synchronized (lock) {
                current = token;
                isClosed = closed;
            }
            if (isClosed) {
                throw ApiException.closed();
            }
            // Another caller already refreshed past the token this one failed with.
            if (current != null && (!force || (stale != null && !current.equals(stale)))) {
                return current;
            }
            String fresh = userToken(force);
            Identity found;
            try {
                found = identityFor(fresh);
            } catch (ApiException error) {
                if (force || error.status() != 401) {
                    throw error;
                }
                fresh = userToken(true);
                found = identityFor(fresh);
            }
            synchronized (lock) {
                if (closed) {
                    throw ApiException.closed();
                }
                if (!found.projectId().equals(projectId)
                        || (identity != null && !found.subjectId().equals(identity.subjectId()))) {
                    throw new ApiException("FORBIDDEN", "Create a new client when changing accounts");
                }
                identity = found;
                token = fresh;
                return fresh;
            }
        }
    }

    private String userToken(boolean force) throws ApiException {
        String fresh;
        try {
            fresh = getToken.getToken(force);
        } catch (ApiException error) {
            throw error;
        } catch (Exception error) {
            throw ApiException.from(error);
        }
        assertOpen();
        if (fresh == null || !fresh.startsWith("rts_")) {
            throw new ApiException("UNAUTHENTICATED", "getToken must return a user session token");
        }
        return fresh;
    }

    private Identity identityFor(String userToken) throws ApiException {
        FyrletHttp.Envelope envelope = request("GET", "/api/v1/identity", userToken, null, null);
        JsonElement data = envelope.data();
        if (data == null || !data.isJsonObject()) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid identity response");
        }
        String project = Json.text(data.getAsJsonObject(), "project_id");
        String subject = Json.text(data.getAsJsonObject(), "subject_id");
        if (project == null || project.isEmpty() || subject == null || subject.isEmpty()) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid identity response");
        }
        return new Identity(project, subject);
    }

    private void assertOpen() throws ApiException {
        synchronized (lock) {
            if (closed) {
                throw ApiException.closed();
            }
        }
    }

    // ---- subscriptions --------------------------------------------------------------------------

    /**
     * Starts a realtime subscription. Observe it with {@link Subscription#onChange}.
     *
     * @param name the subscription name from the contract
     * @param params the subscription parameters, or {@code null}
     * @return the subscription handle
     * @throws ApiException when the client is closed
     */
    public Subscription subscribe(String name, Object params) throws ApiException {
        synchronized (lock) {
            if (closed) {
                throw ApiException.closed();
            }
            String id = newId.get();
            if (entries.containsKey(id)) {
                throw new IllegalStateException("newId returned a duplicate subscription ID");
            }
            SubscriptionEntry entry = new SubscriptionEntry(
                    id, name, params == null ? new JsonObject() : params, delta);
            entries.put(id, entry);
            if (connection != null) {
                attach(entry, connection, epoch);
            } else {
                start(false);
            }
            return new Subscription(this, entry);
        }
    }

    ListenerHandle addListener(SubscriptionEntry entry, Consumer<SubscriptionState> listener) {
        int id;
        synchronized (lock) {
            id = entry.nextListener++;
            entry.listeners.put(id, listener);
            dispatch(listener, entry.state);
        }
        return new ListenerHandle(() -> {
            synchronized (lock) {
                entry.listeners.remove(id);
            }
        });
    }

    void refresh(SubscriptionEntry entry) throws ApiException {
        PhoenixConnection current;
        synchronized (lock) {
            current = entry.connection;
            if (entry.state.status() != SubscriptionStatus.READY || current == null) {
                throw new ApiException("NOT_READY", "The subscription is not ready");
            }
        }
        CompletableFuture<Void> done = new CompletableFuture<>();
        current.push(entry.topic(), "refresh", new JsonObject(), (status, response) -> {
            if ("ok".equals(status)) {
                done.complete(null);
            } else if ("error".equals(status)) {
                done.completeExceptionally(ApiException.channel(response));
            } else {
                done.completeExceptionally(
                        new ApiException("TIMEOUT", "refresh was not acknowledged", true));
            }
        });
        try {
            done.get();
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw ApiException.network("The request was interrupted");
        } catch (ExecutionException error) {
            throw ApiException.from(error.getCause() == null ? error : error.getCause());
        }
    }

    void unsubscribe(SubscriptionEntry entry) {
        synchronized (lock) {
            if (entries.remove(entry.id) == null) {
                return;
            }
            cancelRejoin(entry);
            PhoenixConnection current = entry.connection;
            entry.connection = null;
            if (current != null) {
                current.leave(entry.topic());
            }
            entry.state = entry.state.closed();
            emit(entry);
            entry.listeners.clear();
            if (entries.isEmpty()) {
                detach();
            }
        }
    }

    /**
     * Explicitly rebuilds the connection and all retained subscriptions.
     *
     * @throws ApiException when the connection cannot be rebuilt
     */
    public void reconnect() throws ApiException {
        int currentEpoch;
        synchronized (lock) {
            if (closed) {
                throw ApiException.closed();
            }
            detach();
            recovering();
            if (entries.isEmpty()) {
                return;
            }
            currentEpoch = epoch;
        }
        try {
            connect(true, currentEpoch);
        } catch (ApiException error) {
            synchronized (lock) {
                connectionFailed(error, currentEpoch);
            }
            throw error;
        } catch (RuntimeException error) {
            synchronized (lock) {
                connectionFailed(ApiException.from(error), currentEpoch);
            }
            throw error;
        }
    }

    /** Releases subscriptions, timers and connections. The client cannot be reused. */
    @Override
    public void close() {
        synchronized (lock) {
            if (closed) {
                return;
            }
            closed = true;
            detach();
            for (SubscriptionEntry entry : entries.values()) {
                entry.state = new SubscriptionState(SubscriptionStatus.CLOSED, null, null, null, 0);
                emit(entry);
                entry.listeners.clear();
            }
            entries.clear();
            token = null;
        }
        events.shutdown();
        scheduler.shutdownNow();
        async.shutdown();
    }

    // ---- connection management (callers hold the lock unless noted) ----------------------------

    private void start(boolean force) {
        int currentEpoch = epoch;
        if (connectingEpoch == currentEpoch) {
            return;
        }
        connectingEpoch = currentEpoch;
        try {
            async.execute(() -> {
                try {
                    connect(force, currentEpoch);
                } catch (ApiException error) {
                    synchronized (lock) {
                        connectionFailed(error, currentEpoch);
                    }
                } catch (RuntimeException error) {
                    synchronized (lock) {
                        connectionFailed(ApiException.from(error), currentEpoch);
                    }
                }
            });
        } catch (RejectedExecutionException ignored) {
            // the client is shutting down
        }
    }

    /** Runs without the lock held. */
    private void connect(boolean force, int currentEpoch) throws ApiException {
        try {
            String fresh = authorize(force, null);
            synchronized (lock) {
                if (closed || epoch != currentEpoch || entries.isEmpty() || connection != null) {
                    return;
                }
            }
            PhoenixConnection opened = PhoenixConnection.open(
                    endpoint, projectId, fresh, timeout, scheduler, async, this::onFrame, this::onClose);
            synchronized (lock) {
                if (closed || epoch != currentEpoch || entries.isEmpty()) {
                    opened.close();
                    return;
                }
                connection = opened;
                for (SubscriptionEntry entry : new ArrayList<>(entries.values())) {
                    if (entry.state.status() != SubscriptionStatus.ERROR) {
                        attach(entry, opened, currentEpoch);
                    }
                }
            }
        } finally {
            synchronized (lock) {
                if (connectingEpoch == currentEpoch) {
                    connectingEpoch = -1;
                }
            }
        }
    }

    private JsonObject joinPayload(SubscriptionEntry entry) {
        JsonObject payload = new JsonObject();
        payload.addProperty("protocol_version", Wire.PROTOCOL_VERSION);
        payload.addProperty("name", entry.name);
        payload.add("params", Json.input(entry.params));
        if (!declared.isEmpty()) {
            JsonObject capabilities = new JsonObject();
            List<String> names = new ArrayList<>(declared.keySet());
            names.sort(String::compareTo);
            for (String name : names) {
                capabilities.addProperty(name, declared.get(name));
            }
            payload.add("capabilities", capabilities);
        }
        if (entry.wantDelta) {
            payload.addProperty("delivery", "delta-v1");
        }
        return payload;
    }

    private boolean isCurrent(SubscriptionEntry entry, PhoenixConnection current, int currentEpoch) {
        return !closed && epoch == currentEpoch && entry.connection == current && entries.get(entry.id) == entry;
    }

    private void attach(SubscriptionEntry entry, PhoenixConnection current, int currentEpoch) {
        entry.connection = current;
        try {
            current.join(entry.topic(), joinPayload(entry), (status, response) -> {
                synchronized (lock) {
                    if (!isCurrent(entry, current, currentEpoch)) {
                        return;
                    }
                    if ("ok".equals(status)) {
                        retries = 0;
                        entry.joinFailures = 0;
                        receive(entry, current, "snapshot", response, true);
                    } else if (!"error".equals(status)) {
                        transportFailed(current);
                    } else {
                        ApiException error = ApiException.channel(response);
                        if (error.code().equals("UNAUTHENTICATED")) {
                            transportFailed(current);
                        } else if (error.retryable() && entry.joinFailures < MAX_JOIN_RETRIES) {
                            // For example the observer was briefly unavailable: retry this subscription only.
                            entry.joinFailures++;
                            entry.state = entry.state.recovering();
                            emit(entry);
                            scheduleRejoin(entry, current, currentEpoch);
                        } else {
                            fail(entry, error);
                        }
                    }
                }
            });
        } catch (ApiException ignored) {
            // the connection already reported its failure
        }
    }

    private void scheduleRejoin(SubscriptionEntry entry, PhoenixConnection current, int currentEpoch) {
        cancelRejoin(entry);
        try {
            entry.rejoin = scheduler.schedule(() -> {
                synchronized (lock) {
                    entry.rejoin = null;
                    if (isCurrent(entry, current, currentEpoch)) {
                        attach(entry, current, currentEpoch);
                    }
                }
            }, Math.max(1L, delay(entry.joinFailures).toMillis()), TimeUnit.MILLISECONDS);
        } catch (RejectedExecutionException ignored) {
            // the client is shutting down
        }
    }

    private static void cancelRejoin(SubscriptionEntry entry) {
        if (entry.rejoin != null) {
            entry.rejoin.cancel(false);
            entry.rejoin = null;
        }
    }

    private Duration delay(int attempt) {
        if (retryDelay != null) {
            Duration custom = retryDelay.apply(attempt);
            if (custom != null) {
                return custom;
            }
        }
        int shift = Math.min(Math.max(attempt - 1, 0), 7);
        return Duration.ofMillis(Math.min(250L << shift, 30_000L));
    }

    private void onFrame(PhoenixConnection current, Wire.Frame frame) {
        synchronized (lock) {
            if (current != connection || closed || !frame.topic().startsWith("subscription:")) {
                return;
            }
            SubscriptionEntry entry = entries.get(frame.topic().substring("subscription:".length()));
            if (entry == null || entry.connection != current) {
                return;
            }
            switch (frame.event()) {
                case "snapshot" -> receive(entry, current, "snapshot", frame.payload(), false);
                case "delta" -> receive(entry, current, "delta", frame.payload(), false);
                case "status" -> {
                    ApiException error = ApiException.channel(frame.payload());
                    if (error.code().equals("UNAUTHENTICATED")) {
                        for (SubscriptionEntry item : entries.values()) {
                            item.state = new SubscriptionState(item.state.status(), null, item.state.error(),
                                    item.state.generation(), item.state.seq());
                        }
                        transportFailed(current);
                    } else if (error.retryable()) {
                        transportFailed(current);
                    } else {
                        fail(entry, error);
                    }
                }
                case "phx_error" -> transportFailed(current);
                case "phx_close" -> fail(entry,
                        new ApiException("SUBSCRIPTION_CLOSED", "The server closed the subscription"));
                default -> {
                    // Unknown events are ignored, as Phoenix permits extension events.
                }
            }
        }
    }

    private void onClose(PhoenixConnection current, ApiException failure) {
        synchronized (lock) {
            if (current != connection || closed) {
                return;
            }
            if (failure != null && !failure.retryable()) {
                failAllLocked(failure);
                return;
            }
            transportFailed(current);
        }
    }

    private void receive(SubscriptionEntry entry, PhoenixConnection current, String event, JsonObject payload,
                         boolean initial) {
        SubscriptionState before = entry.state;
        SubscriptionEntry.Applied applied;
        try {
            applied = "snapshot".equals(event)
                    ? entry.applySnapshot(payload, identity, initial)
                    : entry.applyDelta(payload);
        } catch (ApiException error) {
            fail(entry, error);
            return;
        }
        if (applied instanceof SubscriptionEntry.Reconnect) {
            transportFailed(current);
            return;
        }
        if (entry.state.seq() != before.seq() || entry.state.status() != before.status()
                || !Objects.equals(entry.state.generation(), before.generation())) {
            emit(entry);
        }
        if (applied instanceof SubscriptionEntry.Ack ack) {
            JsonObject body = new JsonObject();
            body.addProperty("g", ack.generation());
            body.addProperty("s", ack.seq());
            current.notify(entry.topic(), "ack", body);
        }
    }

    private void transportFailed(PhoenixConnection current) {
        if (current != connection || closed) {
            return;
        }
        detach();
        recovering();
        scheduleRetry();
    }

    private void connectionFailed(ApiException error, int failedEpoch) {
        if (closed || epoch != failedEpoch) {
            return;
        }
        if (!error.retryable()) {
            failAllLocked(error);
            return;
        }
        recovering();
        scheduleRetry();
    }

    private void scheduleRetry() {
        if (closed || retryTimer != null || entries.isEmpty()) {
            return;
        }
        retries++;
        try {
            retryTimer = scheduler.schedule(() -> {
                synchronized (lock) {
                    retryTimer = null;
                    if (!closed && !entries.isEmpty()) {
                        start(true);
                    }
                }
            }, Math.max(1L, delay(retries).toMillis()), TimeUnit.MILLISECONDS);
        } catch (RejectedExecutionException ignored) {
            // the client is shutting down
        }
    }

    private void recovering() {
        for (SubscriptionEntry entry : entries.values()) {
            if (entry.state.status() != SubscriptionStatus.ERROR) {
                entry.state = entry.state.recovering();
                emit(entry);
            }
        }
    }

    private void failAll(ApiException error) {
        synchronized (lock) {
            failAllLocked(error);
        }
    }

    private void failAllLocked(ApiException error) {
        detach();
        token = null;
        for (SubscriptionEntry entry : new ArrayList<>(entries.values())) {
            fail(entry, error);
        }
    }

    private void fail(SubscriptionEntry entry, ApiException error) {
        cancelRejoin(entry);
        PhoenixConnection current = entry.connection;
        entry.connection = null;
        if (current != null) {
            current.leave(entry.topic());
        }
        entry.state = entry.state.failed(error);
        emit(entry);
    }

    private void detach() {
        epoch++;
        connectingEpoch = -1;
        if (retryTimer != null) {
            retryTimer.cancel(false);
            retryTimer = null;
        }
        PhoenixConnection old = connection;
        connection = null;
        for (SubscriptionEntry entry : entries.values()) {
            cancelRejoin(entry);
            entry.connection = null;
        }
        if (old != null) {
            old.close();
        }
    }

    // ---- listener dispatch ----------------------------------------------------------------------

    private void emit(SubscriptionEntry entry) {
        for (Consumer<SubscriptionState> listener : new ArrayList<>(entry.listeners.values())) {
            dispatch(listener, entry.state);
        }
    }

    private void dispatch(Consumer<SubscriptionState> listener, SubscriptionState state) {
        try {
            events.execute(() -> {
                try {
                    listener.accept(state);
                } catch (Throwable error) {
                    try {
                        if (onListenerError != null) {
                            onListenerError.accept(error);
                        }
                    } catch (Throwable ignored) {
                        // listener callbacks must not break the client
                    }
                }
            });
        } catch (RejectedExecutionException ignored) {
            // the client is shutting down
        }
    }
}
