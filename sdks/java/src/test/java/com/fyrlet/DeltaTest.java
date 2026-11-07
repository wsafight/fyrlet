package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonParser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

class DeltaTest {

    private static JsonElement json(String raw) {
        return JsonParser.parseString(raw);
    }

    @Test
    void changesAndClearsWithoutMutatingInput() {
        JsonElement view = json("[{\"id\":\"a\",\"text\":\"x\",\"note\":\"n\"},{\"id\":\"b\",\"text\":\"y\"}]");
        JsonElement out = Delta.apply(view, json("{\"c\":[[\"a\",{\"text\":\"z\"},[\"note\"]]]}"));

        assertEquals(json("[{\"id\":\"a\",\"text\":\"z\"},{\"id\":\"b\",\"text\":\"y\"}]"), out);
        assertEquals(json("[{\"id\":\"a\",\"text\":\"x\",\"note\":\"n\"},{\"id\":\"b\",\"text\":\"y\"}]"), view);
    }

    @Test
    void nullIsNotDeletion() {
        JsonElement out = Delta.apply(json("[{\"id\":\"a\",\"t\":1}]"), json("{\"c\":[[\"a\",{\"t\":null}]]}"));

        assertEquals(json("[{\"id\":\"a\",\"t\":null}]"), out);
    }

    @Test
    void addRemoveAndReorder() {
        JsonElement out = Delta.apply(json("[{\"id\":\"a\"},{\"id\":\"b\"}]"),
                json("{\"r\":[\"a\"],\"a\":[{\"id\":\"c\"}],\"o\":[\"c\",\"b\"]}"));

        assertNotNull(out);
        assertEquals(json("[{\"id\":\"c\"},{\"id\":\"b\"}]"), out);
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "{\"x\":[]}",
            "{\"r\":[\"missing\"],\"o\":[\"a\"]}",
            "{\"a\":[{\"id\":\"a\"}],\"o\":[\"a\"]}",
            "{\"c\":[[\"a\",{\"id\":\"a\"}]]}",
            "{\"c\":[[\"a\",{\"t\":1},[\"t\"]]]}",
            "{\"c\":[[\"a\",{\"t\":1}],[\"a\",{\"t\":2}]]}",
            "{\"r\":[\"a\"]}",
            "{\"c\":[[\"zzz\",{\"t\":1}]]}",
    })
    void rejectsInvalidPatches(String patch) {
        assertNull(Delta.apply(json("[{\"id\":\"a\",\"t\":0}]"), json(patch)));
    }
}
