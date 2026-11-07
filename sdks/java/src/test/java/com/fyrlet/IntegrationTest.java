package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.Authenticator;
import java.net.CookieHandler;
import java.net.ProxySelector;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpResponse.BodyHandler;
import java.net.http.HttpResponse.PushPromiseHandler;
import java.net.http.WebSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Runs against a real Fyrlet inbox server. Start it with scripts/integration_sdks.sh; every test is
 * skipped when {@code INTEGRATION_ENDPOINT} or {@code INTEGRATION_FIXTURES} is unset.
 */
class IntegrationTest {

    private static final String ENDPOINT = System.getenv("INTEGRATION_ENDPOINT");
    private static final String FIXTURES = System.getenv("INTEGRATION_FIXTURES");

    @BeforeEach
    void requireServer() {
        Assumptions.assumeTrue(ENDPOINT != null && !ENDPOINT.isEmpty() && FIXTURES != null
                && !FIXTURES.isEmpty(), "needs INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES");
    }

    static final class Project {
        String projectId;
        String serviceKey;

        Project(String projectId, String serviceKey) {
            this.projectId = projectId;
            this.serviceKey = serviceKey;
        }
    }

    static final class Item {
        String id;
        String text;
        int version;
    }

    static final class History {
        List<Item> items;
    }

    private record Fixture(FyrletClient client, UserSession session, SessionService service) {
    }

    private static List<Project> projects() throws IOException {
        JsonElement root = JsonParser.parseString(Files.readString(Path.of(FIXTURES)));
        List<Project> projects = new ArrayList<>();
        for (JsonElement element : root.getAsJsonArray()) {
            JsonObject object = element.getAsJsonObject();
            projects.add(new Project(object.get("project_id").getAsString(),
                    object.get("service_key").getAsString()));
        }
        return projects;
    }

    private static Fixture user(int projectIndex, String subject) throws Exception {
        List<Project> projects = projects();
        Project project = projects.get(projectIndex);
        SessionService service = new SessionService(ENDPOINT, project.serviceKey);
        UserSession session = service.issueSession(
                subject == null ? "user-" + UUID.randomUUID() : subject, null, 600);
        FyrletOptions options = new FyrletOptions(ENDPOINT, project.projectId, force -> session.token());
        options.retryDelay = attempt -> Duration.ofMillis(50);
        return new Fixture(new FyrletClient(options), session, service);
    }

    private static void until(String what, BooleanSupplier condition) {
        long deadline = System.nanoTime() + Duration.ofSeconds(10).toNanos();
        while (System.nanoTime() < deadline) {
            if (condition.getAsBoolean()) {
                return;
            }
            try {
                Thread.sleep(20);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("interrupted while waiting for " + what, error);
            }
        }
        throw new AssertionError("condition not reached: " + what);
    }

    private static void ready(Subscription subscription) {
        until("subscription ready", () -> subscription.state().status() == SubscriptionStatus.READY);
    }

    private static List<Item> items(Subscription subscription) {
        Item[] decoded = subscription.state().decode(Item[].class);
        return decoded == null ? List.of() : Arrays.asList(decoded);
    }

    @Test
    void callIdempotencyConflictAndContract() throws Exception {
        Fixture fixture = user(0, null);
        try (FyrletClient client = fixture.client) {
            String key = "key-" + UUID.randomUUID();
            Item first = client.callInto("inbox.add", java.util.Map.of("text", "hello"), Item.class, key);
            Item again = client.callInto("inbox.add", java.util.Map.of("text", "hello"), Item.class, key);
            assertEquals(first.id, again.id);

            ApiException conflict = assertThrows(ApiException.class,
                    () -> client.call("inbox.add", java.util.Map.of("text", "changed"), key));
            assertEquals("CONFLICT", conflict.code());
            assertEquals(409, conflict.status());

            History history = client.callInto("inbox.history", null, History.class);
            assertEquals(1, history.items.size());

            client.call("inbox.update",
                    java.util.Map.of("id", first.id, "text", "new", "expected_version", first.version));
            ApiException stale = assertThrows(ApiException.class, () -> client.call("inbox.update",
                    java.util.Map.of("id", first.id, "text", "late", "expected_version", first.version)));
            assertEquals("CONFLICT", stale.code());

            assertTrue(client.contract().toString().contains("inbox.add"));
        }
    }

