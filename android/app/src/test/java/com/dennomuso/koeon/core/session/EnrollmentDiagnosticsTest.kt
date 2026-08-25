package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.api.KoeonApiException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class EnrollmentDiagnosticsTest {
    @Test
    fun `deep link enrollment failure reports source and backend status without invite token`() {
        val inviteToken = "A".repeat(43)
        val diagnostic = enrollmentFailureDiagnostic(
            source = "deep_link",
            error = KoeonApiException(400, "INVALID_REQUEST", "Request body is invalid"),
        )

        assertEquals(
            "Device enrollment failed (deep_link, HTTP 400/INVALID_REQUEST): Request body is invalid",
            diagnostic,
        )
        assertFalse(diagnostic.contains(inviteToken))
    }
}