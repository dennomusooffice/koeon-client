package com.dennomuso.koeon.core.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceDisplayNameStoreTest {
    @Test
    fun `android name has persistent AND prefix and unambiguous suffix`() {
        val values = MemoryValues()
        val first = PersistentDeviceDisplayNameStore(values, "AND") { it - 1 }.getOrCreate()
        val second = PersistentDeviceDisplayNameStore(values, "AND") { 0 }.getOrCreate()

        assertEquals(first, second)
        assertTrue(first.matches(Regex("^AND-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$")))
        assertFalse(first.contains(Regex("[01IO]")))
        assertFalse(DEVICE_NAME_ALPHABET.contains(Regex("[01IO]")))
    }

    private class MemoryValues : DeviceDisplayNameValues {
        private val values = mutableMapOf<String, String>()
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String) { values[key] = value }
    }
}
