package com.dennomuso.koeon.core.api

import org.junit.Assert.assertEquals
import org.junit.Test

class KoeonApiBaseUrlConfigurationTest {
    @Test
    fun `missing configuration uses public safe default`() {
        assertEquals(KoeonApiBaseUrlConfiguration.PUBLIC_SAFE_BASE_URL, KoeonApiBaseUrlConfiguration.resolve(null))
        assertEquals(KoeonApiBaseUrlConfiguration.PUBLIC_SAFE_BASE_URL, KoeonApiBaseUrlConfiguration.resolve("  "))
    }

    @Test
    fun `valid HTTPS build configuration is used`() {
        assertEquals(
            "https://api.example.test",
            KoeonApiBaseUrlConfiguration.resolve(" https://api.example.test/ "),
        )
    }

    @Test
    fun `malformed or unsafe configuration fails closed`() {
        listOf(
            "not a URL",
            "http://api.example.test",
            "https://user:pass@api.example.test",
            "https://api.example.test?token=unsafe",
        ).forEach { value ->
            assertEquals(
                KoeonApiBaseUrlConfiguration.PUBLIC_SAFE_BASE_URL,
                KoeonApiBaseUrlConfiguration.resolve(value),
            )
        }
    }
}
