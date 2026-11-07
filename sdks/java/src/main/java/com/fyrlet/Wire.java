package com.fyrlet;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/** Phoenix v2 transport helpers: frame validation, socket URL and bearer subprotocol. */
final class Wire {

    static final int PROTOCOL_VERSION = 1;
    static final int MAX_BATCH = 64;
    static final int MAX_MESSAGE_BYTES = 4 << 20;

    private Wire() {
    }

    /**
     * One Phoenix v2 JSON frame {@code [join_ref, ref, topic, event, payload]}.
     *
     * @param joinRef the join reference, or {@code null}
     * @param ref the message reference, or {@code null}
     * @param topic the channel topic
     * @param event the event name
     * @param payload the non-null object payload
     */
    record Frame(String joinRef, String ref, String topic, String event, JsonObject payload) {
    }

    /**
     * Decodes one frame or a {@code {"batch":[...]}} wrapper, validating every member before dispatch.
     *
     * @param raw the raw text message
     * @return the decoded frames, or {@code null} when any part is invalid
     */
    static List<Frame> decodeFrames(String raw) {
        JsonElement root = Json.parse(raw);
        if (root == null) {
            return null;
        }
        List<JsonElement> members = new ArrayList<>();
        if (root.isJsonObject()) {
            JsonObject wrapper = root.getAsJsonObject();
            if (wrapper.size() != 1 || !wrapper.has("batch")) {
                return null;
            }
            JsonElement batch = wrapper.get("batch");
            if (batch == null || !batch.isJsonArray()) {
                return null;
            }
            for (JsonElement member : batch.getAsJsonArray()) {
                members.add(member);
            }
        } else {
            members.add(root);
        }
        if (members.isEmpty() || members.size() > MAX_BATCH) {
            return null;
        }

        List<Frame> frames = new ArrayList<>(members.size());
        for (JsonElement member : members) {
            if (member == null || !member.isJsonArray()) {
                return null;
            }
            JsonArray parts = member.getAsJsonArray();
            if (parts.size() != 5) {
                return null;
            }
            String joinRef = reference(parts.get(0));
            String ref = reference(parts.get(1));
            if (joinRef == null && !parts.get(0).isJsonNull()) {
                return null;
            }
            if (ref == null && !parts.get(1).isJsonNull()) {
                return null;
            }
            if (!Json.isString(parts.get(2)) || !Json.isString(parts.get(3))) {
                return null;
            }
            JsonElement payload = parts.get(4);
            if (payload == null || !payload.isJsonObject()) {
                return null;
            }
            frames.add(new Frame(joinRef, ref, parts.get(2).getAsString(), parts.get(3).getAsString(),
                    payload.getAsJsonObject()));
        }
        return frames;
    }

    private static String reference(JsonElement value) {
        return value != null && value.isJsonPrimitive() && value.getAsJsonPrimitive().isString()
                ? value.getAsString() : null;
    }

    /** Builds the authenticated socket URL for a project. */
    static String socketUrl(String endpoint, String projectId) {
        return "ws" + endpoint.substring("http".length()) + "/socket/websocket?project_id="
                + URLEncoder.encode(projectId, StandardCharsets.UTF_8) + "&vsn=2.0.0";
    }

    /** Encodes a user token as the Phoenix bearer subprotocol value. */
    static String authProtocol(String token) {
        return "base64url.bearer.phx." + Base64.getUrlEncoder().withoutPadding()
                .encodeToString(token.getBytes(StandardCharsets.UTF_8));
    }

    /**
     * Escapes one path segment so that reserved characters, including {@code /} and {@code %}, cannot
     * change the request path.
     *
     * @param value the raw segment
     * @return the escaped segment
     */
    static String pathSegment(String value) {
        byte[] bytes = (value == null ? "" : value).getBytes(StandardCharsets.UTF_8);
        StringBuilder escaped = new StringBuilder(bytes.length);
        for (byte raw : bytes) {
            int valueByte = raw & 0xff;
            if ((valueByte >= 'A' && valueByte <= 'Z') || (valueByte >= 'a' && valueByte <= 'z')
                    || (valueByte >= '0' && valueByte <= '9') || valueByte == '-' || valueByte == '_'
                    || valueByte == '.' || valueByte == '~') {
                escaped.append((char) valueByte);
            } else {
                escaped.append('%');
                escaped.append(Character.toUpperCase(Character.forDigit(valueByte >> 4, 16)));
                escaped.append(Character.toUpperCase(Character.forDigit(valueByte & 0x0f, 16)));
            }
        }
        return escaped.toString();
    }

    /**
     * Validates and normalizes an HTTP(S) base URL.
     *
     * @param endpoint the configured endpoint
     * @return the endpoint without trailing slashes
     * @throws IllegalArgumentException when the endpoint is not an HTTP(S) base URL
     */
    static String endpointUrl(String endpoint) {
        URI uri;
        try {
            uri = new URI(endpoint == null ? "" : endpoint);
        } catch (Exception error) {
            throw new IllegalArgumentException(
                    "endpoint must be an HTTP(S) base URL without credentials, query or fragment", error);
        }
        String scheme = uri.getScheme();
        if (scheme == null || !(scheme.equals("http") || scheme.equals("https")) || uri.getHost() == null
                || uri.getHost().isEmpty() || uri.getRawUserInfo() != null
                || (uri.getRawQuery() != null && !uri.getRawQuery().isEmpty())
                || (uri.getRawFragment() != null && !uri.getRawFragment().isEmpty())) {
            throw new IllegalArgumentException(
                    "endpoint must be an HTTP(S) base URL without credentials, query or fragment");
        }
        int end = endpoint.length();
        while (end > 0 && endpoint.charAt(end - 1) == '/') {
            end--;
        }
        return endpoint.substring(0, end);
    }
}
