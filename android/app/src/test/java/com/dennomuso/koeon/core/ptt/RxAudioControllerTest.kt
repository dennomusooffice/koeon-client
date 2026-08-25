package com.dennomuso.koeon.core.ptt

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import com.dennomuso.koeon.core.model.FloorResponse

@OptIn(ExperimentalCoroutinesApi::class)
class RxAudioControllerTest {
    @Test
    fun `validated START arms readiness before PCM and duplicate cannot publish twice`() = runTest {
        val harness = Harness(testScheduler, suspendStartCue = true)

        assertTrue(harness.controller.handleControl(harness.event("start", 1), "session-a"))
        assertEquals(RxState.RX_STARTING, harness.controller.current().state)
        assertEquals(false, harness.controller.handleControl(harness.event("start", 1), "session-a"))
        assertEquals(false, harness.controller.handleControl(harness.event("end", 2), "session-a"))
    }

    @Test
    fun `anonymous FAST START cannot consume sequence before identified reliable START`() = runTest {
        val harness = Harness(testScheduler, suspendStartCue = true)
        val start = harness.event("start", 1)

        assertEquals(false, harness.controller.handleControl(start, null))
        assertEquals(RxState.RX_IDLE, harness.controller.current().state)
        assertEquals(1, harness.controller.current().staleIgnored)
        assertTrue(harness.controller.handleControl(start, "session-a"))
        assertEquals(RxState.RX_STARTING, harness.controller.current().state)
        assertEquals("lease-a", harness.controller.current().leaseId)
    }

    @Test
    fun `mismatched sender identity cannot arm readiness`() = runTest {
        val harness = Harness(testScheduler)

        assertEquals(false, harness.controller.handleControl(harness.event("start", 1), "session-b"))
        assertEquals(RxState.RX_IDLE, harness.controller.current().state)
        assertEquals(1, harness.controller.current().staleIgnored)
    }

    @Test
    fun `START cue becomes active and duplicate is ignored`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        runCurrent()
        assertEquals(RxState.RX_ACTIVE, harness.controller.current().state)
        assertEquals(listOf("start-cue"), harness.cues)

        harness.controller.handleControl(harness.event("start", 1), "session-a")
        assertEquals(1, harness.controller.current().duplicateIgnored)
    }

    @Test
    fun `audio activity makes voice active without waiting for cue`() = runTest {
        val harness = Harness(testScheduler, suspendStartCue = true)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        harness.controller.handleRemoteAudioActivity("session-a", true)
        assertEquals(RxState.RX_ACTIVE, harness.controller.current().state)
    }

    @Test
    fun `remote voice before control skips start cue`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleRemoteAudioActivity("session-a", true)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        runCurrent()
        assertEquals(RxState.RX_ACTIVE, harness.controller.current().state)
        assertEquals("Skipped: voice already active", harness.controller.current().startCueResult)
        assertEquals(emptyList<String>(), harness.cues)
    }

    @Test
    fun `END preserves minimum drain then plays end cue`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        runCurrent()
        harness.controller.handleRemoteAudioActivity("session-a", false)
        harness.controller.handleControl(harness.event("end", 2), "session-a")
        advanceTimeBy(RX_DRAIN_MIN_MS - 1)
        runCurrent()
        assertEquals(RxState.RX_DRAINING, harness.controller.current().state)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(RX_DRAIN_MIN_MS, harness.controller.current().rxDrainDurationMs)
        assertTrue(harness.cues.contains("end-cue"))
    }

    @Test
    fun `active audio ends at 350ms hard cap`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        runCurrent()
        harness.controller.handleRemoteAudioActivity("session-a", true)
        harness.controller.handleControl(harness.event("end", 2), "session-a")
        advanceTimeBy(RX_DRAIN_MAX_MS - 1)
        runCurrent()
        assertEquals(RxState.RX_DRAINING, harness.controller.current().state)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(RX_DRAIN_MAX_MS, harness.controller.current().rxDrainDurationMs)
        assertEquals("hard_cap", harness.controller.current().rxEndReason)
    }

    @Test
    fun `new speaker preempts drain and stale END cannot stop it`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        harness.controller.handleControl(harness.event("end", 2), "session-a")
        harness.controller.handleControl(harness.event(
            "start",
            1,
            speaker = "staff-b",
            session = "session-b",
            lease = "lease-b",
        ), "session-b")
        assertEquals("staff-b", harness.controller.current().speakerUserId)
        assertEquals(1, harness.controller.current().preempted)

        harness.controller.handleControl(harness.event("end", 3), "session-a")
        advanceTimeBy(RX_DRAIN_MAX_MS)
        runCurrent()
        assertEquals("staff-b", harness.controller.current().speakerUserId)
        assertTrue(harness.controller.current().staleIgnored > 0)
    }

    @Test
    fun `same lease floor status keeps RX active`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        harness.controller.reconcileFloor(FloorResponse("busy", leaseId = "lease-a"))
        assertEquals(RxState.RX_STARTING, harness.controller.current().state)
    }

    @Test
    fun `available floor converges through bounded drain`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        runCurrent()
        harness.controller.handleRemoteAudioActivity("session-a", false)
        harness.controller.reconcileFloor(FloorResponse("available"))
        assertEquals(RxState.RX_DRAINING, harness.controller.current().state)
        advanceTimeBy(RX_DRAIN_MIN_MS)
        runCurrent()
        assertEquals(RxState.RX_IDLE, harness.controller.current().state)
        assertTrue(harness.cues.contains("end-cue"))
    }

    @Test
    fun `different lease convergence cannot clear preempting speaker`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.handleControl(harness.event("start", 1), "session-a")
        harness.controller.reconcileFloor(FloorResponse("busy", leaseId = "lease-b"))
        harness.controller.handleControl(harness.event(
            "start", 1, speaker = "staff-b", session = "session-b", lease = "lease-b",
        ), "session-b")
        advanceTimeBy(RX_DRAIN_MAX_MS)
        runCurrent()
        assertEquals("session-b", harness.controller.current().sessionId)
    }

    private class Harness(
        scheduler: TestCoroutineScheduler,
        suspendStartCue: Boolean = false,
    ) {
        val cues = mutableListOf<String>()
        private val scope = TestScope(scheduler)
        private val clock = object : RxClock {
            override fun nowMillis(): Long = scheduler.currentTime + 1_000
            override fun now(): Instant = Instant.ofEpochMilli(nowMillis())
            override suspend fun sleep(milliseconds: Long) = delay(milliseconds)
        }
        private val cue = object : PttCuePlayer {
            override suspend fun playStart(): Result<Unit> {
                cues += "start-cue"
                if (suspendStartCue) delay(1_000)
                return Result.success(Unit)
            }
            override suspend fun playEnd(): Result<Unit> {
                cues += "end-cue"
                return Result.success(Unit)
            }
        }
        val controller = RxAudioController(scope, "stage", cue, clock) {}

        fun event(
            type: String,
            sequence: Long,
            speaker: String = "staff-a",
            session: String = "session-a",
            lease: String = "lease-a",
        ) = PttControlEvent(
            type = type,
            channelId = "stage",
            speakerUserId = speaker,
            sessionId = session,
            leaseId = lease,
            sequence = sequence,
            sentAt = clock.nowMillis(),
        )
    }
}
