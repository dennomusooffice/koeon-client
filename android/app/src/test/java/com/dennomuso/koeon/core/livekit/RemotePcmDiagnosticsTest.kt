package com.dennomuso.koeon.core.livekit

import org.junit.Assert.assertEquals
import org.junit.Test

class RemotePcmDiagnosticsTest {
    @Test fun delayedCallbacksCannotContaminateNextRoom() {
        val d = RemotePcmDiagnostics()
        val old = d.attach()
        d.record(old, 480, 48000, 1000)
        d.reset()
        val current = d.attach()
        d.record(old, 960, 48000, 2000)
        assertEquals(0L, d.snapshot().callbacks)
        d.record(current, 480, 48000, 3000)
        assertEquals(RemotePcmSnapshot(1, 1, 480, 3000, 48000), d.snapshot())
    }

    @Test fun unsubscribeRetainsEvidenceButRejectsLateCallback() {
        val d = RemotePcmDiagnostics()
        val token = d.attach()
        d.record(token, 480, 48000, 1000)
        d.detach(token)
        d.record(token, 480, 48000, 2000)
        assertEquals(RemotePcmSnapshot(0, 1, 480, 1000, 48000), d.snapshot())
    }

    @Test fun concurrentTracksAccumulateWithoutRetainingAudioOrIdentity() {
        val d = RemotePcmDiagnostics()
        val a = d.attach()
        val b = d.attach()
        val threads = listOf(a, b).map { token ->
            Thread { repeat(1000) { d.record(token, 480, 48000, 1000) } }.also { it.start() }
        }
        threads.forEach { it.join() }
        assertEquals(RemotePcmSnapshot(2, 2000, 960000, 1000, 48000), d.snapshot())
        d.record(a, 0, 48000, 2000)
        d.record(a, 480, 0, 2000)
        assertEquals(2000L, d.snapshot().callbacks)
    }
}
