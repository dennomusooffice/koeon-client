package com.dennomuso.koeon.core.livekit

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10

/** Ephemeral decoded PCM RMS, before device output volume; never retains PCM. */
class ReceiveLevelMeter {
    private data class Reading(val atMs: Long, val db: Float?)
    private var nextToken = 0L
    private val tracks = mutableMapOf<Long, Reading>()
    private var inputFormat = "未取得"
    @Synchronized fun format(): String = inputFormat

    @Synchronized fun attach(): Long = (++nextToken).also { tracks[it] = Reading(Long.MIN_VALUE, null) }
    @Synchronized fun detach(token: Long) { tracks.remove(token) }
    @Synchronized fun reset() { tracks.clear(); inputFormat = "未取得" }

    @Synchronized fun record(token: Long, data: ByteBuffer, bits: Int, channels: Int, frames: Int, nowMs: Long) {
        val previous = tracks[token] ?: return
        if (previous.atMs != Long.MIN_VALUE && nowMs - previous.atMs in 0..99) return
        inputFormat = "$bits bit / $channels ch / $frames frames / pos ${data.position()} / limit ${data.limit()}"
        tracks[token] = Reading(nowMs, pcm16Dbfs(data, bits, channels, frames))
    }

    @Synchronized fun value(nowMs: Long): Float? = tracks.values
        .filter { it.atMs != Long.MIN_VALUE && nowMs - it.atMs in 0..300 }
        .mapNotNull { it.db }.maxOrNull()

    companion object {
        fun pcm16Dbfs(data: ByteBuffer, bits: Int, channels: Int, frames: Int): Float? {
            if (bits != 16 || channels !in 1..8 || frames <= 0 || frames > 8192 / channels) return null
            val count = frames * channels
            // SDK callbacks describe the complete frame from index zero. A reused
            // buffer may retain another sink's cursor; never mutate the shared cursor.
            val samples = data.duplicate().order(ByteOrder.nativeOrder())
            samples.rewind()
            if (samples.remaining() < count * 2) return null
            var energy = 0.0
            repeat(count) { val sample = samples.short / 32768.0; energy += sample * sample }
            return if (energy == 0.0) -96f else (10.0 * log10(energy / count)).toFloat().coerceIn(-96f, 0f)
        }
    }
}
