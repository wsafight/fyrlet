package fyrlet

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class WireTest {
    private val frame = """[null,"1","t","e",{}]"""

    @Test
    fun `decodes a single frame`() {
        val frames = Wire.decodeFrames(frame)
        assertNotNull(frames)
        assertEquals(1, frames.size)
        assertEquals("t", frames[0].topic)
        assertEquals("e", frames[0].event)
        assertNull(frames[0].joinRef)
        assertEquals("1", frames[0].ref)
    }

    @Test
    fun `decodes a batch in array order`() {
        val frames = Wire.decodeFrames("""{"batch":[$frame,$frame]}""")
        assertNotNull(frames)
        assertEquals(2, frames.size)
        assertNull(Wire.decodeFrames("""{"batch":[$frame]}""")!![0].joinRef)
    }

    @Test
    fun `rejects malformed and invalid batches`() {
        val sixtyFive = (1..65).joinToString(",", """{"batch":[""", "]}") { frame }
        for (bad in listOf(
            """[]""",
            """{"batch":[]}""",
            sixtyFive,
            """{"batch":[$frame],"x":1}""",
            """[1,2]""",
            """[null,null,"t","e",[]]""",
            """[null,null,"t","e",null]""",
            """nope""",
            """{"batch":{}}""",
            """{}""",
        )) {
            assertNull(Wire.decodeFrames(bad), "accepted ${bad.take(40)}")
        }
    }

    @Test
    fun `socket URL and auth protocol`() {
        assertEquals(
            "wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0",
            Wire.socketUrl("https://x.test", "p1"),
        )
        assertEquals(
            "ws://x.test/socket/websocket?project_id=p1&vsn=2.0.0",
            Wire.socketUrl("http://x.test", "p1"),
        )
        assertEquals("base64url.bearer.phx.cnRzX2FiYw", Wire.authProtocol("rts_abc"))
    }

    @Test
    fun `endpoint validation`() {
        assertEquals("http://localhost:4000", FyrletHttp.endpointUrl("http://localhost:4000/"))
        for (bad in listOf("ftp://x", "http://u:p@x", "http://x?a=1", "http://x#f", "nope", "http://")) {
            assertFailsWith<IllegalArgumentException>("accepted $bad") { FyrletHttp.endpointUrl(bad) }
        }
    }

    @Test
    fun `path escape leaves unreserved characters and encodes the rest`() {
        assertEquals("inbox.add", FyrletHttp.pathEscape("inbox.add"))
        assertEquals("a%2Fb", FyrletHttp.pathEscape("a/b"))
        assertEquals("a%20b", FyrletHttp.pathEscape("a b"))
    }
}
