package com.dennomuso.koeon.core.ptt

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull

/** Retry a warming reliable channel, without turning a failed SDK Result into readiness. */
internal suspend fun publishRxReadyWithRetry(
    isCurrent: () -> Boolean,
    publish: suspend () -> Result<Unit>,
) {
    val completed = withTimeoutOrNull(RX_READY_SINGLE_MAX_WAIT_MS) {
        repeat(10) { attempt ->
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) throw CancellationException("Readiness generation ended")
            try {
                publish().getOrThrow()
                currentCoroutineContext().ensureActive()
                if (!isCurrent()) throw CancellationException("Readiness generation changed")
                return@withTimeoutOrNull true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                if (attempt == 9) throw error
            }
            delay(150)
        }
        false
    }
    if (completed != true) throw RxReadyPublicationTimeoutException()
}

internal class RxReadyPublicationTimeoutException : IllegalStateException("Readiness publication timed out")
