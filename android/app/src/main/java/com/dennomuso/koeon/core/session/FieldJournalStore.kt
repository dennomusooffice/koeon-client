package com.dennomuso.koeon.core.session

import kotlinx.serialization.json.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Serial-worker owned. No Context, microphone or network dependency. */
class FieldJournalStore(
    private val root: File,
    private val platform: String,
    private val build: String,
    private val installationId: String,
    private val maxBytes: Long = 32L * 1024 * 1024,
    private val segmentBytes: Long = 256L * 1024,
    private val retentionMs: Long = 86_400_000,
) {
    private val runId = UUID.randomUUID().toString()
    private var sequence = 0L
    private var segment = 0L
    private var current: File? = null
    private var lastSweep = Long.MIN_VALUE
    private var lastWall: Long? = null
    private var lastMono: Long? = null
    private var capacityDropped = 0L
    private var corruptDropped = 0L
    private var ioFailures = 0L
    init {
        root.mkdirs()
        val stats = runCatching { Json.parseToJsonElement(File(root, "retention.json").readText()).jsonObject }.getOrNull()
        capacityDropped = (stats?.get("capacityDroppedRecords") as? JsonPrimitive)?.longOrNull ?: 0
        corruptDropped = (stats?.get("corruptDroppedRecords") as? JsonPrimitive)?.longOrNull ?: 0
    }
    companion object {
        val keys = setOf("connection", "ptt", "rx", "operational", "lifecycle", "audio", "route", "mode",
            "runtimeGeneration", "receiveGeneration", "firstPcm", "pcmCallbacks", "pcmFrames", "pcmAtMs",
            "rxStartedAtMs", "txDownAtMs", "gainDb", "gainSamples", "gainDecision", "recoveryLevel", "restoring",
            "trackSubscribed", "participants", "readyExpected", "readyReceived", "readyTimedOut", "clockDiscontinuity")
        fun hash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        fun safeFields(data: Map<String, Any?>): JsonObject = buildJsonObject {
            data.filterKeys { it in keys }.forEach { (k, v) ->
                when (v) {
                    is Boolean -> put(k, JsonPrimitive(v))
                    is Number -> if (v.toDouble().isFinite()) put(k, JsonPrimitive(v))
                    is String -> if (v.matches(Regex("[A-Z][A-Z0-9_]{0,63}"))) put(k, JsonPrimitive(v))
                }
            }
        }
    }
    @Synchronized fun append(event: String, fields: Map<String, Any?>, ids: Map<String, String?>,
        wallMs: Long, monoMs: Long, droppedBefore: Long = 0) {
        require(event.matches(Regex("[A-Z][A-Z0-9_]{0,63}")))
        val discontinuity = lastWall?.let { kotlin.math.abs((wallMs - it) - (monoMs - (lastMono ?: monoMs))) > 60_000 } ?: false
        lastWall = wallMs; lastMono = monoMs
        val record = buildJsonObject {
            put("schema", JsonPrimitive("koeon.field-journal.v1")); put("platform", JsonPrimitive(platform))
            put("build", JsonPrimitive(build.take(64))); put("installationId", JsonPrimitive(installationId)); put("runId", JsonPrimitive(runId))
            put("sequence", JsonPrimitive(++sequence)); put("wallTimeMs", JsonPrimitive(wallMs)); put("monotonicMs", JsonPrimitive(monoMs))
            put("event", JsonPrimitive(event)); put("droppedBefore", JsonPrimitive(droppedBefore)); put("ioFailuresBefore", JsonPrimitive(ioFailures))
            put("clockDiscontinuity", JsonPrimitive(discontinuity)); put("data", safeFields(fields))
            put("correlation", buildJsonObject {
                ids.filterKeys { it in setOf("sessionHash", "speakerSessionHash", "leaseHash", "channelHash") }
                    .forEach { (k, v) -> if (!v.isNullOrBlank()) put(k, JsonPrimitive(hash(v))) }
            })
        }.toString() + "\n"
        try {
            if (lastSweep == Long.MIN_VALUE || wallMs < lastSweep || wallMs - lastSweep >= 60_000) prune(wallMs)
            if (current?.exists() != true || (current?.length() ?: 0) + record.toByteArray().size > segmentBytes) {
                current = File(root, "$runId-${++segment}.jsonl")
            }
            current!!.appendText(record)
            enforceCapacity()
        } catch (_: Exception) { ioFailures++ }
    }
    private fun files() = root.listFiles()?.filter { it.name.endsWith(".jsonl") }?.sortedBy { it.lastModified() } ?: emptyList()
    private fun rows(file: File): List<JsonObject> = file.readLines().mapNotNull { line ->
        runCatching { Json.parseToJsonElement(line).jsonObject }.getOrNull()?.takeIf {
            (it["schema"] as? JsonPrimitive)?.content == "koeon.field-journal.v1" && (it["wallTimeMs"] as? JsonPrimitive)?.longOrNull != null
        }
    }
    private fun persistStats() {
        val temp = File(root, "retention.tmp")
        temp.writeText(buildJsonObject {
            put("capacityDroppedRecords", JsonPrimitive(capacityDropped)); put("corruptDroppedRecords", JsonPrimitive(corruptDropped))
        }.toString())
        check(temp.renameTo(File(root, "retention.json")))
    }
    private fun prune(now: Long) {
        for (file in files()) {
            val all = file.readLines(); val valid = rows(file)
            corruptDropped += all.size - valid.size
            // Keep future-clock records privately until the clock catches up, within the byte cap.
            val kept = valid.filter { it.getValue("wallTimeMs").jsonPrimitive.long >= now - retentionMs }
            if (kept.isEmpty()) file.delete()
            else if (kept.size != all.size) {
                val temp = File(root, file.name + ".tmp"); temp.writeText(kept.joinToString("\n", postfix = "\n")); check(temp.renameTo(file))
            }
        }
        lastSweep = now; persistStats(); enforceCapacity()
    }
    private fun enforceCapacity() {
        val list = files(); var bytes = list.sumOf { it.length() }
        for (file in list) {
            if (bytes <= maxBytes) break
            val size = file.length(); capacityDropped += rows(file).size
            check(file.delete()); bytes -= size; persistStats()
        }
    }
    /** Two-pass bounded-segment export; no full-day array retained in memory. */
    @Synchronized fun export(destination: File, now: Long): File {
        prune(now)
        val inputs = files()
        fun included(row: JsonObject) = row.getValue("wallTimeMs").jsonPrimitive.long in (now - retentionMs)..now
        val count = inputs.sumOf { rows(it).count(::included) }
        val future = inputs.sumOf { rows(it).count { r -> r.getValue("wallTimeMs").jsonPrimitive.long > now } }
        destination.parentFile!!.mkdirs(); val temporary = File(destination.parentFile, destination.name + ".tmp")
        temporary.bufferedWriter().use { out ->
            val manifest = buildJsonObject {
                put("exportedAtMs", JsonPrimitive(now)); put("cutoffMs", JsonPrimitive(now - retentionMs)); put("recordCount", JsonPrimitive(count))
                put("capacityDroppedRecordsLifetime", JsonPrimitive(capacityDropped)); put("corruptDroppedRecordsLifetime", JsonPrimitive(corruptDropped))
                put("futureClockRecordsExcluded", JsonPrimitive(future)); put("ioFailuresThisRun", JsonPrimitive(ioFailures))
                put("retentionMs", JsonPrimitive(retentionMs)); put("maxBytes", JsonPrimitive(maxBytes))
            }
            out.write("{\"schema\":\"koeon.field-journal-export.v1\",\"manifest\":$manifest,\"records\":[")
            var first = true
            inputs.forEach { f -> rows(f).filter(::included).forEach { row ->
                if (!first) out.write(",\n"); first = false; out.write(row.toString())
            } }
            out.write("]}")
        }
        check(temporary.renameTo(destination)); return destination
    }
}

/** Testable admission limit, including the in-flight item. */
class FieldJournalAdmission(private val limit: Int = 256) {
    private var pending = 0
    private var dropped = 0L
    @Synchronized fun admit(): Boolean {
        if (pending >= limit) { dropped++; return false }
        pending++; return true
    }
    @Synchronized fun finish() { check(pending > 0); pending-- }
    @Synchronized fun takeDropped(): Long = dropped.also { dropped = 0 }
}
