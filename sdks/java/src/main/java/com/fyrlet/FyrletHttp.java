package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.Flow;

/** HTTP envelope handling on top of the JDK client. */
final class FyrletHttp {

    static final int MAX_RESPONSE_BYTES = 16 << 20;

    private FyrletHttp() {
    }

    /**
     * One decoded response envelope.
     *
     * @param data the {@code data} member, which may be JSON null
     * @param outcome the operation outcome, or {@code null}
     * @param requestId the server request identifier, or {@code null}
     */
    record Envelope(JsonElement data, String outcome, String requestId) {
    }

    /** Creates a redirect-free client with a connect timeout. */
    static HttpClient newHttpClient(Duration timeout) {
        HttpClient.Builder builder = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER);
        if (timeout != null && !timeout.isZero() && !timeout.isNegative()) {
            builder.connectTimeout(timeout);
        }
        return builder.build();
    }

    /** Rejects an injected client that could forward bearer credentials through a redirect. */
    static void requireNoRedirects(HttpClient client) {
        if (client.followRedirects() != HttpClient.Redirect.NEVER) {
            throw new IllegalArgumentException("the injected HttpClient must not follow redirects");
        }
    }

    /**
     * Performs one request and decodes its JSON envelope.
     *
     * @param client the HTTP client
     * @param method the HTTP method
     * @param target the absolute target URL
     * @param headers request headers
     * @param body the JSON body, or {@code null}
     * @param timeout the per-request timeout
     * @return the decoded envelope
     * @throws ApiException on transport, timeout, HTTP or protocol failures
     */
    static Envelope send(HttpClient client, String method, String target, Map<String, String> headers,
                         JsonElement body, Duration timeout) throws ApiException {
        HttpRequest.Builder builder;
        try {
            builder = HttpRequest.newBuilder(URI.create(target));
            builder.header("accept", "application/json");
            builder.timeout(timeout);
            if (body != null) {
                builder.header("content-type", "application/json");
            }
            for (Map.Entry<String, String> header : headers.entrySet()) {
                builder.header(header.getKey(), header.getValue());
            }
            HttpRequest.BodyPublisher publisher = body == null
                    ? HttpRequest.BodyPublishers.noBody()
                    : HttpRequest.BodyPublishers.ofString(Json.GSON.toJson(body), StandardCharsets.UTF_8);
            builder.method(method, publisher);
        } catch (IllegalArgumentException error) {
            throw new ApiException("HTTP_ERROR", "The request was rejected");
        }

        HttpResponse<byte[]> response;
        try {
            response = client.send(builder.build(), info -> new LimitedBodySubscriber(MAX_RESPONSE_BYTES));
        } catch (HttpTimeoutException error) {
            throw new ApiException("TIMEOUT", "The request timed out", true);
        } catch (IOException error) {
            throw ApiException.network();
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw ApiException.network("The request was interrupted");
        } catch (IllegalArgumentException error) {
            throw new ApiException("HTTP_ERROR", "The request was rejected");
        }

        int status = response.statusCode();
        JsonElement root = Json.parse(new String(response.body(), StandardCharsets.UTF_8));
        if (root == null || !root.isJsonObject()) {
            throw new ApiException("PROTOCOL_ERROR", "Expected a JSON response", false, status, null,
                    new JsonObject(), null);
        }
        JsonObject envelope = root.getAsJsonObject();
        String requestId = Json.text(envelope, "request_id");
        JsonElement error = envelope.get("error");
        boolean hasError = error != null && !error.isJsonNull();

        if (status < 200 || status >= 300 || hasError) {
            if (hasError) {
                throw ApiException.fromWire(error, status, requestId);
            }
            throw new ApiException("HTTP_ERROR", "The request was rejected", false, status, requestId,
                    new JsonObject(), null);
        }
        if (!envelope.has("data")) {
            throw new ApiException("PROTOCOL_ERROR", "Missing response data", false, status, null,
                    new JsonObject(), null);
        }
        return new Envelope(envelope.get("data"), Json.text(envelope, "outcome"), requestId);
    }

    /** A body subscriber that keeps at most {@code max} bytes and completes once the body ends. */
    private static final class LimitedBodySubscriber implements HttpResponse.BodySubscriber<byte[]> {

        private final int max;
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> body = new CompletableFuture<>();

        LimitedBodySubscriber(int max) {
            this.max = max;
        }

        @Override
        public CompletionStage<byte[]> getBody() {
            return body;
        }

        @Override
        public void onSubscribe(Flow.Subscription subscription) {
            subscription.request(Long.MAX_VALUE);
        }

        @Override
        public void onNext(List<ByteBuffer> items) {
            int remaining = max - bytes.size();
            for (ByteBuffer item : items) {
                int length = item.remaining();
                if (remaining <= 0) {
                    item.position(item.limit());
                    continue;
                }
                int take = Math.min(length, remaining);
                byte[] chunk = new byte[take];
                item.get(chunk, 0, take);
                bytes.write(chunk, 0, take);
                remaining -= take;
                if (item.hasRemaining()) {
                    item.position(item.limit());
                }
            }
        }

        @Override
        public void onError(Throwable error) {
            body.completeExceptionally(error);
        }

        @Override
        public void onComplete() {
            body.complete(bytes.toByteArray());
        }
    }
}
