package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.model.Channel
import org.junit.Assert.assertEquals
import org.junit.Test

class ChannelSwitchPolicyTest {
    private val channels = listOf(
        Channel("reception", "workspace", "04 受付"),
        Channel("stage", "workspace", "02 ステージ"),
        Channel("operations", "workspace", "01 運営本部"),
    )

    @Test fun `stable order wraps previous and next`() {
        assertEquals(listOf("operations", "stage", "reception"), ChannelSwitchPolicy.ordered(channels).map { it.id })
        assertEquals("operations", ChannelSwitchPolicy.adjacent(channels, "reception", 1))
        assertEquals("reception", ChannelSwitchPolicy.adjacent(channels, "operations", -1))
    }
}
