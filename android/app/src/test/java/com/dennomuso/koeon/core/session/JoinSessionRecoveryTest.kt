package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.api.HttpKoeonApi
import com.dennomuso.koeon.core.api.KoeonApiException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class JoinSessionRecoveryTest {
    @Test fun `expired join response recovers runtime without clearing device credential`() = runTest {
        val server = MockWebServer(); server.start()
        try {
            server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":{"code":"SESSION_INVALID","message":"expired"}}"""))
            val credential = "test-device-credential"
            val api = HttpKoeonApi(server.url("/").toString(), { credential })
            val error = runCatching { api.floorStatus("old-join") }.exceptionOrNull()!!
            assertTrue(requiresJoinRenewal(error))
            val recovery = JoinSessionRecovery()
            val ticket = recovery.request("old-join")!!
            val events = mutableListOf<String>()
            assertTrue(recovery.run(ticket, { "old-join" }, { events += "stop" }, { events += "rejoin"; true }))
            assertEquals(listOf("stop", "rejoin"), events)
            assertEquals("Bearer $credential", server.takeRequest().getHeader("Authorization"))
        } finally { server.shutdown() }
    }

    @Test fun `power off while teardown suspends prevents rejoin`() = runTest {
        val recovery = JoinSessionRecovery(); val ticket = recovery.request("old")!!
        val stopped = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var joined = false
        val job = launch { recovery.run(ticket, { "old" }, { stopped.complete(Unit); release.await() }, { joined = true; true }) }
        stopped.await(); recovery.invalidate(); release.complete(Unit); job.join()
        assertFalse(joined)
    }

    @Test fun `duplicate request and stale session cannot tear down replacement`() = runTest {
        val recovery = JoinSessionRecovery(); val ticket = recovery.request("old")!!
        assertNull(recovery.request("old"))
        assertFalse(recovery.run(ticket, { "new" }, { fail("replacement stopped") }, { fail("unexpected join"); true }))
        assertNotNull(recovery.request("new"))
    }

    @Test fun `channel change invalidates queued recovery and old cleanup preserves new ticket`() = runTest {
        val recovery = JoinSessionRecovery(); val old = recovery.request("old")!!
        recovery.invalidate(); val next = recovery.request("new")!!
        assertFalse(recovery.run(old, { "old" }, { fail("stale teardown") }, { true }))
        assertNull(recovery.request("duplicate"))
        assertTrue(recovery.run(next, { "new" }, {}, { true }))
    }

    @Test fun `credential failures and transport errors are not join expiry`() {
        assertFalse(requiresJoinRenewal(KoeonApiException(401, "DEVICE_REVOKED", "revoked")))
        assertFalse(requiresJoinRenewal(KoeonApiException(403, "SESSION_INVALID", "denied")))
        assertFalse(requiresJoinRenewal(java.io.IOException("offline")))
    }
}
