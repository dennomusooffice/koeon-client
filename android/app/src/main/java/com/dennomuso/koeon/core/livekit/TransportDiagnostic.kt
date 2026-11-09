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
private val leaveReasons = setOf("UNKNOWN_REASON", "CLIENT_INITIATED", "DUPLICATE_IDENTITY", "SERVER_SHUTDOWN",
    "PARTICIPANT_REMOVED", "ROOM_DELETED", "STATE_MISMATCH", "JOIN_FAILURE", "MIGRATION", "SIGNAL_CLOSE",
    "ROOM_CLOSED", "USER_UNAVAILABLE", "USER_REJECTED", "SIP_TRUNK_FAILURE", "CONNECTION_TIMEOUT", "MEDIA_FAILURE", "AGENT_ERROR")
private val closeCode = Regex("received close event: [\\s\\S]*, code: ([0-9]{4})")

internal fun transportDiagnostic(message: String): String? {
    if (message.startsWith("leave request received: reason = ")) {
        val reason = message.removePrefix("leave request received: reason = ")
        return if (reason in leaveReasons) "SERVER_LEAVE_$reason" else null
    }
    for ((prefix, kind) in transportPrefixes) {
        if (message.startsWith(prefix)) {
            val state = message.removePrefix(prefix)
            return if (state in states) "${kind}_$state" else null
        }
    }
    return when {
        message == "network connection available, reconnecting" -> "NETWORK_AVAILABLE_RECONNECT"
        pingTimeout.matches(message) -> "SIGNAL_PING_TIMEOUT"
        message.startsWith("received close event: ") -> closeCode.matchEntire(message)?.groupValues?.get(1)
            ?.let { "SIGNAL_CLOSED_$it" } ?: "SIGNAL_CLOSED"
        reconnectAttempt.matches(message) -> "SIGNAL_RECONNECT_ATTEMPT"
        message == "Attempting soft reconnect." -> "SOFT_RECONNECT"
        message == "restarting ice" -> "ICE_RESTART"
        else -> null
    }
}
