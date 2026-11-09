package com.dennomuso.koeon.core.session

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class FieldJournalStoreTest {
    @Test fun `queue bounds include inflight and admission resumes after completion`() {
        val queue = FieldJournalAdmission(2)
        assertTrue(queue.admit()); assertTrue(queue.admit()); assertFalse(queue.admit())
        assertFalse(queue.admit()); assertEquals(2L, queue.takeDropped()); assertEquals(0L, queue.takeDropped())
        queue.finish(); assertTrue(queue.admit()); queue.finish(); queue.finish()
    }
    private fun sandbox(test: (File) -> Unit) {
        val dir = Files.createTempDirectory("koeon-journal-test").toFile()
        try { test(dir) } finally { dir.deleteRecursively() }
    }
    private fun read(store: FieldJournalStore, dir: File, now: Long) =
        Json.parseToJsonElement(store.export(File(dir, "export.json"), now).readText()).jsonObject
    @Test fun `restart preserves events and exact retention boundary excludes older events`() = sandbox { dir ->
        val root = File(dir, "journal")
        val first = FieldJournalStore(root, "android", "test", "installation", retentionMs = 1000)
        first.append("RX", emptyMap(), emptyMap(), 1000, 1)
        first.append("RX_PCM", emptyMap(), emptyMap(), 1001, 2)
        val second = FieldJournalStore(root, "android", "test", "installation", retentionMs = 1000)
        second.append("START", emptyMap(), emptyMap(), 2001, 0)
        val records = read(second, dir, 2001).getValue("records").jsonArray
        assertEquals(2, records.size)
        // Export is segmented; the Mac correlator orders by time, not file mtime.
        assertEquals(setOf("RX_PCM", "START"), records.map { it.jsonObject.getValue("event").jsonPrimitive.content }.toSet())
        assertNotEquals(records[0].jsonObject["runId"], records[1].jsonObject["runId"])
        second.append("TX", emptyMap(), emptyMap(), 2002, 1)
        assertEquals(2, read(second, dir, 2002).getValue("records").jsonArray.size)
    }
    @Test fun `privacy whitelist and correlation digest do not include raw secrets`() = sandbox { dir ->
        val store = FieldJournalStore(File(dir, "journal"), "android", "test", "installation")
        store.append("TX", mapOf("token" to "secret", "route" to "headset-name-private", "ptt" to "TRANSMITTING", "gainDb" to 6),
            mapOf("leaseHash" to "raw-private-lease", "token" to "secret"), 1000, 10, 4)
        val text = store.export(File(dir, "out.json"), 1000).readText()
        assertFalse(text.contains("secret")); assertFalse(text.contains("raw-private")); assertFalse(text.contains("headset-name"))
        assertTrue(text.contains(FieldJournalStore.hash("raw-private-lease")))
        assertTrue(text.contains("\"droppedBefore\":4"))
    }
    @Test fun `corrupt and partial records are counted and capacity is enforced`() = sandbox { dir ->
        val root = File(dir, "journal"); root.mkdirs()
        File(root, "broken.jsonl").writeText("{broken\n{\"schema\":[],\"wallTimeMs\":{}}\n")
        val store = FieldJournalStore(root, "android", "test", "installation", maxBytes = 1600, segmentBytes = 500)
        repeat(12) { store.append("RX", emptyMap(), emptyMap(), 1000L + it, it.toLong()) }
        val result = read(store, dir, 1012)
        assertTrue(root.listFiles()!!.filter { it.extension == "jsonl" }.sumOf { it.length() } <= 1600)
        assertEquals(2L, result.getValue("manifest").jsonObject.getValue("corruptDroppedRecordsLifetime").jsonPrimitive.long)
        assertTrue(result.getValue("manifest").jsonObject.getValue("capacityDroppedRecordsLifetime").jsonPrimitive.long > 0)
    }
    @Test fun `backward clock reports discontinuity and excludes future from export`() = sandbox { dir ->
        val store = FieldJournalStore(File(dir, "journal"), "android", "test", "installation")
        store.append("START", emptyMap(), emptyMap(), 100_000, 100)
        store.append("RX", emptyMap(), emptyMap(), 1000, 101)
        val result = read(store, dir, 1000)
        assertEquals(1, result.getValue("records").jsonArray.size)
        assertTrue(result.getValue("records").jsonArray[0].jsonObject.getValue("clockDiscontinuity").jsonPrimitive.boolean)
        assertEquals(1, result.getValue("manifest").jsonObject.getValue("futureClockRecordsExcluded").jsonPrimitive.int)
    }
}
