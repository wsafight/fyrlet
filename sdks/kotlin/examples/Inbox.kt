import com.google.gson.JsonObject
import fyrlet.FyrletClient
import fyrlet.FyrletOptions
import fyrlet.SessionService
import fyrlet.SubscriptionState
import fyrlet.decode

/**
 * Runs against a running Fyrlet server.
 *
 * ```
 * mvn -q compile dependency:build-classpath -Dmdep.outputFile=target/classpath.txt
 * kotlinc -cp "target/classes:$(cat target/classpath.txt)" examples/Inbox.kt -include-runtime -d target/inbox.jar
 * java -cp "target/inbox.jar:target/classes:$(cat target/classpath.txt)" InboxKt "First note"
 * ```
 *
 * In a real application the SessionService runs on your backend and only the token reaches the client.
 */
fun main(args: Array<String>) {
    val endpoint = requireNotNull(System.getenv("FYRLET_ENDPOINT")) { "FYRLET_ENDPOINT" }
    val projectId = requireNotNull(System.getenv("FYRLET_PROJECT_ID")) { "FYRLET_PROJECT_ID" }
    val serviceKey = requireNotNull(System.getenv("FYRLET_SERVICE_KEY")) { "FYRLET_SERVICE_KEY" }

    val sessions = SessionService(endpoint, serviceKey)
    val client = FyrletClient(
        FyrletOptions(endpoint, projectId, getToken = {
            sessions.issueSession("example-user", ttlSeconds = 600).token
        }),
    )
    try {
        val recent = client.subscribe("inbox.recent", JsonObject().apply { addProperty("limit", 20) })
        recent.onChange { state: SubscriptionState ->
            val items = state.decode<List<Item>>() ?: emptyList()
            println("${state.status} " + items.joinToString(", ") { it.text })
        }

        val texts = if (args.isNotEmpty()) args.toList() else listOf("Hello from Kotlin")
        for (text in texts) {
            client.call("inbox.add", JsonObject().apply { addProperty("text", text) })
        }
        Thread.sleep(1000) // let the delta arrive before exiting
        recent.unsubscribe()
    } finally {
        client.close()
    }
}

/** A plain class with a no-arg constructor so Gson can decode it. */
class Item {
    var id: String? = null
    var text: String = ""
    var version: Long = 0

    override fun toString(): String = text
}
