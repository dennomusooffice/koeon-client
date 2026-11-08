package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.api.KoeonApiException

/** A Join expiry is not a revoked device registration. Never clear credentials here. */
internal fun requiresJoinRenewal(error: Throwable): Boolean =
    error is KoeonApiException && error.statusCode == 401 && error.errorCode == "SESSION_INVALID"

/** Main-thread intent fence; runtime teardown/rejoin are serialized by the owner's mutex. */
internal class JoinSessionRecovery {
    data class Ticket(val sessionId: String, val epoch: Long)
    private var epoch = 0L
    private var pending: Ticket? = null

    fun invalidate() { epoch++; pending = null }
    fun request(sessionId: String): Ticket? {
        if (pending != null) return null
        return Ticket(sessionId, ++epoch).also { pending = it }
    }

    suspend fun run(
        ticket: Ticket,
        currentSessionId: () -> String?,
        stopRuntime: suspend () -> Unit,
        rejoin: suspend () -> Boolean,
    ): Boolean {
        fun current() = pending == ticket && epoch == ticket.epoch
        try {
            if (!current() || currentSessionId() != ticket.sessionId) return false
            stopRuntime()
            // POWER OFF / channel change can occur while teardown suspends.
            if (!current()) return false
            return rejoin()
        } finally {
            if (pending == ticket) pending = null
        }
    }
}
