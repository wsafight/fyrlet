package com.fyrlet;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.google.gson.JsonPrimitive;

import java.math.BigDecimal;

/** Small JSON helpers shared by the SDK. */
final class Json {

    static final Gson GSON = new Gson();

    /** JavaScript's largest exactly representable integer, {@code 2^53}. */
    private static final BigDecimal MAX_SAFE_INTEGER = new BigDecimal("9007199254740992");

    private Json() {
    }

    static JsonObject object() {
        return new JsonObject();
    }

    /** Serializes a caller value, mapping {@code null} to an empty object. */
    static JsonElement input(Object value) {
        return value == null ? new JsonObject() : GSON.toJsonTree(value);
    }

    /** Parses a JSON text, or returns {@code null} when the text is not valid JSON. */
    static JsonElement parse(String raw) {
        try {
            return JsonParser.parseString(raw);
        } catch (RuntimeException error) {
            return null;
        }
    }

    /**
     * Reads an integral JSON number that fits in a JavaScript safe integer, or {@code null} when the value
     * is absent, not a number, fractional or out of range.
     */
    static Long integer(JsonElement value) {
        if (value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isNumber()) {
            return null;
        }
        BigDecimal decimal;
        try {
            decimal = value.getAsBigDecimal();
        } catch (NumberFormatException | ArithmeticException error) {
            return null;
        }
        if (decimal.stripTrailingZeros().scale() > 0 || decimal.abs().compareTo(MAX_SAFE_INTEGER) > 0) {
            return null;
        }
        try {
            return decimal.longValueExact();
        } catch (ArithmeticException error) {
            return null;
        }
    }

    static Long integer(JsonObject object, String key) {
        return object == null ? null : integer(object.get(key));
    }

    /** Returns the string value of {@code key}, or {@code null} when absent or not a JSON string. */
    static String text(JsonObject object, String key) {
        if (object == null) {
            return null;
        }
        JsonElement value = object.get(key);
        if (value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString()) {
            return null;
        }
        return value.getAsString();
    }

    static boolean isString(JsonElement value) {
        return value != null && value.isJsonPrimitive() && value.getAsJsonPrimitive().isString();
    }

    static JsonArray array() {
        return new JsonArray();
    }

    static JsonPrimitive primitive(String value) {
        return new JsonPrimitive(value);
    }

    static JsonPrimitive primitive(Number value) {
        return new JsonPrimitive(value);
    }
}
