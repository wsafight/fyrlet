package fyrlet

import com.google.gson.JsonElement
import com.google.gson.JsonParser
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

internal fun json(text: String): JsonElement = JsonParser.parseString(text)

class DeltaTest {
    @Test
    fun `changes and clears without mutating the input view`() {
        val view = json("""[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]""")
        val out = Delta.apply(view, json("""{"c":[["a",{"text":"z"},["note"]]]}"""))
        assertNotNull(out)
        assertEquals(json("""[{"id":"a","text":"z"},{"id":"b","text":"y"}]"""), out)
        // The delivered view is read-only: a later delta never modifies it.
        assertEquals(json("""[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]"""), view)
    }

    @Test
    fun `null is not deletion and reorder is applied`() {
        val kept = Delta.apply(json("""[{"id":"a","t":1}]"""), json("""{"c":[["a",{"t":null}]]}"""))
        assertNotNull(kept)
        val record = kept.asJsonArray[0].asJsonObject
        assertEquals(2, record.size())
        assertEquals(com.google.gson.JsonNull.INSTANCE, record.get("t"))

        val reordered = Delta.apply(
            json("""[{"id":"a"},{"id":"b"}]"""),
            json("""{"r":["a"],"a":[{"id":"c"}],"o":["c","b"]}"""),
        )
        assertNotNull(reordered)
        assertEquals("c", reordered.asJsonArray[0].asJsonObject.get("id").asString)
        assertEquals("b", reordered.asJsonArray[1].asJsonObject.get("id").asString)
    }

    @Test
    fun `rejects invalid patches`() {
        val view = json("""[{"id":"a","t":0}]""")
        for (patch in listOf(
            """{"x":[]}""",
            """{"r":["missing"],"o":["a"]}""",
            """{"a":[{"id":"a"}],"o":["a"]}""",
            """{"c":[["a",{"id":"a"}]]}""",
            """{"c":[["a",{"t":1},["t"]]]}""",
            """{"c":[["a",{"t":1}],["a",{"t":2}]]}""",
            """{"r":["a"]}""",
            """{"c":[["zzz",{"t":1}]]}""",
        )) {
            assertNull(Delta.apply(view, json(patch)), "accepted $patch")
        }
        // Not an array view, not an object patch, and a patch over the item limit.
        assertNull(Delta.apply(json("""{"id":"a"}"""), json("""{"c":[]}""")))
        assertNull(Delta.apply(view, json("""[]""")))
        val many = (1..101).joinToString(",", "[", "]") { """{"id":"$it"}""" }
        assertNull(Delta.apply(view, json("""{"a":$many}""")))
    }
}
