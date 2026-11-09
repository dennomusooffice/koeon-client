package com.dennomuso.koeon.core.audio

import org.junit.Assert.*
import org.junit.Test

class AudioBreadcrumbRetentionTest {
    private fun event(stage: String, generation: String? = null, result: String = "OK") =
        AudioLifecycleBreadcrumb(1L, "android", "test", generation?.take(8), "RX", stage, "WORKER", result)

    @Test fun `polling preserves important evidence after reload`() {
        val ring = AudioLifecycleBreadcrumbRing()
        ring.append(event("APP_BACKGROUND"))
        ring.append(event("RUNTIME_CONNECT_FAILED", result = "ERROR"))
        repeat(200) {
            ring.append(event("RX_SUBSCRIBE_BEGIN", "generation-a"), "generation-a")
            ring.append(event("RX_SUBSCRIBE_END", "generation-a"), "generation-a")
        }
        val restored = AudioLifecycleBreadcrumbRing()
        restored.replace(ring.snapshot())
        assertEquals(listOf("APP_BACKGROUND", "RUNTIME_CONNECT_FAILED", "RX_SUBSCRIBE_BEGIN", "RX_SUBSCRIBE_END"), restored.snapshot().map { it.stage })
    }

    @Test fun `exact generations remain distinct and errors are never coalesced`() {
        val ring = AudioLifecycleBreadcrumbRing()
        for (id in listOf("samepref-one", "samepref-two")) {
            repeat(20) { ring.append(event("RX_SUBSCRIBE_END", id), id) }
        }
        assertTrue(ring.append(event("RX_SUBSCRIBE_END", "samepref-two", "ERROR"), "samepref-two"))
        assertEquals(3, ring.snapshot().size)
        assertEquals("ERROR", ring.snapshot().last().resultClass)
    }

    @Test fun `coalescing window is bounded and reset for restored process`() {
        val ring = AudioLifecycleBreadcrumbRing()
        repeat(100) { ring.append(event("RX_SUBSCRIBE_BEGIN", "g$it"), "g$it") }
        assertEquals(64, ring.snapshot().size)
        assertTrue(ring.append(event("RX_SUBSCRIBE_BEGIN", "g0"), "g0"))
        assertFalse(ring.append(event("RX_SUBSCRIBE_BEGIN", "g0"), "g0"))
        ring.replace(ring.snapshot())
        assertTrue(ring.append(event("RX_SUBSCRIBE_BEGIN", "g0"), "g0"))
    }
}
