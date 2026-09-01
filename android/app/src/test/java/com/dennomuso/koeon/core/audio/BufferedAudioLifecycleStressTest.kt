package com.dennomuso.koeon.core.audio

import com.dennomuso.koeon.core.api.KoeonApi
import com.dennomuso.koeon.core.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
            launch {
                delay(1)
                capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
            }
            assertTrue(transmitter.armAndConfirmCapture(generation))
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
            launch {
                delay(1)
                capture.appendPostProcessedPcm(ByteBuffer.wrap(ByteArray(BATV1_BYTES_PER_FRAME)))
            }
            assertTrue(transmitter.armAndConfirmCapture(generation))
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

private class Batv1StressApi(
    private val publishFailure: (Batv1PublishRequest) -> Boolean = { false },
) : KoeonApi {
    override suspend fun publishBufferedAudio(request: Batv1PublishRequest): Batv1PublishResponse {
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
            chunks = listOf(Batv1Chunk(0, android.util.Base64.encodeToString(ByteArray(BATV1_BYTES_PER_FRAME), android.util.Base64.NO_WRAP))),
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
