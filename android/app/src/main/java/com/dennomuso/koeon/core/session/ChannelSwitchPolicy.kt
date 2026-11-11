package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.model.Channel

object ChannelSwitchPolicy {
    private val numberPattern = Regex("^CH\\s*([0-9]{1,2})(?=$|[\\s_:：\\-・])", RegexOption.IGNORE_CASE)
    fun number(name: String): Int? = numberPattern.find(name)?.groupValues?.get(1)?.toIntOrNull()
    fun numbered(channels: List<Channel>, number: Int): Channel? =
        channels.filter { this.number(it.name) == number }.singleOrNull()

    fun ordered(channels: List<Channel>): List<Channel> =
        channels.sortedWith(compareBy<Channel>({ it.name }, { it.id }))

    fun adjacent(channels: List<Channel>, currentId: String, direction: Int): String? {
        val ordered = ordered(channels)
        if (ordered.isEmpty()) return null
        val current = ordered.indexOfFirst { it.id == currentId }.takeIf { it >= 0 } ?: 0
        val next = (current + direction).mod(ordered.size)
        return ordered[next].id
    }
}