    @Test
    void subscriptionSnapshotDeltaRefreshAndSharedDevices() throws Exception {
        String subject = "shared-" + UUID.randomUUID();
        Fixture leftFixture = user(0, subject);
        Fixture rightFixture = user(0, subject);
        try (FyrletClient leftClient = leftFixture.client; FyrletClient rightClient = rightFixture.client) {
            Subscription left = leftClient.subscribe("inbox.recent", null);
            Subscription right = rightClient.subscribe("inbox.recent", null);
            ready(left);
            ready(right);

            List<SubscriptionStatus> seen = Collections.synchronizedList(new ArrayList<>());
            left.onChange(state -> seen.add(state.status()));

            Item created = leftClient.callInto("inbox.add", java.util.Map.of("text", "shared"), Item.class);
            until("left sees the item", () -> items(left).stream()
                    .anyMatch(item -> item.id.equals(created.id) && "shared".equals(item.text)));
            until("right sees the item", () -> items(right).stream()
                    .anyMatch(item -> item.id.equals(created.id) && "shared".equals(item.text)));

            leftClient.call("inbox.update", java.util.Map.of(
                    "id", created.id, "text", "edited", "expected_version", created.version));
            until("delta applied", () -> items(left).stream()
                    .anyMatch(item -> "edited".equals(item.text)));

            long before = left.state().seq();
            left.refresh();
            until("refresh snapshot", () -> left.state().seq() > before);
            until("listener saw the current state", () -> !seen.isEmpty());
            assertEquals(SubscriptionStatus.READY, seen.get(0));

            left.unsubscribe();
            assertEquals(SubscriptionStatus.CLOSED, left.state().status());
            assertNull(left.state().data());
            ApiException notReady = assertThrows(ApiException.class, left::refresh);
            assertEquals("NOT_READY", notReady.code());
        }
    }

    @Test
    void authorizationIsolation() throws Exception {
        Fixture owner = user(0, null);
        try (FyrletClient client = owner.client) {
            client.call("inbox.add", java.util.Map.of("text", "private"));
        }
        Fixture other = user(0, null);
        Fixture foreign = user(1, null);
        for (Fixture fixture : List.of(other, foreign)) {
            try (FyrletClient client = fixture.client) {
                Subscription subscription = client.subscribe("inbox.recent", null);
                ready(subscription);
                assertTrue(items(subscription).isEmpty(), "subscription leaked another user's data");
                History history = client.callInto("inbox.history", null, History.class);
                assertTrue(history.items.isEmpty());
            }
        }
    }

    @Test
    void lostResponseIsUnknownThenRecoveredWithoutSecondWrite() throws Exception {
        List<Project> projects = projects();
        Project project = projects.get(0);
        SessionService service = new SessionService(ENDPOINT, project.serviceKey);
        UserSession session = service.issueSession("lost-" + UUID.randomUUID(), null, 600);
        LossyHttpClient transport = new LossyHttpClient(
                HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build());
        FyrletOptions options = new FyrletOptions(ENDPOINT, project.projectId, force -> session.token());
        options.httpClient = transport;
        try (FyrletClient client = new FyrletClient(options)) {
            Mutation mutation = client.mutate("inbox.add", java.util.Map.of("text", "lost"));
            assertEquals(MutationStatus.UNKNOWN, mutation.state().status());
            assertInstanceOf(OutcomeUnknownException.class, mutation.state().error());

            MutationState recovered = mutation.recover();
            assertEquals(MutationStatus.COMMITTED, recovered.status());
            Item item = Json.GSON.fromJson(recovered.data(), Item.class);
            assertEquals("lost", item.text);
            assertEquals(1, transport.writes.get());

            Fixture stranger = user(0, null);
            try (FyrletClient other = stranger.client) {
                RecoveryResult found = other.recover("inbox.add",
                        java.util.Map.of("text", "lost"), mutation.idempotencyKey());
                assertEquals(MutationStatus.UNKNOWN, found.status());
            }
        }
    }

    @Test
    void tokenRefreshAndRevocation() throws Exception {
        List<Project> projects = projects();
        Project project = projects.get(0);
        SessionService service = new SessionService(ENDPOINT, project.serviceKey);
        String subject = "refresh-" + UUID.randomUUID();
        UserSession old = service.issueSession(subject, null, 600);
        assertTrue(service.revokeSession(old.sessionId()));

        List<Boolean> calls = Collections.synchronizedList(new ArrayList<>());
        FyrletOptions options = new FyrletOptions(ENDPOINT, project.projectId, force -> {
            calls.add(force);
            return force ? service.issueSession(subject, null, 600).token() : old.token();
        });
        try (FyrletClient client = new FyrletClient(options)) {
            client.call("inbox.history", null);
            assertEquals(List.of(false, true), calls);
        }

        UserSession live = service.issueSession(subject, null, 600);
        FyrletOptions deadOptions = new FyrletOptions(ENDPOINT, project.projectId, force -> {
            if (force) {
                throw new ApiException("UNAUTHENTICATED", "logged out");
            }
            return live.token();
        });
        deadOptions.retryDelay = attempt -> Duration.ofMillis(50);
        try (FyrletClient dead = new FyrletClient(deadOptions)) {
            Subscription subscription = dead.subscribe("inbox.recent", null);
            ready(subscription);
            service.revokeSession(live.sessionId());
            until("terminal error", () -> subscription.state().status() == SubscriptionStatus.ERROR);
            SubscriptionState state = subscription.state();
            assertNull(state.data());
            assertEquals("UNAUTHENTICATED", state.error().code());
        }
    }

