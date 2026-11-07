package com.fyrlet;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SubscriptionEntryTest {

    private static final Identity WHO = new Identity("p", "u");

    private static JsonObject snapshot(String... overrides) {
        JsonObject base = JsonParser.parseString("""
                {"protocol_version":1,"subscription_id":"s","project_id":"p","subject_id":"u",
                 "generation":"g1","seq":1,"data":[{"id":"a"}],"delivery":"delta-v1"}
                """).getAsJsonObject();
        for (int index = 0; index + 1 < overrides.length; index += 2) {
            base.add(overrides[index], JsonParser.parseString(overrides[index + 1]));
        }
        return base;
    }

    private static SubscriptionEntry entry() {
        return new SubscriptionEntry("s", "n", new JsonObject(), true);
    }

    private static JsonObject delta(String raw) {
        return JsonParser.parseString(raw).getAsJsonObject();
    }

    @Test
    void snapshotAndDeltaFlow() throws ApiException {
        SubscriptionEntry subject = entry();
        SubscriptionEntry.Applied applied = subject.applySnapshot(snapshot(), WHO, true);

        assertEquals(new SubscriptionEntry.Ack("g1", 1), applied);
        assertEquals(SubscriptionStatus.READY, subject.state.status());
        assertEquals(1, subject.state.seq());

        applied = subject.applyDelta(delta("{\"g\":\"g1\",\"b\":1,\"s\":2,\"p\":{\"c\":[[\"a\",{\"t\":1}]]}}"));
        assertEquals(new SubscriptionEntry.Ack("g1", 2), applied);
        assertEquals(2, subject.state.seq());
        assertEquals(JsonParser.parseString("[{\"id\":\"a\",\"t\":1}]"), subject.state.data());

        // A duplicate is re-acknowledged; another generation is ignored; a gap asks for a reconnect.
        assertEquals(new SubscriptionEntry.Ack("g1", 2),
                subject.applyDelta(delta("{\"g\":\"g1\",\"b\":1,\"s\":2,\"p\":{}}")));
        assertEquals(SubscriptionEntry.Nothing.INSTANCE,
                subject.applyDelta(delta("{\"g\":\"old\",\"b\":1,\"s\":2,\"p\":{}}")));
        assertEquals(SubscriptionEntry.Reconnect.INSTANCE,
                subject.applyDelta(delta("{\"g\":\"g1\",\"b\":3,\"s\":4,\"p\":{}}")));
    }

    @Test
    void rejectsForeignSnapshots() {
        for (String[] overrides : new String[][]{
                {"subject_id", "\"other\""},
                {"subscription_id", "\"x\""},
                {"seq", "0"},
                {"protocol_version", "2"},
        }) {
            SubscriptionEntry subject = entry();
            ApiException error = assertThrows(ApiException.class,
                    () -> subject.applySnapshot(snapshot(overrides), WHO, true));
            assertEquals("PROTOCOL_ERROR", error.code());
        }
    }

    @Test
    void rejectsDeltaThatWasNotNegotiated() throws ApiException {
        SubscriptionEntry subject = entry();
        subject.applySnapshot(snapshot("delivery", "\"snapshot\""), WHO, true);
        ApiException error = assertThrows(ApiException.class,
                () -> subject.applyDelta(delta("{\"g\":\"g1\",\"b\":1,\"s\":2,\"p\":{}}")));
        assertEquals("PROTOCOL_ERROR", error.code());
    }

    @Test
    void decodesStateIntoUserType() throws ApiException {
        SubscriptionEntry subject = entry();
        subject.applySnapshot(snapshot(), WHO, true);

        Item[] items = subject.state.decode(Item[].class);
        assertEquals(1, items.length);
        assertEquals("a", items[0].id);
    }

    static final class Item {
        String id;
        String text;
    }
}
