package com.dennomuso.koeon

import androidx.test.platform.app.InstrumentationRegistry
import com.dennomuso.koeon.core.api.HttpKoeonApi
import com.dennomuso.koeon.core.audio.*
import com.dennomuso.koeon.core.model.*
import kotlinx.coroutines.*
import org.junit.Test
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import java.net.HttpURLConnection
import java.net.URL
import java.util.Base64
import org.json.JSONObject

class MixedEmulatorTransportTest {
    @Test fun cancellingStalledReceiveAllowsNextGeneration() = runBlocking {
        val role = InstrumentationRegistry.getArguments().getString("labRole")
        assumeNotNull(role)
        val id = role!!
        val api = HttpKoeonApi("http://127.0.0.1:18765")
        api.publishBufferedAudio(Batv1PublishRequest(1, "$id-after-cancel", "lab", id, id,
            "lab-lease", "pcm16le", 48000, 1, 20, id,
            (0..31).map { Batv1Chunk(it, Base64.getEncoder().encodeToString(ByteArray(1920))) }, 31))
        val done = CompletableDeferred<BufferedAudioRxSnapshot>()
        var frames = 0
        val player = object : Batv1PcmPlayer {
            override fun start() {}
            override fun setRate(rate: Float) {}
            override fun write(bytes: ByteArray) { frames++ }
            override suspend fun drain() {}
            override fun stop() {}
        }
        val receiver = HttpBufferedAudioReceiver(this, api, id, playerFactory = { player },
            onTerminalSnapshot = { done.complete(it) })
        try {
            receiver.start("lab-stalled")
            withTimeout(5000) {
                while (true) {
                    val status = withContext(Dispatchers.IO) { URL("http://127.0.0.1:18765/lab/status").readText() }
                    if (JSONObject(status).getJSONObject("attempts").has("$id:lab-stalled")) break
                    delay(20)
                }
            }
            receiver.start("$id-after-cancel")
            withTimeout(2000) { done.await() }
            assertEquals(32, frames)
        } finally { receiver.shutdownAndAwait() }
    }

    @Test fun mixedNativeTransportAndRecovery() = runBlocking {
        val role = InstrumentationRegistry.getArguments().getString("labRole")
        assumeNotNull(role)
        val id = role!!
        val api = HttpKoeonApi("http://127.0.0.1:18765")
        val scenarios = listOf("normal", "transient", "expired", "recovered")
        for (scenario in scenarios) {
            api.publishBufferedAudio(Batv1PublishRequest(1, "$id-$scenario", "lab", id, id,
                "lab-lease", "pcm16le", 48000, 1, 20, id,
                (0..31).map { Batv1Chunk(it, Base64.getEncoder().encodeToString(ByteArray(1920) { _ -> it.toByte() })) }, 31))
        }
        for (sender in listOf("android35", "android36", "ios27")) for (scenario in scenarios) {
            val frames = mutableListOf<ByteArray>()
            val done = CompletableDeferred<BufferedAudioRxSnapshot>()
            val player = object : Batv1PcmPlayer {
                override fun start() {}
                override fun setRate(rate: Float) {}
                override fun write(bytes: ByteArray) { frames.add(bytes.copyOf()) }
                override suspend fun drain() {}
                override fun stop() {}
            }
            val receiver = HttpBufferedAudioReceiver(this, api, id, playerFactory = { player },
                onTerminalSnapshot = { done.complete(it) })
            try {
                receiver.start("$sender-$scenario")
                withTimeout(120000) { done.await() }
            } finally { receiver.shutdownAndAwait() }
            // Current Android behavior: plays the remaining tail when the head expired.
            val first = if (scenario == "expired") 28 else 0
            assertEquals(32 - first, frames.size)
            frames.forEachIndexed { index, bytes -> assertArrayEquals(ByteArray(1920) { (first + index).toByte() }, bytes) }
            val connection = URL("http://127.0.0.1:18765/lab/result").openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(JSONObject(mapOf("role" to id, "sender" to sender,
                "scenario" to scenario, "frames" to frames.size)).toString().toByteArray()) }
            assertEquals(200, connection.responseCode)
            connection.disconnect()
        }
    }
}
