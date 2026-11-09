package com.dennomuso.koeon.core.livekit

import io.livekit.android.room.SignalClient
import io.livekit.android.stats.NetworkInfo
import io.livekit.android.stats.NetworkType
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class SignalRecoveryHttpClientTest {
    @Test fun sdkValidationFailureCannotDelayRecoveryPastCleanupWindow() {
        for (bounded in listOf(false, true)) {
            val client = if (bounded) SignalRecoveryHttpClient() else OkHttpClient()
            val server = MockWebServer()
            server.enqueue(MockResponse().setHeadersDelay(3, TimeUnit.SECONDS).setBody("ok"))
            server.start()
            val socket = object : WebSocket {
                override fun request() = Request.Builder().url(server.url("/rtc?protocol=15")).build()
                override fun queueSize() = 0L
                override fun send(text: String) = false
                override fun send(bytes: okio.ByteString) = false
                override fun close(code: Int, reason: String?) = true
                override fun cancel() {}
            }
            val signal = SignalClient(client, Json, client, Dispatchers.IO, object : NetworkInfo {
                override fun getNetworkType() = NetworkType.UNKNOWN
            })
            // Seed only connection identity/state; exercise actual SDK onFailure and real HTTP.
            for ((name, value) in mapOf("currentWs" to socket, "lastUrl" to server.url("/rtc?protocol=15").toString(), "isConnected" to true)) {
                SignalClient::class.java.getDeclaredField(name).apply { isAccessible = true }.set(signal, value)
            }
            val closedAt = java.util.concurrent.atomic.AtomicLong()
            signal.listener = java.lang.reflect.Proxy.newProxyInstance(
                SignalClient.Listener::class.java.classLoader, arrayOf(SignalClient.Listener::class.java),
            ) { _, method, _ ->
                if (method.name == "onClose") closedAt.set(System.nanoTime())
                null
            } as SignalClient.Listener
            val start = System.nanoTime()
            try {
                signal.onFailure(socket, java.io.EOFException("synthetic transport failure"), null)
                val elapsedMs = (closedAt.get() - start) / 1_000_000
                assertTrue("onClose must be called", closedAt.get() > 0)
                if (bounded) assertTrue("recovery notification took $elapsedMs ms", elapsedMs < 2500)
                else assertTrue("baseline should wait for diagnostic HTTP", elapsedMs >= 2800)
                assertEquals("/rtc/validate?protocol=15", server.takeRequest().path)
                assertFalse(signal.isConnected)
            } finally {
                server.shutdown()
                client.dispatcher.executorService.shutdownNow()
                client.connectionPool.evictAll()
            }
        }
    }

    @Test fun ordinaryHttpKeepsOriginalTimeout() {
        val client = SignalRecoveryHttpClient()
        val request = Request.Builder().url("https://example.invalid/rtc").build()
        assertEquals(0L, client.newCall(request).timeout().timeoutNanos())
        val validation = request.newBuilder().url("https://example.invalid/rtc/validate").build()
        assertEquals(TimeUnit.SECONDS.toNanos(1), client.newCall(validation).timeout().timeoutNanos())
    }

    @Test fun pinnedSdkDoesNotAcknowledgeServerCloseWithoutAdapter() = exercise(OkHttpClient(), false)
    @Test fun adapterCompletesServerCloseBeforeParticipantCleanup() = exercise(SignalRecoveryHttpClient(), true)

    private fun exercise(client: OkHttpClient, expectedClose: Boolean) {
        val server = MockWebServer()
        val closing = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val serverClosed = CountDownLatch(1)
        val failure = AtomicReference<Throwable>()
        // Exercise the actual pinned SDK's onClosing, not a copy of its implementation.
        val signal = SignalClient(client, Json, client, Dispatchers.IO, object : NetworkInfo {
            override fun getNetworkType() = NetworkType.UNKNOWN
        })
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.close(3500, "transport closed")
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { serverClosed.countDown() }
        }))
        server.start()
        val socket = client.newWebSocket(Request.Builder().url(server.url("/rtc")).build(), object : WebSocketListener() {
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                signal.onClosing(webSocket, code, reason)
                closing.countDown()
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                assertEquals(3500, code)
                assertEquals("transport closed", reason)
                closed.countDown()
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { failure.set(t) }
        })
        try {
            assertTrue("server close delivered", closing.await(3, TimeUnit.SECONDS))
            assertEquals("close handshake completion", expectedClose, closed.await(2, TimeUnit.SECONDS))
            if (expectedClose) assertTrue(serverClosed.await(1, TimeUnit.SECONDS))
            assertNull(failure.get())
        } finally {
            socket.cancel()
            server.shutdown()
            client.dispatcher.executorService.shutdownNow()
            client.connectionPool.evictAll()
        }
    }
}
