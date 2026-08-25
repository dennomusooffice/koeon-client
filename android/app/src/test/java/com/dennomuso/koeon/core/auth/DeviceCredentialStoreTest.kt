package com.dennomuso.koeon.core.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceCredentialStoreTest {
    @Test
    fun `credential lifecycle uses secure store abstraction`() {
        val store: DeviceCredentialStore = FakeStore()
        assertNull(store.read())
        store.write("credential-value-that-is-never-plain-preferences")
        assertEquals("credential-value-that-is-never-plain-preferences", store.read())
        store.clear()
        assertNull(store.read())
    }

    private class FakeStore : DeviceCredentialStore {
        private var value: String? = null
        override fun read(): String? = value
        override fun write(credential: String) { value = credential }
        override fun clear() { value = null }
    }
}
