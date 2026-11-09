package com.dennomuso.koeon.core.livekit

/** LiveKit 2.28 transport messages only. Never retain SDP, URLs, tokens or exceptions. */
private val states = setOf("NEW", "CHECKING", "CONNECTING", "CONNECTED", "COMPLETED", "DISCONNECTED", "FAILED", "CLOSED")
private val transportPrefixes = listOf(
        "onConnection new state: " to "PUBLISHER",
        "onConnectionChange new state: " to "SUBSCRIBER",
        // The SDK uses the same ICE message for both peer connections.
        "onIceConnection new state: " to "ICE_UNSCOPED",
    )
private val pingTimeout = Regex("Ping timeout reached for ping sent at [0-9]+\\.")
private val reconnectAttempt = Regex("Reconnecting to signal, attempt [0-9]+")

internal fun transportDiagnostic(message: String): String? {
    for ((prefix, kind) in transportPrefixes) {
        if (message.startsWith(prefix)) {
            val state = message.removePrefix(prefix)
            return if (state in states) "${kind}_$state" else null
        }
    }
    return when {
        message == "network connection available, reconnecting" -> "NETWORK_AVAILABLE_RECONNECT"
        pingTimeout.matches(message) -> "SIGNAL_PING_TIMEOUT"
        message.startsWith("received close event: ") -> "SIGNAL_CLOSED"
        reconnectAttempt.matches(message) -> "SIGNAL_RECONNECT_ATTEMPT"
        message == "Attempting soft reconnect." -> "SOFT_RECONNECT"
        message == "restarting ice" -> "ICE_RESTART"
        else -> null
    }
}
