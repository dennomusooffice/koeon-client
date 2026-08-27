package com.dennomuso.koeon.core.ptt

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RxReadyTest {
    @Test fun `no expected receiver adds no wait`() = runTest {
        val result = barrier(emptyList()) { testScheduler.currentTime }.waitForReady()
        assertEquals(RxReadyReason.NO_EXPECTATIONS, result.reason)
        assertEquals(0L, result.waitMs)
    }

    @Test fun `single expected receiver requires trusted matching ACK`() = runTest {
        val barrier = barrier(listOf("receiver-a")) { testScheduler.currentTime }
        val result = async { barrier.waitForReady() }
        assertFalse(barrier.accept(event("old-lease"), "receiver-a"))
        assertFalse(barrier.accept(event("lease-a"), "receiver-b"))
        assertTrue(barrier.accept(event("lease-a"), "receiver-a"))
        runCurrent()
        assertEquals(RxReadyReason.ALL_READY, result.await().reason)
    }

    @Test fun `M1 three receivers wait for final ACK at 2800ms`() = runTest {
        val barrier = barrier(listOf("receiver-a", "receiver-b", "receiver-c")) { testScheduler.currentTime }
        val result = async { barrier.waitForReady() }
        runCurrent()
        advanceTimeBy(200)
        assertTrue(barrier.accept(event("lease-a", "receiver-a"), "receiver-a"))
        advanceTimeBy(1_200)
        assertTrue(barrier.accept(event("lease-a", "receiver-b"), "receiver-b"))
        advanceTimeBy(1_399)
        assertFalse(result.isCompleted)
        advanceTimeBy(1)
        assertTrue(barrier.accept(event("lease-a", "receiver-c"), "receiver-c"))
        runCurrent()
        val ready = result.await()
        assertEquals(RxReadyReason.ALL_READY, ready.reason)
        assertEquals(2_800L, ready.waitMs)
        assertEquals(3, ready.receivedCountAtMicOn)
    }

    @Test fun `M2 missing receiver waits until 4000ms timeout`() = runTest {
        val barrier = barrier(listOf("receiver-a", "receiver-b", "receiver-c")) { testScheduler.currentTime }
        val result = async { barrier.waitForReady() }
        runCurrent()
        advanceTimeBy(200)
        barrier.accept(event("lease-a", "receiver-a"), "receiver-a")
        advanceTimeBy(1_200)
        barrier.accept(event("lease-a", "receiver-b"), "receiver-b")
        advanceTimeBy(2_599)
        assertFalse(result.isCompleted)
        advanceTimeBy(1)
        runCurrent()
        val timeout = result.await()
        assertEquals(RxReadyReason.MULTI_TIMEOUT, timeout.reason)
        assertEquals(4_000L, timeout.waitMs)
        assertEquals(3, timeout.expectedCount)
        assertEquals(2, timeout.receivedCountAtMicOn)
        assertEquals(1, timeout.expectedCount - timeout.receivedCountAtMicOn)
    }

    @Test fun `M3 all fast receivers complete at final 80ms ACK`() = runTest {
        val barrier = barrier(listOf("receiver-a", "receiver-b", "receiver-c")) { testScheduler.currentTime }
        val result = async { barrier.waitForReady() }
        runCurrent()
        advanceTimeBy(40)
        barrier.accept(event("lease-a", "receiver-a"), "receiver-a")
        advanceTimeBy(20)
        barrier.accept(event("lease-a", "receiver-b"), "receiver-b")
        advanceTimeBy(20)
        barrier.accept(event("lease-a", "receiver-c"), "receiver-c")
        runCurrent()
        assertEquals(80L, result.await().waitMs)
    }

    @Test fun `M4 stale and duplicate ACKs do not satisfy expected count`() = runTest {
        val barrier = barrier(listOf("receiver-a", "receiver-b", "receiver-c")) { testScheduler.currentTime }
        assertFalse(barrier.accept(event("stale-lease", "receiver-a"), "receiver-a"))
        assertTrue(barrier.accept(event("lease-a", "receiver-a"), "receiver-a"))
        assertFalse(barrier.accept(event("lease-a", "receiver-a"), "receiver-a"))
        assertEquals(1, barrier.receivedCount())
        assertEquals(3, barrier.expectedCount())
    }

    @Test fun `M5 stable device IDs accept all after session rotation`() = runTest {
        val barrier = RxReadyBarrier(
            expectedSessionIds = listOf("old-a", "old-b", "old-c"),
            expectedDeviceIds = listOf("device-a", "device-b", "device-c"),
            channelId = "stage", speakerSessionId = "speaker", leaseId = "lease-a",
            elapsedRealtimeMs = { testScheduler.currentTime },
            wallClockMs = { 1_000L + testScheduler.currentTime },
        )
        val result = async { barrier.waitForReady() }
        runCurrent()
        for (suffix in listOf("a", "b", "c")) {
            assertTrue(barrier.accept(
                event("lease-a", "new-$suffix", "device-$suffix"),
                participantIdentity = "new-$suffix",
                participantDeviceId = "device-$suffix",
            ))
        }
        runCurrent()
        assertEquals(RxReadyReason.ALL_READY, result.await().reason)
    }

    @Test fun `B2 fresh session ACK is accepted after bounded metadata reconciliation`() = runTest {
        val barrier = RxReadyBarrier(
            expectedSessionIds = listOf("old-session"),
            expectedDeviceIds = listOf("stable-device"),
            channelId = "stage", speakerSessionId = "speaker", leaseId = "lease-a",
            elapsedRealtimeMs = { testScheduler.currentTime },
            wallClockMs = { 1_000L + testScheduler.currentTime },
        )
        val result = async { barrier.waitForReady() }
        assertEquals(
            RxReadyAcceptance.PENDING_PARTICIPANT_METADATA,
            barrier.acceptDetailed(
                event("lease-a", "fresh-session", "stable-device"),
                participantIdentity = "fresh-session",
                participantDeviceId = null,
            ),
        )
        advanceTimeBy(800)
        assertTrue(barrier.reconcileParticipant("fresh-session", "stable-device"))
        runCurrent()
        assertEquals(RxReadyReason.ALL_READY, result.await().reason)
        assertEquals(1, barrier.auditSnapshot().rejectedParticipantMetadataMissing)
        assertEquals(0, barrier.auditSnapshot().rejectedEvents)
    }

    @Test fun `B3 metadata reconciliation stays bounded and cannot unlock stale ACK`() = runTest {
        val barrier = RxReadyBarrier(
            expectedSessionIds = listOf("old-session"),
            expectedDeviceIds = listOf("stable-device"),
            channelId = "stage", speakerSessionId = "speaker", leaseId = "lease-a",
            elapsedRealtimeMs = { testScheduler.currentTime },
            wallClockMs = { 1_000L + testScheduler.currentTime },
        )
        barrier.acceptDetailed(
            event("lease-a", "fresh-session", "stable-device"),
            participantIdentity = "fresh-session",
            participantDeviceId = null,
        )
        advanceTimeBy(RxReadyBarrier.PENDING_METADATA_MAX_MS + 1)
        assertFalse(barrier.reconcileParticipant("fresh-session", "stable-device"))
        assertEquals(0, barrier.receivedCount())
    }

    @Test fun `B4 wrong device channel lease and session remain rejected`() = runTest {
        val barrier = RxReadyBarrier(
            expectedSessionIds = listOf("old-session"), expectedDeviceIds = listOf("stable-device"),
            channelId = "stage", speakerSessionId = "speaker", leaseId = "lease-a",
        )
        assertEquals(RxReadyAcceptance.REJECTED_DEVICE_MISMATCH, barrier.acceptDetailed(
            event("lease-a", "fresh-session", "wrong-device"), "fresh-session", "wrong-device",
        ))
        assertEquals(RxReadyAcceptance.REJECTED_LEASE_MISMATCH, barrier.acceptDetailed(
            event("wrong-lease", "fresh-session", "stable-device"), "fresh-session", "stable-device",
        ))
        assertEquals(RxReadyAcceptance.REJECTED_SESSION_MISMATCH, barrier.acceptDetailed(
            event("lease-a", "fresh-session", "stable-device"), "other-session", "stable-device",
        ))
        val wrongChannel = event("lease-a", "fresh-session", "stable-device").copy(channelId = "other")
        assertEquals(RxReadyAcceptance.REJECTED_CHANNEL_MISMATCH, barrier.acceptDetailed(
            wrongChannel, "fresh-session", "stable-device",
        ))
        assertEquals(0, barrier.receivedCount())
    }

    @Test fun `single and multi timeout stay bounded`() = runTest {
        val single = async { barrier(listOf("receiver-a")) { testScheduler.currentTime }.waitForReady() }
        advanceTimeBy(RX_READY_SINGLE_MAX_WAIT_MS)
        runCurrent()
        assertEquals(RxReadyReason.SINGLE_TIMEOUT, single.await().reason)

        val multi = async { barrier(listOf("receiver-a", "receiver-b")) { testScheduler.currentTime }.waitForReady() }
        advanceTimeBy(RX_READY_MULTI_ABSOLUTE_MAX_MS)
        runCurrent()
        assertEquals(RxReadyReason.MULTI_TIMEOUT, multi.await().reason)
    }

    @Test fun `cancel is generation safe and prevents ghost unlock`() = runTest {
        val barrier = barrier(listOf("receiver-a")) { testScheduler.currentTime }
        val result = async { barrier.waitForReady() }
        barrier.cancel()
        runCurrent()
        assertEquals(RxReadyReason.CANCELLED, result.await().reason)
        assertFalse(barrier.accept(event("other-lease"), "receiver-a"))
    }

    private fun barrier(expected: List<String>, now: () -> Long) = RxReadyBarrier(
        expectedSessionIds = expected,
        channelId = "stage",
        speakerSessionId = "speaker",
        leaseId = "lease-a",
        elapsedRealtimeMs = now,
        wallClockMs = { 1_000L + now() },
    )

    private fun event(
        leaseId: String,
        receiverSessionId: String = "receiver-a",
        receiverDeviceId: String? = null,
    ) = PttRxReadyEvent(
        channelId = "stage",
        speakerSessionId = "speaker",
        receiverSessionId = receiverSessionId,
        receiverDeviceId = receiverDeviceId,
        leaseId = leaseId,
        readyAt = 1_000,
    )
}
