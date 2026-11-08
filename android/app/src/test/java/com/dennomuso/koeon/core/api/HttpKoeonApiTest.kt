package com.dennomuso.koeon.core.api

import com.dennomuso.koeon.core.model.Batv1Chunk
import com.dennomuso.koeon.core.model.Batv1PublishRequest
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch
import okio.buffer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HttpKoeonApiTest {
    private lateinit var server: MockWebServer
    private lateinit var api: HttpKoeonApi
    private var credential: String? = "device-credential-test-value-1234567890"

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        api = HttpKoeonApi(
            server.url("/").toString(),
            credentialProvider = { credential },
        )
    }

    @After
    fun tearDown() = server.shutdown()

    @Test
    fun `cancellation also closes a stalled response body`() = kotlinx.coroutines.runBlocking {
        val readingBody = java.util.concurrent.CountDownLatch(1)
        val client = okhttp3.OkHttpClient.Builder()
            .readTimeout(3, java.util.concurrent.TimeUnit.SECONDS)
            .addNetworkInterceptor { chain ->
                val response = chain.proceed(chain.request())
                val body = response.body!!
                val source = object : okio.ForwardingSource(body.source()) {
                    override fun read(sink: okio.Buffer, byteCount: Long): Long {
                        readingBody.countDown()
                        return super.read(sink, byteCount)
                    }
                }.buffer()
                response.newBuilder().body(object : okhttp3.ResponseBody() {
                    override fun contentType() = body.contentType()
                    override fun contentLength() = body.contentLength()
                    override fun source() = source
                }).build()
            }.build()
        val cancellableApi = HttpKoeonApi(server.url("/").toString(), client = client)
        server.enqueue(jsonResponse("""{"outcome":"accepted","acceptedChunks":0,"latestSequence":-1}""")
            .setBodyDelay(3, java.util.concurrent.TimeUnit.SECONDS))
        val pending = launch(kotlinx.coroutines.Dispatchers.IO) {
            cancellableApi.publishBufferedAudio(Batv1PublishRequest(1, "slow-body", "lab", "lab", "lab",
                "lease", "pcm16le", 48000, 1, 20, "lab", emptyList(), null))
        }
        assertTrue(readingBody.await(2, java.util.concurrent.TimeUnit.SECONDS))
        val started = System.nanoTime()
        pending.cancel()
        pending.join()
        assertTrue("Body read survived cancellation", (System.nanoTime() - started) / 1_000_000 < 1500)
    }

    @Test
    fun `cancelling a stalled subscription releases transport promptly`() = kotlinx.coroutines.runBlocking {
        val client = okhttp3.OkHttpClient.Builder().readTimeout(3, java.util.concurrent.TimeUnit.SECONDS).build()
        val cancellableApi = HttpKoeonApi(server.url("/").toString(), client = client)
        server.enqueue(MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.NO_RESPONSE))
        val pending = launch(kotlinx.coroutines.Dispatchers.IO) {
            cancellableApi.subscribeBufferedAudio(com.dennomuso.koeon.core.model.Batv1SubscribeRequest("lab", "stalled", 0))
        }
        org.junit.Assert.assertNotNull(server.takeRequest(2, java.util.concurrent.TimeUnit.SECONDS))
        val started = System.nanoTime()
        pending.cancel()
        pending.join()
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("Cancellation held transport for $elapsedMs ms", elapsedMs < 1500)
        server.enqueue(jsonResponse("""{"outcome":"accepted","acceptedChunks":0,"latestSequence":-1}"""))
        // A cancelled subscription must not poison the shared HTTP client's next request.
        val response = cancellableApi.publishBufferedAudio(Batv1PublishRequest(1, "next", "lab", "lab", "lab",
            "lease", "pcm16le", 48000, 1, 20, "lab", emptyList(), null))
        assertEquals("accepted", response.outcome)
    }

    @Test
    fun `listener join uses existing backend contract without publish request`() = runTest {
        server.enqueue(
            jsonResponse(
                """{
                  "sessionId":"session-1","livekitUrl":"wss://example.livekit.cloud",
                  "token":"redacted-token","roomName":"workspace-channel",
                  "user":{"id":"listener-a","workspaceId":"workspace-1","name":"Listener A","role":"LISTENER"},
                  "channel":{"id":"channel-2","name":"02 ステージ"},
                  "canPublish":false,"tokenExpiresInSeconds":300
                }""".trimIndent(),
            ),
        )

        val joined = api.join("listener-a", "channel-2", false)
        val request = server.takeRequest()
        val body = request.body.readUtf8()

        assertEquals("/api/join", request.path)
        assertEquals("Bearer device-credential-test-value-1234567890", request.getHeader("Authorization"))
        assertTrue(body.contains("\"wantsToPublish\":false"))
        assertFalse(body.contains("rxReadyProtocolVersion"))
        assertFalse(body.contains("\"userId\""))
        assertFalse(joined.canPublish)
        assertTrue(joined.user.channelIds.isEmpty())
    }

    @Test
    fun `publisher join advertises RX READY protocol v1`() = runTest {
        server.enqueue(
            jsonResponse(
                """{
                  "sessionId":"session-1","livekitUrl":"wss://example.livekit.cloud",
                  "token":"redacted-token","roomName":"workspace-channel",
                  "user":{"id":"staff-a","workspaceId":"workspace-1","name":"Staff A","role":"STAFF"},
                  "channel":{"id":"channel-2","name":"02 ステージ"},
                  "canPublish":true,"tokenExpiresInSeconds":300,"deviceId":"device-a"
                }""".trimIndent(),
            ),
        )

        api.join("staff-a", "channel-2", true)
        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject

        assertEquals("1", body["rxReadyProtocolVersion"]?.jsonPrimitive?.content)
    }

    @Test
    fun `floor renew sends session and lease identifiers`() = runTest {
        server.enqueue(jsonResponse("""{"outcome":"renewed","leaseId":"lease-1","isOwner":true}"""))

        val renewed = api.renew("session-1", "lease-1")
        val request = server.takeRequest()
        val body = request.body.readUtf8()

        assertEquals("/api/floor/renew", request.path)
        assertTrue(body.contains("\"sessionId\":\"session-1\""))
        assertTrue(body.contains("\"leaseId\":\"lease-1\""))
        assertEquals("renewed", renewed.outcome)
    }

    @Test
    fun `native enrollment returns credential once then me uses bearer`() = runTest {
        credential = null
        server.enqueue(jsonResponse("""{
          "identity":{
            "user":{"id":"staff-a","displayName":"Staff A","role":"STAFF"},
            "workspace":{"id":"workspace-1","name":"Example Workspace"},
            "device":{"id":"device-1","name":"Android","platform":"android"},
            "channels":[{"id":"stage","name":"02 Stage","type":"NORMAL"}]
          },
          "credentialExpiresAt":"2026-09-01T00:00:00Z",
          "deviceCredential":"native-device-credential-value-123456789"
        }""".trimIndent()))
        val enrollment = api.enroll(com.dennomuso.koeon.core.model.EnrollmentRequest(
            token = "invite-token-value-that-is-long-enough-123",
            platform = "android",
            deviceName = "Android",
            osVersion = "test",
            appVersion = "test",
        ))
        val enrollRequest = server.takeRequest()
        val enrollBody = enrollRequest.body.readUtf8()
        assertEquals("/api/auth/enroll", enrollRequest.path)
        assertEquals(null, enrollRequest.getHeader("Authorization"))
        assertEquals("android", Json.parseToJsonElement(enrollBody).jsonObject["platform"]?.jsonPrimitive?.content)
        credential = enrollment.deviceCredential

        server.enqueue(jsonResponse("""{
          "user":{"id":"staff-a","displayName":"Staff A","role":"STAFF"},
          "workspace":{"id":"workspace-1","name":"Example Workspace"},
          "device":{"id":"device-1","name":"Android","platform":"android"},
          "channels":[{"id":"stage","name":"02 Stage","type":"NORMAL"}]
        }""".trimIndent()))
        assertEquals("staff-a", api.me().user.id)
        assertEquals("Bearer native-device-credential-value-123456789", server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `temporary code enrollment body uses code and explicit android platform`() = runTest {
        credential = null
        server.enqueue(jsonResponse("""{
          "identity":{"user":{"id":"user-a","displayName":"Example User","role":"STAFF"},"workspace":{"id":"workspace-1","name":"Example Workspace"},"device":{"id":"device-1","name":"Android","platform":"android"},"channels":[]},
          "credentialExpiresAt":"2026-09-01T00:00:00Z","deviceCredential":"native-device-credential-value-123456789"
        }""".trimIndent()))
        api.enroll(com.dennomuso.koeon.core.model.EnrollmentRequest(
            code = "ABCDE23456",
            platform = "android",
            deviceName = "Android",
            osVersion = "test",
            appVersion = "test",
        ))
        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("ABCDE23456", body["code"]?.jsonPrimitive?.content)
        assertEquals("android", body["platform"]?.jsonPrimitive?.content)
        assertFalse("token" in body)
    }

    @Test
    fun `device assignment reset calls authenticated server logout`() = runTest {
        server.enqueue(jsonResponse("""{"outcome":"logged_out"}"""))

        api.logout()
        val request = server.takeRequest()

        assertEquals("/api/auth/logout", request.path)
        assertEquals("POST", request.method)
        assertEquals("Bearer device-credential-test-value-1234567890", request.getHeader("Authorization"))
        assertEquals(emptySet<String>(), Json.parseToJsonElement(request.body.readUtf8()).jsonObject.keys)
    }

    @Test
    fun `BATv1 publish wire includes every required immutable format field`() = runTest {
        server.enqueue(jsonResponse("""{"outcome":"accepted","acceptedChunks":1,"latestSequence":0}"""))

        api.publishBufferedAudio(
            Batv1PublishRequest(
                protocolVersion = 1,
                generationId = "generation-1",
                channelId = "channel-1",
                speakerSessionId = "session-1",
                speakerDeviceId = "device-1",
                leaseId = "lease-1",
                codec = "pcm16le",
                sampleRate = 48_000,
                channels = 1,
                frameDurationMs = 20,
                sessionId = "session-1",
                chunks = listOf(Batv1Chunk(sequence = 0, payloadBase64 = "AA==")),
            ),
        )

        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("1", body["protocolVersion"]?.jsonPrimitive?.content)
        assertEquals("pcm16le", body["codec"]?.jsonPrimitive?.content)
        assertEquals("48000", body["sampleRate"]?.jsonPrimitive?.content)
        assertEquals("1", body["channels"]?.jsonPrimitive?.content)
        assertEquals("20", body["frameDurationMs"]?.jsonPrimitive?.content)
    }

    private fun jsonResponse(body: String) = MockResponse()
        .setResponseCode(200)
        .setHeader("Content-Type", "application/json")
        .setBody(body)
}
