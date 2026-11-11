package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.model.Channel
import org.junit.Assert.assertEquals
import org.junit.Test

class ChannelSwitchPolicyTest {
    @Test fun `explicit numbers reject ambiguity and never use list order`() {
        assertEquals(12, ChannelSwitchPolicy.number(12))
        assertEquals(0, ChannelSwitchPolicy.number(0))
        for (n in listOf(null, -1, 100)) assertEquals(null, ChannelSwitchPolicy.number(n))
        val one = Channel("one", "scope", "CH99 misleading", 12)
        val two = Channel("two", "scope", "Other", 12)
        assertEquals(null, ChannelSwitchPolicy.numbered(listOf(Channel("legacy", "scope", "CH12")), 12))
        assertEquals(one, ChannelSwitchPolicy.numbered(listOf(one), 12))
        assertEquals(null, ChannelSwitchPolicy.numbered(listOf(one, two), 12))
        assertEquals(null, ChannelSwitchPolicy.numbered(listOf(one), 1))
    }

    @Test fun `digits preserve place and shared key`() {
        assertEquals(ChannelSwitchPolicy.Digits(1, null), ChannelSwitchPolicy.digits(1, null, 1))
        assertEquals(ChannelSwitchPolicy.Digits(2, 1), ChannelSwitchPolicy.digits(12, null, 1))
        assertEquals(ChannelSwitchPolicy.Digits(1, 1), ChannelSwitchPolicy.digits(11, null, 1))
        assertEquals(ChannelSwitchPolicy.Digits(0, 1), ChannelSwitchPolicy.digits(10, null, 1))
        assertEquals(ChannelSwitchPolicy.Digits(null, 1), ChannelSwitchPolicy.digits(2, "1", 2))
        assertEquals(ChannelSwitchPolicy.Digits(null, null), ChannelSwitchPolicy.digits(null, null, 1))
    }
    @Test fun `channel JSON keeps official numbers and supports old responses`() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        for (extra in listOf("", ",\"channelNumber\":null", ",\"channelNumber\":12")) {
            val channel = json.decodeFromString<Channel>("""{"id":"synthetic","workspaceId":"scope","name":"CH99"$extra}""")
            assertEquals(if (extra.endsWith("12")) 12 else null, channel.channelNumber)
        }
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
