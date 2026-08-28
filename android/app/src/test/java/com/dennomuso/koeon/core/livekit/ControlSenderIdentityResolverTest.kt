package com.dennomuso.koeon.core.livekit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ControlSenderIdentityResolverTest {
    @Test fun `matching SDK identity is accepted`() {
        val result = resolveControlSenderIdentity("session-a", "session-a", listOf("session-a"))
        assertEquals("session-a", result.identity)
        assertEquals(ControlSenderIdentityResolution.SDK_EVENT, result.resolution)
    }

    @Test fun `mismatching SDK identity cannot fall back to payload`() {
        val result = resolveControlSenderIdentity("attacker", "session-a", listOf("session-a"))
        assertNull(result.identity)
        assertEquals(ControlSenderIdentityResolution.REJECTED, result.resolution)
    }

    @Test fun `missing SDK identity accepts exactly one current room session match`() {
        val result = resolveControlSenderIdentity(null, "session-a", listOf("session-a", "session-b"))
        assertEquals("session-a", result.identity)
        assertEquals(ControlSenderIdentityResolution.ROOM_SESSION_MATCH, result.resolution)
    }

    @Test fun `missing SDK identity rejects no stale or ambiguous room match`() {
        assertNull(resolveControlSenderIdentity(null, "session-a", listOf("session-b")).identity)
        assertNull(resolveControlSenderIdentity(null, "session-a", listOf("session-a", "session-a")).identity)
        assertNull(resolveControlSenderIdentity(null, "session-a", emptyList()).identity)
    }
}
