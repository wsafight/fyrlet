package fyrlet

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.Authenticator
import java.net.CookieHandler
import java.net.ProxySelector
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.net.http.WebSocket
import java.security.SecureRandom
import java.time.Duration
import java.util.Optional
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLParameters
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Runs against a real Fyrlet inbox server. Start it with scripts/integration_sdks.sh.
// Every test skips itself when INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES are absent, so `mvn test` is offline-safe.

private data class Project(val project_id: String, val service_key: String)

private data class Item(
    val id: String = "",
    val text: String = "",
    val version: Int = 0,
)

private data class History(val items: List<Item> = emptyList())

private fun newId(): String {
    val bytes = ByteArray(8)
    SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { byte -> "%02x".format(byte) }
}

private fun jsonObject(text: String): JsonObject = JsonParser.parseString(text).asJsonObject

private class Harness(private val endpoint: String, private val projects: List<Project>) {
    fun user(
        projectIndex: Int,
        subject: String? = null,
        retryDelay: ((Int) -> Duration)? = { Duration.ofMillis(50) },
        onListenerError: ((Throwable) -> Unit)? = null,
        httpClient: HttpClient? = null,
    ): FyrletClient {
        val project = projects[projectIndex]
        val service = SessionService(endpoint, project.service_key)
        val session = service.issueSession(subject ?: "user-" + newId(), ttlSeconds = 600)
        return FyrletClient(
            FyrletOptions(
                endpoint = endpoint,
                projectId = project.project_id,
                getToken = { session.token },
                retryDelay = retryDelay,
                onListenerError = onListenerError,
                httpClient = httpClient,
            ),
        )
    }
}

private class Environment(val endpoint: String, val projects: List<Project>)

private fun setup(): Environment {
    val endpoint = System.getenv("INTEGRATION_ENDPOINT")
    val fixtures = System.getenv("INTEGRATION_FIXTURES")
    Assumptions.assumeTrue(
        !endpoint.isNullOrEmpty() && !fixtures.isNullOrEmpty(),
        "needs INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES",
    )
    val array = JsonParser.parseString(File(fixtures!!).readText()).asJsonArray
    val projects = array.map {
        val entry = it.asJsonObject
        Project(entry.get("project_id").asString, entry.get("service_key").asString)
    }
    return Environment(endpoint!!, projects)
}

private fun until(what: String, condition: () -> Boolean) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
    while (System.nanoTime() < deadline) {
        if (condition()) return
        Thread.sleep(20)
    }
    throw AssertionError("condition not reached: $what")
}

private fun ready(subscription: Subscription) {
    until("subscription ready") { subscription.state.status == SubscriptionStatus.READY }
}

private fun items(subscription: Subscription): List<Item> =
    subscription.state.decode<List<Item>>() ?: emptyList()

private fun apiCode(error: Throwable?): String? = (error as? ApiException)?.code

/** Accepts every request through [base], but loses the response of a committed `inbox.add`. */
private class LossyHttpClient(private val base: HttpClient) : HttpClient() {
    val writes = AtomicInteger()

    override fun cookieHandler(): Optional<CookieHandler> = base.cookieHandler()
    override fun connectTimeout(): Optional<Duration> = base.connectTimeout()
    override fun followRedirects(): HttpClient.Redirect = base.followRedirects()
    override fun proxy(): Optional<ProxySelector> = base.proxy()
    override fun sslContext(): SSLContext = base.sslContext()
    override fun sslParameters(): SSLParameters = base.sslParameters()
    override fun authenticator(): Optional<Authenticator> = base.authenticator()
    override fun version(): HttpClient.Version = base.version()
    override fun executor(): Optional<Executor> = base.executor()

    override fun <T : Any?> send(
        request: HttpRequest,
        responseBodyHandler: HttpResponse.BodyHandler<T>,
    ): HttpResponse<T> {
        val response = base.send(request, responseBodyHandler)
        if (request.uri().path.endsWith("/operations/inbox.add")) {
            writes.incrementAndGet()
            (response.body() as? InputStream)?.close()
            throw IOException("injected response loss after commit")
        }
        return response
    }

    override fun <T : Any?> sendAsync(
        request: HttpRequest,
        responseBodyHandler: HttpResponse.BodyHandler<T>,
    ): CompletableFuture<HttpResponse<T>> = base.sendAsync(request, responseBodyHandler)

    override fun <T : Any?> sendAsync(
        request: HttpRequest,
        responseBodyHandler: HttpResponse.BodyHandler<T>,
        pushPromiseHandler: HttpResponse.PushPromiseHandler<T>,
    ): CompletableFuture<HttpResponse<T>> = base.sendAsync(request, responseBodyHandler, pushPromiseHandler)

    override fun newWebSocketBuilder(): WebSocket.Builder = base.newWebSocketBuilder()
}

