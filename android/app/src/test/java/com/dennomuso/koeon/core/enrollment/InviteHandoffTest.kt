package com.dennomuso.koeon.core.enrollment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InviteHandoffTest {
    private val token = "A".repeat(43)

    @Test fun `accepts strict raw token and trusted invite URL`() {
        assertEquals(token, InviteInputParser.parse(token))
        assertEquals(token, InviteInputParser.parse("https://koeon.muso-apps.net/join#$token"))
    }

    @Test fun `rejects wrong host path query and missing fragment`() {
        listOf(
            "https://example.com/join#$token",
            "https://koeon.muso-apps.net/admin#$token",
            "https://koeon.muso-apps.net/join?token=x#$token",
            "https://koeon.muso-apps.net/join",
        ).forEach { value ->
            assertTrue(runCatching { InviteInputParser.parse(value) }.isFailure)
        }
    }

    @Test fun `routes cold and warm intents without retaining a token`() {
        val deliveries = mutableListOf<String>()
        val router = InviteDeepLinkRouter(deliveries::add)
        assertTrue(router.route("https://koeon.muso-apps.net/join#$token"))
        assertTrue(router.route("https://koeon.muso-apps.net/join#${"B".repeat(43)}"))
        assertEquals(listOf(token, "B".repeat(43)), deliveries)
        assertFalse(router.route("https://koeon.muso-apps.net/join"))
        assertEquals(1, router.javaClass.declaredFields.count { it.name == "deliver" })
    }

    @Test fun `temporary code normalizes case spaces and hyphen`() {
        assertEquals(EnrollmentCredential.Code("ABCDE23456"), EnrollmentInputParser.parse("abcde-23456"))
        assertEquals(EnrollmentCredential.Code("ABCDE23456"), EnrollmentInputParser.parse("ABCDE 23456"))
        assertTrue(runCatching { EnrollmentInputParser.parse("ABCDE-I2345") }.isFailure)
    }
}
