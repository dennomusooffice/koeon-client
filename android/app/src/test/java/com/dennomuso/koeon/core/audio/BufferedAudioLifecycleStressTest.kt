package com.dennomuso.koeon.core.audio

import com.dennomuso.koeon.core.api.KoeonApi
import com.dennomuso.koeon.core.api.KoeonApiException
import com.dennomuso.koeon.core.ptt.TX_RELEASE_HANG_MS
import com.dennomuso.koeon.core.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

class BufferedAudioLifecycleStressTest {
    @Test fun `tail hangover includes delayed frames and final marker is last`() = runBlocking {
        val api = Batv1StressApi()
        val capture = Batv1CaptureBuffer()
        val transmitter = HttpBufferedAudioTransmitter(this, api, capture, "channel", "session", "device")
        val generation = "tail-contract"
        launch { delay(1); capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME))) }
        assertTrue(transmitter.armAndConfirmCapture(generation))
        assertTrue(transmitter.markCueBoundary(generation))
        assertTrue(transmitter.authorize("lease", generation))

        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 1 }))
        assertTrue(transmitter.beginReleaseHangover(generation, 1_000))
        val tail50 = launch { delay(50); capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 2 })) }
        val tail150 = launch { delay(150); capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 3 })) }
        val excluded300 = launch { delay(300); capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME) { 4 })) }
        delay(TX_RELEASE_HANG_MS + 20)
        assertTrue(transmitter.completeReleaseHangover(generation, 1_180))
        assertTrue(transmitter.finish(generation))
        tail50.join(); tail150.join(); excluded300.join()

        val audioRequests = api.published.filter { it.chunks.isNotEmpty() }
        val finalRequests = api.published.filter { it.finalSequence != null }
        assertEquals(listOf(0, 1, 2), audioRequests.flatMap { it.chunks }.map { it.sequence })
        assertEquals(2, finalRequests.single().finalSequence)
        assertTrue(api.published.last().finalSequence != null)
        assertEquals(2, transmitter.diagnostics().framesAcceptedAfterPttUp)
        assertEquals(2, transmitter.diagnostics().lastAudioSequence)
        assertEquals(2, transmitter.diagnostics().finalMarkerSequence)
    }

    @Test fun `API error status and code are retained without payload`() = runBlocking {
        val api = Batv1StressApi(failureFactory = { KoeonApiException(400, "BATV1_FORMAT_UNSUPPORTED", "rejected") })
        val capture = Batv1CaptureBuffer()
        val transmitter = HttpBufferedAudioTransmitter(this, api, capture, "channel", "session", "device")
        val generation = "diagnostic-contract"
        launch { delay(1); capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME))) }
        assertTrue(transmitter.armAndConfirmCapture(generation))
        assertTrue(transmitter.markCueBoundary(generation))
        assertTrue(transmitter.authorize("lease", generation))
        capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
        while (transmitter.diagnostics().lastErrorCode == null) delay(1)
        assertEquals(400, transmitter.diagnostics().lastHttpStatus)
        assertEquals("BATV1_FORMAT_UNSUPPORTED", transmitter.diagnostics().lastApiErrorCode)
        transmitter.discard(generation)
    }

    @Test fun `receiver drains final sequence and cue before player stop when END arrives first`() = runBlocking {
        val events = java.util.Collections.synchronizedList(mutableListOf<String>())
        val receiver = HttpBufferedAudioReceiver(
            scope = this,
            api = Batv1StressApi(),
            sessionId = "session",
            playerFactory = {
                object : Batv1PcmPlayer {
                    override fun start() { events += "start" }
                    override fun setRate(rate: Float) = Unit
                    override fun write(bytes: ByteArray) { events += "write" }
                    override suspend fun drain() { events += "drain" }
                    override fun stop() { events += "stop" }
                }
            },
            onActivity = { active -> events += "activity:$active" },
            onTimelineDrained = { events += "cue" },
        )
        receiver.start("rx-end-first")
        while (receiver.diagnostics().generationId == null) delay(1)
        receiver.noteControlEnd(1_000)
        withTimeout(2_000) { while (receiver.diagnostics().playerDrainCompletedAtEpochMs == null) delay(1) }
        receiver.shutdownAndAwait()

        assertTrue(events.indexOf("write") < events.indexOf("drain"))
        assertTrue(events.indexOf("drain") < events.indexOf("cue"))
        assertTrue(events.indexOf("cue") < events.indexOf("stop"))
        assertEquals(1_000L, receiver.diagnostics().controlEndReceivedAtEpochMs)
        assertEquals(0, receiver.diagnostics().finalSequence)
    }

    @Test fun `receiver final marker remains authoritative when END arrives after drain`() = runBlocking {
        val receiver = HttpBufferedAudioReceiver(
            scope = this,
            api = Batv1StressApi(),
            sessionId = "session",
            playerFactory = {
                object : Batv1PcmPlayer {
                    override fun start() = Unit
                    override fun setRate(rate: Float) = Unit
                    override fun write(bytes: ByteArray) = Unit
                    override suspend fun drain() = Unit
                    override fun stop() = Unit
                }
            },
        )
        receiver.start("rx-final-first")
        receiver.stopAndAwaitAfterNaturalCompletion()
        receiver.noteControlEnd(2_000)
        assertEquals(0, receiver.diagnostics().finalSequence)
        assertEquals(1, receiver.diagnostics().playbackCursor)
        assertEquals(2_000L, receiver.diagnostics().controlEndReceivedAtEpochMs)
    }

    @Test fun `100 publish failures stay contained inside sender child coroutine`() = runBlocking {
        val failures = AtomicInteger()
        val api = Batv1StressApi(publishFailure = { true })
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val capture = Batv1CaptureBuffer()
        val transmitter = HttpBufferedAudioTransmitter(
            scope, api, capture, "channel", "session", "device",
            onFailure = { failures.incrementAndGet() },
        )

        repeat(100) { index ->
            val generation = "publish-error-$index"
            val captureConfirmation = async(start = CoroutineStart.UNDISPATCHED) {
                transmitter.armAndConfirmCapture(generation)
            }
            withTimeout(2_000) {
                while (transmitter.diagnostics().generationId != generation) delay(1)
            }
            capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
            assertTrue("capture must be confirmed for generation $index", captureConfirmation.await())
            assertTrue(transmitter.markCueBoundary(generation))
            assertTrue(transmitter.authorize("lease", generation))
            capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
            while (failures.get() <= index) delay(1)
            transmitter.discard(generation)
        }

        delay(20)
        assertEquals(100, failures.get())
        scope.cancel()
    }

    @Test fun `100 final marker failures perform bounded cleanup without throwing`() = runBlocking {
        val failures = AtomicInteger()
        val api = Batv1StressApi(publishFailure = { request -> request.finalSequence != null })
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val capture = Batv1CaptureBuffer()
        val transmitter = HttpBufferedAudioTransmitter(
            scope, api, capture, "channel", "session", "device",
            onFailure = { failures.incrementAndGet() },
        )

        repeat(100) { index ->
            val generation = "final-error-$index"
            val captureConfirmation = async(start = CoroutineStart.UNDISPATCHED) {
                transmitter.armAndConfirmCapture(generation)
            }
            withTimeout(2_000) {
                while (transmitter.diagnostics().generationId != generation) delay(1)
            }
            capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
            assertTrue("capture must be confirmed for generation $index", captureConfirmation.await())
            assertTrue(transmitter.markCueBoundary(generation))
            assertTrue(transmitter.authorize("lease", generation))
            capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
            assertFalse(withTimeout(2_000) { transmitter.finish(generation) })
        }

        assertEquals(100, failures.get())
        scope.cancel()
    }

    @Test fun `100 receiver generations serialize player start write stop off main`() = runBlocking {
        val starts = AtomicInteger()
        val writes = AtomicInteger()
        val stops = AtomicInteger()
        val playerFactory = {
            object : Batv1PcmPlayer {
                override fun start() { starts.incrementAndGet() }
                override fun setRate(rate: Float) = Unit
                override fun write(bytes: ByteArray) { writes.incrementAndGet() }
                override suspend fun drain() = Unit
                override fun stop() { stops.incrementAndGet() }
            }
        }
        val api = Batv1StressApi()
        val receiver = HttpBufferedAudioReceiver(
            scope = this,
            api = api,
            sessionId = "session",
            playerFactory = playerFactory,
        )

        repeat(100) { index ->
            receiver.start("rx-$index")
            receiver.stopAndAwait()
        }
        receiver.shutdownAndAwait()

        assertTrue(starts.get() <= 100)
        assertEquals(starts.get(), stops.get())
        assertTrue(writes.get() <= starts.get())
    }

    @Test fun `breadcrumb ring remains bounded after lifecycle stress`() {
        val ring = Batv1BreadcrumbRing()
        repeat(100) { index ->
            ring.append(Batv1CrashBreadcrumb(index.toLong(), "android", "1.0.6 (7)", "g$index", "TX", "TX_BATCH_END", "WORKER", "OK"))
        }
        assertEquals(BATV1_BREADCRUMB_MAX_EVENTS, ring.snapshot().size)
        assertEquals(36L, ring.snapshot().first().timestampEpochMs)
        assertEquals(99L, ring.snapshot().last().timestampEpochMs)
    }
}

