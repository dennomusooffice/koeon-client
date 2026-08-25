package com.dennomuso.koeon.service

internal const val TRANSIENT_WAKE_LOCK_TIMEOUT_MS = 10_000L

enum class BackgroundWakeEvent { SESSION_STARTING, RECONNECTING, CONNECTED, STOPPED }
enum class BackgroundWakeAction { ACQUIRE_WITH_TIMEOUT, RELEASE }

/** KOEON never keeps an app-owned CPU WakeLock for the whole Channel session. */
fun backgroundWakeAction(event: BackgroundWakeEvent): BackgroundWakeAction = when (event) {
    BackgroundWakeEvent.SESSION_STARTING,
    BackgroundWakeEvent.RECONNECTING,
    -> BackgroundWakeAction.ACQUIRE_WITH_TIMEOUT
    BackgroundWakeEvent.CONNECTED,
    BackgroundWakeEvent.STOPPED,
    -> BackgroundWakeAction.RELEASE
}
