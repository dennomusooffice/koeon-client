package com.dennomuso.koeon.core.ptt

import com.dennomuso.koeon.core.model.FloorOwner
import com.dennomuso.koeon.core.model.FloorResponse
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

@OptIn(ExperimentalCoroutinesApi::class)
class PttControllerTest {
    @Test
    fun `grant plays start cue before microphone TX`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)

        assertEquals(PttState.TRANSMITTING, harness.controller.current().state)
        assertEquals(listOf("acquire", "control-start", "start-cue", "mic-on"), harness.events.take(4))
        assertTrue(harness.controller.current().timing.cueEndAt!! <= harness.controller.current().timing.trackEnabledAt!!)
    }

    @Test
    fun `busy never plays cue or enables microphone`() = runTest {
        val harness = Harness(testScheduler, acquire = FloorResponse("busy", FloorOwner("other", "Staff B")))
        harness.controller.pressDown(true)

        assertEquals(PttState.BUSY, harness.controller.current().state)
        assertFalse(harness.events.contains("start-cue"))
        assertFalse(harness.events.contains("mic-on"))
        assertTrue(harness.events.contains("busy-cue"))
    }

    @Test
    fun `PTT up mutes before end cue and release`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        harness.events.clear()
        harness.controller.pressUp()

        assertEquals(PttState.IDLE, harness.controller.current().state)
        assertEquals("mic-off", harness.events.first())
        assertTrue(harness.events.indexOf("mic-off") < harness.events.indexOf("end-cue"))
        assertTrue(harness.events.indexOf("mic-off") < harness.events.indexOf("control-end"))
        assertEquals(TX_RELEASE_HANG_MS, harness.micOffAt)
        assertEquals(TX_RELEASE_HANG_MS + TX_POST_MUTE_FLUSH_MS, harness.controlEndAt)
    }

    @Test
    fun `UP during RX Ready wait cancels arm and never enables microphone`() = runTest {
        val harness = Harness(
            testScheduler,
            acquire = FloorResponse("granted", FloorOwner("staff-a", "Staff A"), "lease-1",
                rxReadyExpectedSessionIds = listOf("receiver-a")),
        )
        val down = backgroundScope.launch { harness.controller.pressDown(true) }
        runCurrent()
        assertFalse(harness.microphoneEnabled)

        harness.controller.pressUp()
        runCurrent()

        assertFalse(harness.microphoneEnabled)
        assertFalse(harness.events.contains("mic-on"))
        assertEquals(PttState.IDLE, harness.controller.current().state)
        down.cancel()
    }

    @Test
    fun `expected receiver ACK unlocks start cue and microphone`() = runTest {
        val harness = Harness(
            testScheduler,
            acquire = FloorResponse("granted", FloorOwner("staff-a", "Staff A"), "lease-1",
                rxReadyExpectedSessionIds = listOf("receiver-a")),
        )
        val down = backgroundScope.launch { harness.controller.pressDown(true) }
        runCurrent()
        assertFalse(harness.microphoneEnabled)
        harness.ack("receiver-a")
        runCurrent()

        assertTrue(harness.microphoneEnabled)
        assertEquals(1, harness.controller.current().rxReadyReceivedCount)
        down.cancel()
    }

    @Test
    fun `renews once per second while transmitting`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        advanceTimeBy(3_100)
        runCurrent()

        assertEquals(3, harness.renewCount)
        assertEquals(PttState.TRANSMITTING, harness.controller.current().state)
    }

    @Test
    fun `renew failure disables TX and discards lease`() = runTest {
        val harness = Harness(testScheduler, failRenewAt = 1)
        harness.controller.pressDown(true)
        advanceTimeBy(1_100)
        runCurrent()

        assertEquals(PttState.ERROR, harness.controller.current().state)
        assertNull(harness.controller.current().leaseId)
        assertFalse(harness.microphoneEnabled)
    }

    @Test
    fun `maximum TX stops at 60 seconds and does not reacquire`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        advanceTimeBy(MAX_CONTINUOUS_TX_MS + 1)
        runCurrent()

        assertEquals(PttState.IDLE, harness.controller.current().state)
        assertEquals(1, harness.acquireCount)
        assertFalse(harness.microphoneEnabled)
        assertTrue(harness.events.contains("end-cue"))
    }

    @Test
    fun `listener remains RX only without backend acquire`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(false)

        assertEquals(PttState.RX_ONLY, harness.controller.current().state)
        assertEquals(0, harness.acquireCount)
        assertFalse(harness.microphoneEnabled)
    }

    @Test
    fun `cue failure is non fatal and TX still starts`() = runTest {
        val harness = Harness(testScheduler, cueFailure = true)
        harness.controller.pressDown(true)

        assertEquals(PttState.TRANSMITTING, harness.controller.current().state)
        assertTrue(harness.controller.current().startCueResult.startsWith("Failed:"))
        assertTrue(harness.microphoneEnabled)
    }

    @Test
    fun `floor exception plays error cue without TX`() = runTest {
        val harness = Harness(testScheduler, acquireFailure = true)
        harness.controller.pressDown(true)

        assertEquals(PttState.ERROR, harness.controller.current().state)
        assertTrue(harness.events.contains("error-cue"))
        assertFalse(harness.events.contains("mic-on"))
    }

    @Test
    fun `audio unavailable rejection plays error cue`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.rejectForAudioUnavailable()
        assertTrue(harness.events.contains("error-cue"))
        assertEquals(PttState.IDLE, harness.controller.current().state)
    }

    @Test
    fun `fifty rapid press cycles settle idle`() = runTest {
        val harness = Harness(testScheduler)
        repeat(50) {
            harness.controller.pressDown(true)
            harness.controller.pressUp()
        }
        assertEquals(PttState.IDLE, harness.controller.current().state)
        assertFalse(harness.microphoneEnabled)
        assertEquals(50, harness.acquireCount)
    }

    @Test
    fun `audio focus loss while TX disables microphone and releases floor`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        harness.controller.stopForSafety("Audio focus lost")

        assertEquals(PttState.ERROR, harness.controller.current().state)
        assertFalse(harness.microphoneEnabled)
        assertTrue(harness.events.contains("release"))
        assertEquals(0L, harness.micOffAt)
    }

    @Test
    fun `safety stop preempts an in-progress normal tail without waiting`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        backgroundScope.launch { harness.controller.pressUp() }
        runCurrent()
        backgroundScope.launch { harness.controller.stopForSafety("route loss") }
        runCurrent()

        assertEquals(0L, harness.micOffAt)
        assertEquals(PttState.ERROR, harness.controller.current().state)
        assertTrue(harness.events.contains("release"))
    }

    @Test
    fun `disconnect while floor owner disables TX and releases floor`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        harness.controller.stopForSafety("LiveKit disconnected")

        assertEquals(PttState.ERROR, harness.controller.current().state)
        assertFalse(harness.microphoneEnabled)
        assertTrue(harness.events.contains("release"))
    }

    @Test
    fun `late renew failure cannot overwrite max TX completion`() = runTest {
        val harness = Harness(testScheduler)
        harness.controller.pressDown(true)
        advanceTimeBy(MAX_CONTINUOUS_TX_MS + 1)
        runCurrent()

        assertEquals(PttState.IDLE, harness.controller.current().state)
        assertEquals(1, harness.events.count { it == "release" })
        assertFalse(harness.microphoneEnabled)
    }

    @Test
    fun `TX OFF failure skips end cue and still releases floor`() = runTest {
        val harness = Harness(testScheduler, microphoneOffSucceeds = false)
        harness.controller.pressDown(true)
        harness.events.clear()
        harness.controller.pressUp()

        assertEquals(PttState.ERROR, harness.controller.current().state)
        assertTrue(harness.events.contains("mic-off"))
        assertFalse(harness.events.contains("end-cue"))
        assertFalse(harness.events.contains("control-end"))
        assertTrue(harness.events.contains("release"))
        assertTrue(harness.controller.current().endCueResult.startsWith("Skipped:"))
    }

    private class Harness(
        scheduler: TestCoroutineScheduler,
        private val acquire: FloorResponse = FloorResponse(
            outcome = "granted",
            owner = FloorOwner("staff-a", "Staff A"),
            leaseId = "lease-1",
        ),
        private val failRenewAt: Int? = null,
        cueFailure: Boolean = false,
        private val microphoneOffSucceeds: Boolean = true,
        private val acquireFailure: Boolean = false,
    ) {
        val events = mutableListOf<String>()
        var acquireCount = 0
        var renewCount = 0
        var microphoneEnabled = false
        var micOffAt: Long? = null
        var controlEndAt: Long? = null
        private var readyBarrier: RxReadyBarrier? = null

        private val floor = object : FloorGateway {
            override suspend fun acquire(): FloorResponse {
                events += "acquire"
                acquireCount++
                if (acquireFailure) throw IllegalStateException("offline")
                return acquire
            }

            override suspend fun renew(leaseId: String): FloorResponse {
                events += "renew"
                renewCount++
                return if (failRenewAt == renewCount) FloorResponse("not_owner") else FloorResponse("renewed", leaseId = leaseId, isOwner = true)
            }

            override suspend fun release(leaseId: String): FloorResponse {
                events += "release"
                return FloorResponse("released")
            }
        }
        private val microphone = object : MicrophoneGateway {
            override suspend fun setEnabled(enabled: Boolean): Boolean {
                if (enabled || microphoneOffSucceeds) microphoneEnabled = enabled
                if (!enabled) micOffAt = scheduler.currentTime
                events += if (enabled) "mic-on" else "mic-off"
                return enabled || microphoneOffSucceeds
            }
        }
        private val control = object : PttControlGateway {
            override fun prepareRxReady(leaseId: String, expectedSessionIds: List<String>) {
                readyBarrier = RxReadyBarrier(
                    expectedSessionIds,
                    channelId = "stage",
                    speakerSessionId = "speaker",
                    leaseId = leaseId,
                    elapsedRealtimeMs = { scheduler.currentTime },
                    wallClockMs = { 1_000L + scheduler.currentTime },
                )
            }

            override suspend fun publishStart(leaseId: String): Result<Unit> {
                events += "control-start"
                return Result.success(Unit)
            }

            override suspend fun awaitRxReady(leaseId: String): RxReadyResult =
                readyBarrier?.waitForReady()
                    ?: RxReadyResult(RxReadyReason.NO_EXPECTATIONS, 0, 0, 1.0, 0, 0)

            override suspend fun publishEnd(leaseId: String): Result<Unit> {
                events += "control-end"
                controlEndAt = scheduler.currentTime
                return Result.success(Unit)
            }

            override fun cancelRxReady() {
                readyBarrier?.cancel()
            }
        }
        private val cue = object : PttCuePlayer {
            override suspend fun playStart(): Result<Unit> {
                events += "start-cue"
                return if (cueFailure) Result.failure(IllegalStateException("cue unavailable")) else Result.success(Unit)
            }

            override suspend fun playEnd(): Result<Unit> {
                events += "end-cue"
                return Result.success(Unit)
            }

            override suspend fun playBusy(): Result<Unit> {
                events += "busy-cue"
                return Result.success(Unit)
            }

            override suspend fun playError(): Result<Unit> {
                events += "error-cue"
                return Result.success(Unit)
            }
        }
        private val clock = object : PttClock {
            override fun now(): Instant = Instant.ofEpochMilli(scheduler.currentTime)
            override fun elapsedRealtimeMs(): Long = scheduler.currentTime
        }
        val controller = PttController(
            scope = kotlinx.coroutines.test.TestScope(scheduler),
            floor = floor,
            microphone = microphone,
            cuePlayer = cue,
            control = control,
            clock = clock,
            onSnapshot = {},
        )

        fun ack(receiverSessionId: String) {
            readyBarrier?.accept(
                PttRxReadyEvent(
                    channelId = "stage",
                    speakerSessionId = "speaker",
                    receiverSessionId = receiverSessionId,
                    leaseId = "lease-1",
                    readyAt = 1_000,
                ),
                receiverSessionId,
            )
        }
    }
}
