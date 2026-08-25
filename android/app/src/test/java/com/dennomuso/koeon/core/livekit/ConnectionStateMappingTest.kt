package com.dennomuso.koeon.core.livekit

import io.livekit.android.room.Room
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionStateMappingTest {
    @Test fun `all LiveKit room states map to UI states`() {
        assertEquals(IntercomConnectionState.DISCONNECTED, mapLiveKitState(Room.State.DISCONNECTED))
        assertEquals(IntercomConnectionState.CONNECTING, mapLiveKitState(Room.State.CONNECTING))
        assertEquals(IntercomConnectionState.CONNECTED, mapLiveKitState(Room.State.CONNECTED))
        assertEquals(IntercomConnectionState.RECONNECTING, mapLiveKitState(Room.State.RECONNECTING))
    }

    @Test fun `RX READY capability requires signed metadata version and stable device`() {
        assertEquals(
            "device-a",
            rxReadyCapableDeviceId("""{"deviceId":"device-a","rxReadyProtocolVersion":1}"""),
        )
        assertNull(rxReadyCapableDeviceId("""{"deviceId":"legacy"}"""))
        assertNull(rxReadyCapableDeviceId("""{"deviceId":"future","rxReadyProtocolVersion":2}"""))
    }

    @Test fun rxReadyPublishFailureClassificationNeverIncludesTheMessage() {
        val classification = rxReadyPublishFailureClass(IllegalStateException("sensitive payload"))
        assertEquals("IllegalStateException", classification)
        assertFalse(classification.contains("sensitive"))
    }
}
