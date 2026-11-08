package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.api.KoeonApiException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException

/** A Join expiry is not a revoked device registration. Never clear credentials here. */
internal fun requiresJoinRenewal(error: Throwable): Boolean =
    error is KoeonApiException && error.statusCode == 401 && error.errorCode == "SESSION_INVALID"

internal fun isRetryableJoinFailure(error: Throwable): Boolean = when (error) {
    is KoeonApiException -> error.statusCode == 408 || error.statusCode == 429 || error.statusCode in 500..599
    is IOException -> true
    else -> false
}

/** Main-thread intent fence; runtime teardown/rejoin are serialized by the owner's mutex. */
internal class JoinSessionRecovery {
    data class Ticket(val sessionId: String, val epoch: Long)
    private var epoch = 0L
    private var pending: Ticket? = null
    private var wake = CompletableDeferred<Unit>()

    fun invalidate() { epoch++; pending = null; wake.complete(Unit) }
    fun request(sessionId: String): Ticket? {
        if (pending != null) return null
        wake = CompletableDeferred()
        return Ticket(sessionId, ++epoch).also { pending = it }
    }

    suspend fun run(
        ticket: Ticket,
        currentSessionId: () -> String?,
        stopRuntime: suspend () -> Unit,
        rejoin: suspend () -> Boolean,
        shouldRetry: () -> Boolean = { false },
    ): Boolean {
        fun current() = pending == ticket && epoch == ticket.epoch
        try {
            if (!current() || currentSessionId() != ticket.sessionId) return false
            stopRuntime()
            // POWER OFF / channel change can occur while teardown suspends.
            if (!current()) return false
            val cancelled = wake
            var backoffMs = 1_000L
            while (current()) {
                val restored = rejoin()
                if (!current()) {
                    if (restored) stopRuntime()
                    return false
                }
                if (restored) return true
                if (!shouldRetry()) return false
                withTimeoutOrNull(backoffMs) { cancelled.await() }
                backoffMs = (backoffMs * 2).coerceAtMost(15_000)
            }
            return false
        } finally {
            if (pending == ticket) pending = null
        }
    }
}