    @Test
    void accountSwitchIsRejected() throws Exception {
        List<Project> projects = projects();
        Project project = projects.get(0);
        SessionService service = new SessionService(ENDPOINT, project.serviceKey);
        UserSession a = service.issueSession("a-" + UUID.randomUUID(), null, 600);
        UserSession b = service.issueSession("b-" + UUID.randomUUID(), null, 600);
        FyrletOptions options = new FyrletOptions(ENDPOINT, project.projectId,
                force -> force ? b.token() : a.token());
        try (FyrletClient client = new FyrletClient(options)) {
            client.call("inbox.history", null);
            service.revokeSession(a.sessionId());
            ApiException error = assertThrows(ApiException.class, () -> client.call("inbox.history", null));
            assertEquals("FORBIDDEN", error.code());
        }
    }

    @Test
    void reconnectAndCloseReleaseResources() throws Exception {
        Fixture fixture = user(0, null);
        FyrletClient client = fixture.client;
        try (FyrletClient closeable = client) {
            Subscription subscription = client.subscribe("inbox.recent", null);
            ready(subscription);
            Item created = client.callInto("inbox.add", java.util.Map.of("text", "before"), Item.class);
            until("item arrives", () -> items(subscription).size() == 1);

            String generation = subscription.state().generation();
            client.reconnect();
            ready(subscription);
            until("new generation", () -> !generation.equals(subscription.state().generation()));
            assertEquals(1, items(subscription).size());
            assertEquals(created.id, items(subscription).get(0).id);

            client.close();
            assertEquals(SubscriptionStatus.CLOSED, subscription.state().status());
            ApiException closed = assertThrows(ApiException.class, () -> client.call("inbox.history", null));
            assertEquals("CLIENT_CLOSED", closed.code());
            ApiException subscribeClosed = assertThrows(ApiException.class,
                    () -> client.subscribe("inbox.recent", null));
            assertEquals("CLIENT_CLOSED", subscribeClosed.code());
        }
    }

    /** Drops the response to {@code inbox.add} after the server committed it. */
    static final class LossyHttpClient extends HttpClient {

        private final HttpClient delegate;
        final AtomicInteger writes = new AtomicInteger();

        LossyHttpClient(HttpClient delegate) {
            this.delegate = delegate;
        }

        @Override
        public Optional<CookieHandler> cookieHandler() {
            return delegate.cookieHandler();
        }

        @Override
        public Optional<Duration> connectTimeout() {
            return delegate.connectTimeout();
        }

        @Override
        public Redirect followRedirects() {
            return delegate.followRedirects();
        }

        @Override
        public Optional<ProxySelector> proxy() {
            return delegate.proxy();
        }

        @Override
        public SSLContext sslContext() {
            return delegate.sslContext();
        }

        @Override
        public SSLParameters sslParameters() {
            return delegate.sslParameters();
        }

        @Override
        public Optional<Authenticator> authenticator() {
            return delegate.authenticator();
        }

        @Override
        public Version version() {
            return delegate.version();
        }

        @Override
        public Optional<Executor> executor() {
            return delegate.executor();
        }

        @Override
        public <T> HttpResponse<T> send(HttpRequest request, BodyHandler<T> handler)
                throws IOException, InterruptedException {
            HttpResponse<T> response = delegate.send(request, handler);
            if (request.uri().getPath().endsWith("/operations/inbox.add")) {
                writes.incrementAndGet();
                throw new IOException("injected response loss after commit");
            }
            return response;
        }

        @Override
        public <T> CompletableFuture<HttpResponse<T>> sendAsync(HttpRequest request, BodyHandler<T> handler) {
            return delegate.sendAsync(request, handler);
        }

        @Override
        public <T> CompletableFuture<HttpResponse<T>> sendAsync(HttpRequest request, BodyHandler<T> handler,
                                                                PushPromiseHandler<T> pushPromiseHandler) {
            return delegate.sendAsync(request, handler, pushPromiseHandler);
        }

        @Override
        public WebSocket.Builder newWebSocketBuilder() {
            return delegate.newWebSocketBuilder();
        }
    }
}