private suspend fun HttpBufferedAudioReceiver.stopAndAwaitAfterNaturalCompletion() {
    withTimeout(2_000) { while (diagnostics().playerDrainCompletedAtEpochMs == null) delay(1) }
    shutdownAndAwait()
}

private class Batv1StressApi(
    private val publishFailure: (Batv1PublishRequest) -> Boolean = { false },
    private val failureFactory: ((Batv1PublishRequest) -> Throwable)? = null,
) : KoeonApi {
    val published = java.util.Collections.synchronizedList(mutableListOf<Batv1PublishRequest>())
    override suspend fun publishBufferedAudio(request: Batv1PublishRequest): Batv1PublishResponse {
        published += request
        failureFactory?.invoke(request)?.let { throw it }
        if (publishFailure(request)) error("expected stress failure")
        return Batv1PublishResponse("accepted", request.chunks.size, request.chunks.lastOrNull()?.sequence ?: request.finalSequence ?: -1)
    }

    override suspend fun subscribeBufferedAudio(request: Batv1SubscribeRequest): Batv1SubscribeResponse =
        Batv1SubscribeResponse(
            generationId = request.generationId,
            latestSequence = 0,
            nextSequence = 1,
            finalSequence = 0,
            bufferHeadExpired = false,
            timelineEnded = true,
            chunks = listOf(Batv1Chunk(0, java.util.Base64.getEncoder().encodeToString(ByteArray(BATV1_BYTES_PER_FRAME)))),
        )

    override suspend fun fixture(): FixtureResponse = error("unused")
    override suspend fun enroll(request: EnrollmentRequest): EnrollmentResponse = error("unused")
    override suspend fun me(): MeResponse = error("unused")
    override suspend fun join(userId: String, channelId: String, wantsToPublish: Boolean): JoinResponse = error("unused")
    override suspend fun leave(sessionId: String): LeaveResponse = error("unused")
    override suspend fun acquire(sessionId: String): FloorResponse = error("unused")
    override suspend fun renew(sessionId: String, leaseId: String): FloorResponse = error("unused")
    override suspend fun release(sessionId: String, leaseId: String): FloorResponse = error("unused")
    override suspend fun floorStatus(sessionId: String): FloorResponse = error("unused")
    override suspend fun logout() = Unit
}
