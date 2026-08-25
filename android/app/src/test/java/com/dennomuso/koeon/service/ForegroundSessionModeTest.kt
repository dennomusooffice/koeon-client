package com.dennomuso.koeon.service

import org.junit.Assert.assertEquals
import org.junit.Test

class ForegroundSessionModeTest {
    @Test fun `publisher uses microphone service mode`() {
        assertEquals(ForegroundSessionMode.MICROPHONE_AND_MEDIA_PLAYBACK, foregroundSessionMode(true))
    }

    @Test fun `listener uses receive only service mode`() {
        assertEquals(ForegroundSessionMode.MEDIA_PLAYBACK, foregroundSessionMode(false))
    }

    @Test fun `wake lock is transient during start and reconnect only`() {
        assertEquals(BackgroundWakeAction.ACQUIRE_WITH_TIMEOUT, backgroundWakeAction(BackgroundWakeEvent.SESSION_STARTING))
        assertEquals(BackgroundWakeAction.ACQUIRE_WITH_TIMEOUT, backgroundWakeAction(BackgroundWakeEvent.RECONNECTING))
        assertEquals(BackgroundWakeAction.RELEASE, backgroundWakeAction(BackgroundWakeEvent.CONNECTED))
        assertEquals(BackgroundWakeAction.RELEASE, backgroundWakeAction(BackgroundWakeEvent.STOPPED))
        assertEquals(10_000L, TRANSIENT_WAKE_LOCK_TIMEOUT_MS)
    }
}
