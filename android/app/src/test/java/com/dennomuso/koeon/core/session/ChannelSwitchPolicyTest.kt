package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.model.Channel
import org.junit.Assert.assertEquals
import org.junit.Test

class ChannelSwitchPolicyTest {
    @Test fun `explicit numbers reject ambiguity and never use list order`() {
        assertEquals(12, ChannelSwitchPolicy.number("CH12 Test"))
        assertEquals(0, ChannelSwitchPolicy.number("ch0"))
        assertEquals(99, ChannelSwitchPolicy.number("CH99-Stage"))
        for (name in listOf("CH100", "CH12abc", "stage12", "12 stage", "CH-1")) assertEquals(null, ChannelSwitchPolicy.number(name))
        val one = Channel("one", "scope", "CH12 Test")
        val two = Channel("two", "scope", "CH12 Duplicate")
        assertEquals(one, ChannelSwitchPolicy.numbered(listOf(one), 12))
        assertEquals(null, ChannelSwitchPolicy.numbered(listOf(one, two), 12))
        assertEquals(null, ChannelSwitchPolicy.numbered(listOf(one), 1))
    }

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
