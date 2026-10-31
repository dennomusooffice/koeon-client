package com.dennomuso.koeon.core.ptt

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class RxReadyPublicationTest {
    @Test fun `returned SDK failures retry until the first actual success`() = runTest {
        var attempts = 0
        publishRxReadyWithRetry(isCurrent = { true }) {
            attempts++
            if (attempts < 3) Result.failure(IOException("warming")) else Result.success(Unit)
        }
        assertEquals(3, attempts)
        assertEquals(300, testScheduler.currentTime)
    }

    @Test fun `permanent Result failure is never reported as successful`() = runTest {
        var attempts = 0
        val failure = IOException("unavailable")
        val error = runCatching {
            publishRxReadyWithRetry(isCurrent = { true }) { attempts++; Result.failure(failure) }
        }.exceptionOrNull()
        assertTrue(error is IOException)
        assertEquals(failure.message, error?.message)
        assertEquals(10, attempts)
        assertEquals(1_350, testScheduler.currentTime)
    }

    @Test fun `thrown transport failure is retried but successful publication is not duplicated`() = runTest {
        var attempts = 0
        publishRxReadyWithRetry(isCurrent = { true }) {
            attempts++
            if (attempts == 1) throw IOException("warming")
            Result.success(Unit)
        }
        assertEquals(2, attempts)
    }

    @Test fun `stalled SDK request is bounded by the ready deadline`() = runTest {
        var attempts = 0
        val error = runCatching {
            publishRxReadyWithRetry(isCurrent = { true }) {
                attempts++
                delay(60_000)
                Result.success(Unit)
            }
        }.exceptionOrNull()
        assertTrue(error is RxReadyPublicationTimeoutException)
        assertEquals(1, attempts)
        assertEquals(4_000, testScheduler.currentTime)
    }

    @Test fun `disconnect or lease change during retry prevents another publish`() = runTest {
        var current = true
        var attempts = 0
        val error = runCatching {
            publishRxReadyWithRetry(isCurrent = { current }) {
                attempts++
                current = false
                Result.failure(IOException("replaced"))
            }
        }.exceptionOrNull()
        assertTrue(error is CancellationException)
        assertEquals(1, attempts)
    }

    @Test fun `late SDK success cannot mark a replaced generation ready`() = runTest {
        var current = true
        val error = runCatching {
            publishRxReadyWithRetry(isCurrent = { current }) {
                current = false
                Result.success(Unit)
            }
        }.exceptionOrNull()
        assertTrue(error is CancellationException)
    }

    @Test fun `SDK Result cancellation is propagated without retry`() = runTest {
        var attempts = 0
        val error = runCatching {
            publishRxReadyWithRetry(isCurrent = { true }) {
                attempts++
                Result.failure(CancellationException("cancelled"))
            }
        }.exceptionOrNull()
        assertTrue(error is CancellationException)
        assertEquals(1, attempts)
    }

    @Test fun `parent cancellation cancels the in-flight call without retry`() = runTest {
        val started = CompletableDeferred<Unit>()
        var attempts = 0
        var completed = false
        val job = launch {
            publishRxReadyWithRetry(isCurrent = { true }) {
                attempts++
                started.complete(Unit)
                delay(10_000)
                Result.success(Unit)
            }
            completed = true
        }
        started.await()
        job.cancelAndJoin()
        assertTrue(job.isCancelled)
        assertFalse(completed)
        assertEquals(1, attempts)
    }
}
