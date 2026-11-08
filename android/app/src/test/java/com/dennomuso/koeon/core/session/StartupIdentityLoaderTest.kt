package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.api.HttpKoeonApi
import com.dennomuso.koeon.core.api.KoeonApiException
import com.dennomuso.koeon.core.auth.DeviceCredentialStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class StartupIdentityLoaderTest {
    private class Store(var value: String? = "saved-credential") : DeviceCredentialStore {
        var clears = 0
        var unreadable = false
        override fun read(): String? { if (unreadable) throw IOException("keystore unavailable"); return value }
        override fun write(credential: String) { value = credential }
        override fun clear() { clears++; value = null }
    }

    @Test fun `transient failures keep enrollment and permit a subsequent successful load`() = runTest {
        for (error in listOf(IOException("offline"), KoeonApiException(503, "UNAVAILABLE", "down"),
            KoeonApiException(401, "UNKNOWN", "unauthorized"))) {
            val store = Store()
            assertEquals(StartupIdentityResult.Retry, loadStartupIdentity(store) { throw error })
            assertEquals("saved-credential", store.value)
            assertEquals(0, store.clears)
            assertEquals(StartupIdentityResult.Loaded("same-user"), loadStartupIdentity(store) { "same-user" })
        }
    }

    @Test fun `actual HTTP unauthorized response only clears explicitly invalid device credential`() = runTest {
        val server = MockWebServer(); server.start()
        try {
            for (code in listOf("SESSION_INVALID", "UNKNOWN", "DEVICE_CREDENTIAL_INVALID", "DEVICE_CREDENTIAL_EXPIRED")) {
                val store = Store()
                val api = HttpKoeonApi(server.url("/").toString(), { store.read() })
                server.enqueue(MockResponse().setResponseCode(401)
                    .setBody("""{"error":{"code":"$code","message":"denied"}}"""))
                val result = loadStartupIdentity(store) { api.me() }
                val invalid = code.startsWith("DEVICE_CREDENTIAL_")
                assertEquals(if (invalid) StartupIdentityResult.EnrollmentRequired else StartupIdentityResult.Retry, result)
                assertEquals(if (invalid) 1 else 0, store.clears)
            }
        } finally { server.shutdown() }
    }

    @Test fun `keystore read failure is retryable and never requests or clears enrollment`() = runTest {
        val store = Store(); store.unreadable = true
        assertEquals(StartupIdentityResult.Retry, loadStartupIdentity(store) { error("must not fetch") })
        assertEquals(0, store.clears)
        store.unreadable = false
        assertEquals(StartupIdentityResult.Loaded("user"), loadStartupIdentity(store) { "user" })
    }

    @Test fun `missing credential enrolls without an API request`() = runTest {
        assertEquals(StartupIdentityResult.EnrollmentRequired,
            loadStartupIdentity(Store(null)) { error("must not fetch") })
    }

    @Test fun `cancellation propagates without clearing registration`() = runTest {
        val store = Store()
        try { loadStartupIdentity(store) { throw CancellationException() }; fail("must propagate") }
        catch (_: CancellationException) { assertEquals(0, store.clears); assertNotNull(store.value) }
    }

    @Test fun `late success or denial cannot override a replacement credential`() = runTest {
        for (deny in listOf(false, true)) {
            val store = Store()
            val result = loadStartupIdentity(store) {
                store.write("replacement-credential")
                if (deny) throw KoeonApiException(401, "DEVICE_CREDENTIAL_INVALID", "old denied")
                "old-user"
            }
            assertEquals(StartupIdentityResult.Superseded, result)
            assertEquals("replacement-credential", store.value)
            assertEquals(0, store.clears)
        }
    }
}
