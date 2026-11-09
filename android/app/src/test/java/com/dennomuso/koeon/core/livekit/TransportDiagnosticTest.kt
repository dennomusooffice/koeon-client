package com.dennomuso.koeon.core.livekit

import org.junit.Assert.*
import org.junit.Test

class TransportDiagnosticTest {
    @Test fun distinguishesPublisherSubscriberAndSignal() {
        assertEquals("PUBLISHER_DISCONNECTED", transportDiagnostic("onConnection new state: DISCONNECTED"))
        assertEquals("SUBSCRIBER_FAILED", transportDiagnostic("onConnectionChange new state: FAILED"))
        assertEquals("ICE_UNSCOPED_CONNECTED", transportDiagnostic("onIceConnection new state: CONNECTED"))
        assertEquals("SIGNAL_PING_TIMEOUT", transportDiagnostic("Ping timeout reached for ping sent at 1234."))
        assertEquals("SIGNAL_CLOSED", transportDiagnostic("received close event: private reason, code: 1006"))
    }
    @Test fun dropsSensitivePayloadsAndUnknownStates() {
        for (message in listOf("response: token=secret", "sdp type: OFFER\ndescription: secret",
            "onIceCandidate: private-address", "onConnection new state: CONNECTED token=secret",
            "onConnection new state: UNKNOWN", "Ping timeout reached for ping sent at secret.")) {
            assertNull(message, transportDiagnostic(message))
        }
    }
    @Test fun emitsOnlyBoundedJournalSafeCategories() {
        for (message in listOf("network connection available, reconnecting", "Reconnecting to signal, attempt 999",
            "Attempting soft reconnect.", "restarting ice", "received close event: secret\nother secrets")) {
            val result = transportDiagnostic(message)!!
            assertTrue(result.matches(Regex("[A-Z][A-Z0-9_]{0,63}")))
            assertFalse(result.contains("secret"))
        }
    }
}