class IntegrationTest {
    @Test
    fun `call idempotency conflict and contract`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val client = harness.user(0)
        try {
            val key = "key-" + newId()
            val first = client.callInto<Item>("inbox.add", jsonObject("""{"text":"hello"}"""), key)
            assertNotNull(first)
            val again = client.callInto<Item>("inbox.add", jsonObject("""{"text":"hello"}"""), key)
            assertNotNull(again)
            assertEquals(first.id, again.id)

            val conflict = assertFailsWith<ApiException> {
                client.call("inbox.add", jsonObject("""{"text":"changed"}"""), key)
            }
            assertEquals("CONFLICT", conflict.code)
            assertEquals(409, conflict.status)

            val history = client.callInto<History>("inbox.history")
            assertNotNull(history)
            assertEquals(1, history.items.size)

            client.call(
                "inbox.update",
                jsonObject("""{"id":"${first.id}","text":"new","expected_version":${first.version}}"""),
            )
            val late = assertFailsWith<ApiException> {
                client.call(
                    "inbox.update",
                    jsonObject("""{"id":"${first.id}","text":"late","expected_version":${first.version}}"""),
                )
            }
            assertEquals("CONFLICT", late.code)

            val contract = client.contract()
            assertTrue(FyrletJson.gson.toJson(contract).contains("inbox.add"))
        } finally {
            client.close()
        }
    }

    @Test
    fun `concurrent duplicate calls share one write`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val client = harness.user(0)
        val pool = Executors.newFixedThreadPool(8)
        try {
            val key = "key-" + newId()
            val ids = CopyOnWriteArrayList<String>()
            val failures = CopyOnWriteArrayList<Throwable>()
            val tasks = (1..8).map {
                pool.submit {
                    try {
                        val created = client.callInto<Item>(
                            "inbox.add", jsonObject("""{"text":"c"}"""), key,
                        )
                        ids.add(created?.id ?: "")
                    } catch (error: Throwable) {
                        failures.add(error)
                    }
                }
            }
            tasks.forEach { it.get(30, TimeUnit.SECONDS) }
            assertTrue(failures.isEmpty(), "unexpected failures: $failures")
            assertEquals(1, ids.distinct().size)
        } finally {
            pool.shutdownNow()
            client.close()
        }
    }

    @Test
    fun `subscription snapshot delta refresh and shared devices`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val subject = "shared-" + newId()
        val first = harness.user(0, subject)
        val second = harness.user(0, subject)
        try {
            val left = first.subscribe("inbox.recent")
            val right = second.subscribe("inbox.recent")
            ready(left)
            ready(right)

            val seen = CopyOnWriteArrayList<SubscriptionStatus>()
            left.onChange { seen.add(it.status) }

            val created = first.callInto<Item>("inbox.add", jsonObject("""{"text":"shared"}"""))
            assertNotNull(created)
            until("left sees item") { items(left).any { it.id == created.id && it.text == "shared" } }
            until("right sees item") { items(right).any { it.id == created.id && it.text == "shared" } }

            first.call(
                "inbox.update",
                jsonObject("""{"id":"${created.id}","text":"edited","expected_version":${created.version}}"""),
            )
            until("delta applied") { items(left).any { it.id == created.id && it.text == "edited" } }

            val before = left.state.seq
            left.refresh()
            until("refresh snapshot") { left.state.seq > before }
            assertEquals(SubscriptionStatus.READY, seen.first())

            left.unsubscribe()
            assertEquals(SubscriptionStatus.CLOSED, left.state.status)
            assertNull(left.state.data)
            assertEquals("NOT_READY", apiCode(assertFailsWith<ApiException> { left.refresh() }))
            right.unsubscribe()
        } finally {
            first.close()
            second.close()
        }
    }

    @Test
    fun `authorization isolation`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val owner = harness.user(0)
        val other = harness.user(0)
        val foreign = harness.user(1)
        try {
            owner.call("inbox.add", jsonObject("""{"text":"private"}"""))
            for (client in listOf(other, foreign)) {
                val subscription = client.subscribe("inbox.recent")
                ready(subscription)
                assertTrue(items(subscription).isEmpty(), "subscription leaked another user's data")
                val history = client.callInto<History>("inbox.history")
                assertNotNull(history)
                assertTrue(history.items.isEmpty())
                subscription.unsubscribe()
            }
        } finally {
            owner.close()
            other.close()
            foreign.close()
        }
    }

    @Test
    fun `lost response is unknown then recovered without a second write`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val base = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build()
        val lossy = LossyHttpClient(base)
        val client = harness.user(0, httpClient = lossy)
        val stranger = harness.user(0)
        try {
            val mutation = client.mutate("inbox.add", jsonObject("""{"text":"lost"}"""))
            assertEquals(MutationStatus.UNKNOWN, mutation.state.status)
            assertTrue(mutation.state.error is OutcomeUnknownException)
            assertTrue(assertFailsWith<ApiException> { mutation.result() } is OutcomeUnknownException)

            val state = mutation.recover()
            assertEquals(MutationStatus.COMMITTED, state.status)
            val recovered = FyrletJson.gson.fromJson(state.data, Item::class.java)
            assertEquals("lost", recovered.text)
            assertEquals(1, lossy.writes.get())

            // Another user must not see the receipt.
            val found = stranger.recover(
                "inbox.add", jsonObject("""{"text":"lost"}"""), mutation.idempotencyKey,
            )
            assertEquals(MutationStatus.UNKNOWN, found.status)
        } finally {
            client.close()
            stranger.close()
        }
    }

    @Test
    fun `token refresh and revocation`() {
        val environment = setup()
        val project = environment.projects[0]
        val service = SessionService(environment.endpoint, project.service_key)
        val subject = "refresh-" + newId()
        val stale = service.issueSession(subject)
        assertTrue(service.revokeSession(stale.session_id))

        val calls = CopyOnWriteArrayList<Boolean>()
        val fresh = FyrletClient(
            FyrletOptions(
                endpoint = environment.endpoint,
                projectId = project.project_id,
                getToken = { force ->
                    calls.add(force)
                    if (force) service.issueSession(subject).token else stale.token
                },
            ),
        )
        try {
            fresh.call("inbox.history")
            assertEquals(2, calls.size)
            assertEquals(false, calls[0])
            assertEquals(true, calls[1])
        } finally {
            fresh.close()
        }

        val live = service.issueSession(subject)
        val revoked = FyrletClient(
            FyrletOptions(
                endpoint = environment.endpoint,
                projectId = project.project_id,
                retryDelay = { Duration.ofMillis(50) },
                getToken = { force ->
                    if (force) throw ApiException("UNAUTHENTICATED", "logged out") else live.token
                },
            ),
        )
        try {
            val subscription = revoked.subscribe("inbox.recent")
            ready(subscription)
            assertTrue(service.revokeSession(live.session_id))
            until("terminal error") { subscription.state.status == SubscriptionStatus.ERROR }
            val state = subscription.state
            assertNull(state.data)
            assertNotNull(state.error)
            assertEquals("UNAUTHENTICATED", state.error.code)
        } finally {
            revoked.close()
        }
    }

    @Test
    fun `account switch is rejected`() {
        val environment = setup()
        val project = environment.projects[0]
        val service = SessionService(environment.endpoint, project.service_key)
        val a = service.issueSession("a-" + newId())
        val b = service.issueSession("b-" + newId())
        val client = FyrletClient(
            FyrletOptions(
                endpoint = environment.endpoint,
                projectId = project.project_id,
                getToken = { force -> if (force) b.token else a.token },
            ),
        )
        try {
            client.call("inbox.history")
            // Revoking A's session forces a refresh, which yields B's identity on the same client.
            assertTrue(service.revokeSession(a.session_id))
            val error = assertFailsWith<ApiException> { client.call("inbox.history") }
            assertEquals("FORBIDDEN", error.code)
        } finally {
            client.close()
        }
    }

    @Test
    fun `subscription recovers after connection loss and close releases`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val client = harness.user(0)
        try {
            val subscription = client.subscribe("inbox.recent")
            ready(subscription)
            val created = client.callInto<Item>("inbox.add", jsonObject("""{"text":"before"}"""))
            assertNotNull(created)
            until("item arrives") { items(subscription).size == 1 }

            val statuses = CopyOnWriteArrayList<SubscriptionStatus>()
            subscription.onChange { statuses.add(it.status) }
            val generation = subscription.state.generation

            client.reconnect()
            ready(subscription)
            until("new generation") { subscription.state.generation != generation }
            assertTrue(statuses.contains(SubscriptionStatus.RECOVERING))

            val after = items(subscription)
            assertEquals(1, after.size)
            assertEquals(created.id, after[0].id)

            client.close()
            assertEquals(SubscriptionStatus.CLOSED, subscription.state.status)
            assertEquals("CLIENT_CLOSED", apiCode(assertFailsWith<ApiException> { client.call("inbox.history") }))
            assertEquals("CLIENT_CLOSED", apiCode(assertFailsWith<ApiException> { client.subscribe("inbox.recent") }))
        } finally {
            client.close()
        }
    }

    @Test
    fun `listener exceptions do not break the client`() {
        val environment = setup()
        val harness = Harness(environment.endpoint, environment.projects)
        val recovered = AtomicInteger()
        val client = harness.user(0, onListenerError = { recovered.incrementAndGet() })
        try {
            val subscription = client.subscribe("inbox.recent")
            subscription.onChange { throw IllegalStateException("boom") }
            ready(subscription)
            until("listener error reported") { recovered.get() > 0 }
        } finally {
            client.close()
        }
    }
}
