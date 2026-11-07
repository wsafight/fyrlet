package fyrlet

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class EntryTest {
    private val who = Identity("p", "u")

    private fun snapshot(vararg overrides: Pair<String, JsonElement>): JsonObject {
        val base = JsonObject()
        base.addProperty("protocol_version", 1)
        base.addProperty("subscription_id", "s")
        base.addProperty("project_id", "p")
        base.addProperty("subject_id", "u")
        base.addProperty("generation", "g1")
        base.addProperty("seq", 1)
        base.add("data", json("""[{"id":"a"}]"""))
        base.addProperty("delivery", "delta-v1")
        for ((key, value) in overrides) base.add(key, value)
        return base
    }

    private fun newEntry(): Entry = Entry("s", "n", JsonObject(), wantDelta = true)

    @Test
    fun `snapshot and delta flow`() {
        val entry = newEntry()
        val first = entry.applySnapshot(snapshot(), who, initial = true)
        assertNotNull(first)
        assertEquals(1, first.seq)
        assertEquals(SubscriptionStatus.READY, entry.state.status)
        assertEquals("g1", entry.state.generation)

        val second = entry.applyDelta(json("""{"g":"g1","b":1,"s":2,"p":{"c":[["a",{"t":1}]]}}""").asJsonObject)
        assertTrue(second is ApplyResult.Ack)
        assertEquals(2, second.seq)
        assertEquals(2, entry.state.seq)
        assertEquals(1, entry.state.data!!.asJsonArray[0].asJsonObject.get("t").asInt)

        // A duplicate sequence number is acknowledged again.
        val duplicate = entry.applyDelta(json("""{"g":"g1","b":1,"s":2,"p":{}}""").asJsonObject)
        assertTrue(duplicate is ApplyResult.Ack)
        assertEquals(2, duplicate.seq)

        // Another generation is ignored.
        assertNull(entry.applyDelta(json("""{"g":"old","b":1,"s":2,"p":{}}""").asJsonObject))

        // A gap requests a reconnect.
        assertSame(
            ApplyResult.Reconnect,
            entry.applyDelta(json("""{"g":"g1","b":3,"s":4,"p":{}}""").asJsonObject),
        )
    }

    @Test
    fun `non-initial snapshot from an old generation is ignored`() {
        val entry = newEntry()
        entry.applySnapshot(snapshot(), who, initial = true)
        assertNull(
            entry.applySnapshot(snapshot("generation" to JsonPrimitive("old")), who, initial = false),
        )
    }

    @Test
    fun `rejects foreign snapshots`() {
        for (overrides in listOf(
            arrayOf("subject_id" to JsonPrimitive("other")),
            arrayOf("subscription_id" to JsonPrimitive("x")),
            arrayOf("seq" to JsonPrimitive(0)),
            arrayOf("protocol_version" to JsonPrimitive(2)),
            arrayOf("generation" to JsonPrimitive(2)),
            arrayOf("project_id" to JsonPrimitive("other")),
        )) {
            val error = assertFailsWith<ApiException>("accepted ${overrides.toList()}") {
                newEntry().applySnapshot(snapshot(*overrides), who, initial = true)
            }
            assertEquals("PROTOCOL_ERROR", error.code)
        }
        // Missing data and missing identity are also invalid.
        val noData = snapshot().apply { remove("data") }
        assertFailsWith<ApiException> { newEntry().applySnapshot(noData, who, initial = true) }
        assertFailsWith<ApiException> { newEntry().applySnapshot(snapshot(), null, initial = true) }
    }

    @Test
    fun `rejects deltas that were not negotiated`() {
        val entry = newEntry()
        entry.applySnapshot(snapshot("delivery" to JsonPrimitive("snapshot")), who, initial = true)
        val error = assertFailsWith<ApiException> {
            entry.applyDelta(json("""{"g":"g1","b":1,"s":2,"p":{}}""").asJsonObject)
        }
        assertEquals("PROTOCOL_ERROR", error.code)
    }

    @Test
    fun `rejects malformed delta sequences and patches`() {
        val entry = newEntry()
        entry.applySnapshot(snapshot(), who, initial = true)
        for (bad in listOf(
            """{"g":"g1","b":1,"s":3,"p":{}}""",
            """{"g":"g1","b":0,"s":1,"p":{}}""",
            """{"g":"g1","b":1.5,"s":2.5,"p":{}}""",
            """{"g":"g1","b":1,"s":"2","p":{}}""",
        )) {
            assertFailsWith<ApiException>("accepted $bad") {
                entry.applyDelta(json(bad).asJsonObject)
            }
        }
        assertFailsWith<ApiException> {
            entry.applyDelta(json("""{"g":"g1","b":1,"s":2,"p":{"x":[]}}""").asJsonObject)
        }
        assertFailsWith<ApiException> {
            entry.applyDelta(json("""{"g":"g1","b":1,"s":2}""").asJsonObject)
        }
    }

    @Test
    fun `state decode copies data into a caller type`() {
        val state = SubscriptionState(data = json("""[{"id":"a","text":"hi"}]"""))
        val items = state.decode<List<Item>>()
        assertNotNull(items)
        assertEquals("hi", items[0].text)
        assertNotNull(state.decode<List<Item>>(object : com.google.gson.reflect.TypeToken<List<Item>>() {}.type))
    }

    data class Item(val id: String = "", val text: String = "")
}
