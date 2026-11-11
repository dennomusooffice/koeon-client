package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.model.Channel

object ChannelSwitchPolicy {
    fun canConfirm(entry: String?, count: Int, named: Boolean): Boolean =
        named || (entry != null && count in 1..2 && entry.length == count && number(entry.toIntOrNull()) != null)

    fun number(value: Int?): Int? = value?.takeIf { it in 0..99 }
    data class Digits(val ones: Int?, val tens: Int?)
    fun digits(number: Int?, entry: String?, count: Int): Digits {
        if (entry != null) {
            val values = entry.mapNotNull { it.digitToIntOrNull() }
            return if (count == 2) Digits(values.getOrNull(1), values.firstOrNull()) else Digits(values.firstOrNull(), null)
        }
        val n = number(number) ?: return Digits(null, null)
        return Digits(n % 10, if (n >= 10) n / 10 else null)
    }
    fun numbered(channels: List<Channel>, number: Int): Channel? =
        channels.filter { this.number(it.channelNumber) == number }.singleOrNull()

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
