package com.dennomuso.koeon.core.audio

import org.junit.Assert.*
import org.junit.Test

class AudioFocusOwnerTest {
    private class Requester : FocusRequester {
        var granted = true
        var requests = 0
        var abandons = 0
        val callbacks = mutableListOf<(FocusSignal) -> Unit>()
        override fun request(onChange: (FocusSignal) -> Unit): Boolean {
            requests++; callbacks += onChange; return granted
        }
        override fun abandon() { abandons++ }
    }
    @Test fun permanentLossDoesNotPollButExplicitResumeRequestsAgain() {
        val r = Requester(); var gains = 0; val losses = mutableListOf<String>()
        val owner = AudioFocusOwner(r, { gains++ }, losses::add)
        owner.start(); assertTrue(owner.hasFocus)
        r.callbacks.last()(FocusSignal.LOSS)
        assertFalse(owner.hasFocus); assertEquals(1, r.requests)
        assertTrue(owner.resume()); assertEquals(2, r.requests); assertEquals(2, gains)
        assertEquals(listOf("Audio focus LOSS"), losses)
    }
    @Test fun transientGainRecoversWithoutNewRequest() {
        val r = Requester(); var gains = 0
        val owner = AudioFocusOwner(r, { gains++ }, {})
        owner.start(); r.callbacks.last()(FocusSignal.TRANSIENT_LOSS)
        assertFalse(owner.hasFocus)
        r.callbacks.last()(FocusSignal.GAIN)
        assertTrue(owner.hasFocus); assertEquals(1, r.requests); assertEquals(2, gains)
    }
    @Test fun deniedRequestAndStoppedOrReplacedCallbacksCannotClaimFocus() {
        val r = Requester(); var gains = 0
        val owner = AudioFocusOwner(r, { gains++ }, {})
        owner.start(); val old = r.callbacks.last(); old(FocusSignal.LOSS)
        r.granted = false
        assertFalse(owner.resume()); old(FocusSignal.GAIN)
        assertFalse(owner.hasFocus); assertEquals(1, gains)
        val current = r.callbacks.last(); current(FocusSignal.GAIN)
        assertFalse(owner.hasFocus)
        owner.stop(); current(FocusSignal.GAIN)
        assertFalse(owner.hasFocus); assertFalse(owner.resume()); assertEquals(2, r.requests)
    }
}
