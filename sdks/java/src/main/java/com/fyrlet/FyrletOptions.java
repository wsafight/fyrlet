package com.fyrlet;

import java.net.http.HttpClient;
import java.time.Duration;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Consumer;
import java.util.function.IntFunction;
import java.util.function.Supplier;

/**
 * Configuration for a {@link FyrletClient}.
 *
 * <p>Required values are supplied to the constructor. Everything else has a documented default. The
 * client copies these settings when it is created, so changing the object afterwards has no effect.</p>
 */
public final class FyrletOptions {

    /** HTTP(S) base URL of the Fyrlet server. */
    public String endpoint;

    /** The project this client is bound to. */
    public String projectId;

    /** Returns a short-lived user session token beginning with {@code rts_}. */
    public TokenProvider getToken;

    /** Bounds each HTTP request and socket reply. Default 10 seconds. */
    public Duration timeout = Duration.ofSeconds(10);

    /**
     * Backoff before reconnect attempt {@code n} (1-based). When {@code null}, the delay starts at 250
     * milliseconds and doubles up to 30 seconds.
     */
    public IntFunction<Duration> retryDelay;

    /** Whether to request {@code delta-v1} patches. Set to {@code false} for full snapshots only. */
    public boolean delta = true;

    /**
     * Optional capabilities to negotiate, as name to positive version. Sorted names are sent in the
     * {@code X-Fyrlet-Capabilities} header and on channel joins.
     */
    public Map<String, Integer> capabilities = Map.of();

    /**
     * Overrides the HTTP client. It must not follow redirects, because a redirect could forward bearer
     * credentials to another host. When {@code null}, the SDK creates one.
     */
    public HttpClient httpClient;

    /** Generates idempotency keys and subscription IDs. Default: random UUIDs. */
    public Supplier<String> newId = () -> UUID.randomUUID().toString();

    /** Receives exceptions thrown by listeners. Listener failures never break the client. */
    public Consumer<Throwable> onListenerError;

    /**
     * Creates the required settings.
     *
     * @param endpoint the HTTP(S) base URL of the Fyrlet server
     * @param projectId the project this client is bound to
     * @param getToken returns a short-lived user session token
     */
    public FyrletOptions(String endpoint, String projectId, TokenProvider getToken) {
        this.endpoint = Objects.requireNonNull(endpoint, "endpoint is required");
        this.projectId = Objects.requireNonNull(projectId, "projectId is required");
        this.getToken = Objects.requireNonNull(getToken, "getToken is required");
    }
}
