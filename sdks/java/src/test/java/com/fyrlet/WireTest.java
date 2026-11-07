package com.fyrlet;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class WireTest {

    @Test
    void decodesSingleFrameAndBatch() {
        String frame = "[null,\"1\",\"t\",\"e\",{}]";
        List<Wire.Frame> single = Wire.decodeFrames(frame);
        assertEquals(1, single.size());
        assertEquals("t", single.get(0).topic());
        assertEquals("e", single.get(0).event());
        assertNull(single.get(0).joinRef());
        assertEquals("1", single.get(0).ref());

        List<Wire.Frame> batch = Wire.decodeFrames("{\"batch\":[" + frame + "," + frame + "]}");
        assertEquals(2, batch.size());
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "[]",
            "{\"batch\":[]}",
            "{\"batch\":[],\"x\":1}",
            "[1,2]",
            "[null,null,\"t\",\"e\",[]]",
            "[null,null,\"t\",\"e\",null]",
            "nope",
    })
    void rejectsInvalidFrames(String raw) {
        assertNull(Wire.decodeFrames(raw));
    }

    @Test
    void rejectsOversizedBatch() {
        StringBuilder raw = new StringBuilder("{\"batch\":[");
        String frame = "[null,\"1\",\"t\",\"e\",{}]";
        for (int index = 0; index < 65; index++) {
            if (index > 0) {
                raw.append(',');
            }
            raw.append(frame);
        }
        raw.append("]}");
        assertNull(Wire.decodeFrames(raw.toString()));
    }

    @Test
    void buildsSocketUrlAndAuthProtocol() {
        assertEquals("wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0",
                Wire.socketUrl("https://x.test", "p1"));
        assertEquals("base64url.bearer.phx.cnRzX2FiYw", Wire.authProtocol("rts_abc"));
    }

    @Test
    void validatesEndpoints() {
        assertEquals("http://localhost:4000", Wire.endpointUrl("http://localhost:4000/"));
        for (String bad : new String[]{"ftp://x", "http://u:p@x", "http://x?a=1", "http://x#f", "nope"}) {
            assertThrows(IllegalArgumentException.class, () -> Wire.endpointUrl(bad), bad);
        }
    }

    @Test
    void escapesPathSegments() {
        assertEquals("a%2Fb%20c%25", Wire.pathSegment("a/b c%"));
        assertEquals("inbox.add", Wire.pathSegment("inbox.add"));
    }
}
