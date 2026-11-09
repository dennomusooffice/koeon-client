import Foundation
import CryptoKit

/// Main-actor RX observer fence: snapshot regressions must not count one PCM twice.
struct FieldJournalRxPcmGate {
    private var runtime = -1
    private var generation = -1
    mutating func accept(runtime: Int, generation: Int) -> Bool {
        guard generation > 0, runtime >= self.runtime,
              runtime > self.runtime || generation > self.generation else { return false }
        self.runtime = runtime
        self.generation = generation
        return true
    }
}

/// Owned by a serial writer. No audio samples, credentials or network access.
final class FieldJournalStore: @unchecked Sendable {
    static let keys: Set<String> = ["connection", "ptt", "rx", "operational", "lifecycle", "audio", "route", "mode",
        "runtimeGeneration", "receiveGeneration", "firstPcm", "pcmCallbacks", "pcmFrames", "pcmAtMs",
        "rxStartedAtMs", "txDownAtMs", "gainDb", "gainSamples", "gainDecision", "recoveryLevel", "restoring",
        "trackSubscribed", "participants", "readyExpected", "readyReceived", "readyTimedOut", "clockDiscontinuity", "reason"]
    private let root: URL
    private let platform: String
    private let build: String
    private let installationId: String
    private let maxBytes: Int
    private let segmentBytes: Int
    private let retentionMs: Int64
    private let runId = UUID().uuidString
    private var sequence: Int64 = 0
    private var segment = 0
    private var current: URL?
    private var lastSweep: Int64?
    private var lastWall: Int64?
    private var lastMono: Int64?
    private var capacityDropped = 0
    private var corruptDropped = 0
    private var ioFailures = 0
    init(root: URL, platform: String = "ios", build: String, installationId: String,
         maxBytes: Int = 32 * 1024 * 1024, segmentBytes: Int = 256 * 1024, retentionMs: Int64 = 86_400_000) throws {
        self.root = root; self.platform = platform; self.build = build; self.installationId = installationId
        self.maxBytes = maxBytes; self.segmentBytes = segmentBytes; self.retentionMs = retentionMs
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        if let data = try? Data(contentsOf: root.appendingPathComponent("retention.json")),
           let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            capacityDropped = stats["capacityDroppedRecords"] ?? 0
            corruptDropped = stats["corruptDroppedRecords"] ?? 0
        }
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func safeFields(_ fields: [String: Any]) -> [String: Any] {
        fields.filter { key, value in
            guard keys.contains(key) else { return false }
            if let string = value as? String { return string.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil }
            if let number = value as? NSNumber { return number.doubleValue.isFinite }
            return false
        }
    }
    func append(event: String, fields: [String: Any], ids: [String: String], wallMs: Int64, monoMs: Int64, droppedBefore: Int = 0) {
        guard event.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil else { return }
        sequence += 1
        let discontinuity = lastWall.map { abs((wallMs - $0) - (monoMs - (lastMono ?? monoMs))) > 60_000 } ?? false
        lastWall = wallMs; lastMono = monoMs
        let correlation = ids.filter { ["sessionHash", "speakerSessionHash", "leaseHash", "channelHash"].contains($0.key) && !$0.value.isEmpty }.mapValues(Self.hash)
        let record: [String: Any] = ["schema": "koeon.field-journal.v1", "platform": platform, "build": String(build.prefix(64)),
            "installationId": installationId, "runId": runId, "sequence": sequence, "wallTimeMs": wallMs, "monotonicMs": monoMs,
            "event": event, "droppedBefore": droppedBefore, "ioFailuresBefore": ioFailures, "clockDiscontinuity": discontinuity,
            "correlation": correlation, "data": Self.safeFields(fields)]
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); data.append(0x0a)
            if lastSweep == nil || wallMs < lastSweep! || wallMs - lastSweep! >= 60_000 { try prune(now: wallMs) }
            if current == nil || !FileManager.default.fileExists(atPath: current!.path) || size(current!) + data.count > segmentBytes {
                segment += 1; current = root.appendingPathComponent("\(runId)-\(segment).jsonl")
                try Data().write(to: current!, options: [.completeFileProtectionUntilFirstUserAuthentication])
            }
            let handle = try FileHandle(forWritingTo: current!); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            try enforceCapacity()
        } catch { ioFailures += 1 }
    }
    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
    }
    private func size(_ file: URL) -> Int { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    private func rows(_ file: URL) throws -> (rows: [[String: Any]], corrupt: Int) {
        let lines = try Data(contentsOf: file).split(separator: 0x0a)
        let valid = lines.compactMap { data -> [String: Any]? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any],
                  row["schema"] as? String == "koeon.field-journal.v1", row["wallTimeMs"] is NSNumber else { return nil }
            return row
        }
        return (valid, lines.count - valid.count)
    }
    private func persistStats() throws {
        try JSONSerialization.data(withJSONObject: ["capacityDroppedRecords": capacityDropped, "corruptDroppedRecords": corruptDropped])
            .write(to: root.appendingPathComponent("retention.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func prune(now: Int64) throws {
        for file in try files() {
            let result = try rows(file); corruptDropped += result.corrupt
            let kept = result.rows.filter { ($0["wallTimeMs"] as! NSNumber).int64Value >= now - retentionMs }
            if kept.isEmpty { try FileManager.default.removeItem(at: file) }
            else if kept.count != result.rows.count || result.corrupt > 0 {
                var data = Data()
                for row in kept { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(0x0a) }
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        lastSweep = now; try persistStats(); try enforceCapacity()
    }
    private func enforceCapacity() throws {
        let list = try files(); var bytes = list.reduce(0) { $0 + size($1) }
        for file in list where bytes > maxBytes {
            let length = size(file); capacityDropped += try rows(file).rows.count
            try FileManager.default.removeItem(at: file); bytes -= length; try persistStats()
        }
    }
    func export(to destination: URL, now: Int64) throws -> URL {
        try prune(now: now); let inputs = try files()
        func included(_ row: [String: Any]) -> Bool {
            let time = (row["wallTimeMs"] as! NSNumber).int64Value
            return time >= now - retentionMs && time <= now
        }
        var count = 0; var future = 0
        for file in inputs {
            let records = try rows(file).rows
            count += records.filter(included).count
            future += records.filter { ($0["wallTimeMs"] as! NSNumber).int64Value > now }.count
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("tmp")
        try Data().write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
        let out = try FileHandle(forWritingTo: temporary); defer { try? out.close() }
        let manifest: [String: Any] = ["exportedAtMs": now, "cutoffMs": now - retentionMs, "recordCount": count,
            "capacityDroppedRecordsLifetime": capacityDropped, "corruptDroppedRecordsLifetime": corruptDropped,
            "futureClockRecordsExcluded": future, "ioFailuresThisRun": ioFailures, "retentionMs": retentionMs, "maxBytes": maxBytes]
        try out.write(contentsOf: Data("{\"schema\":\"koeon.field-journal-export.v1\",\"manifest\":".utf8))
        try out.write(contentsOf: JSONSerialization.data(withJSONObject: manifest))
        try out.write(contentsOf: Data(",\"records\":[".utf8)); var first = true
        for file in inputs {
            for row in try rows(file).rows where included(row) {
                if !first { try out.write(contentsOf: Data(",\n".utf8)) }; first = false
                try out.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            }
        }
        try out.write(contentsOf: Data("]}".utf8)); try out.close()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return destination
    }
}

final class FieldJournalAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var pending = 0
    private var dropped = 0
    init(limit: Int = 256) { self.limit = limit }
    func admit() -> Bool { lock.withLock {
        guard pending < limit else { dropped += 1; return false }; pending += 1; return true
    } }
    func finish() { lock.withLock { precondition(pending > 0); pending -= 1 } }
    func takeDropped() -> Int { lock.withLock { let value = dropped; dropped = 0; return value } }
}

final class FieldJournal: @unchecked Sendable {
    static let shared = FieldJournal()
    private let worker = DispatchQueue(label: "koeon.field-journal", qos: .utility)
    private let admission = FieldJournalAdmission()
    private var store: FieldJournalStore?
    private init() {
        // Initialization and all storage operations stay on the worker.
        worker.async { [self] in
            let defaults = UserDefaults.standard
            let installation = defaults.string(forKey: "field.journal.installation") ?? UUID().uuidString
            defaults.set(installation, forKey: "field.journal.installation")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                store = try? FieldJournalStore(root: root.appendingPathComponent("KOEONFieldJournal"), build: "\(version) (\(build))", installationId: installation)
            }
        }
    }
    func record(_ event: String, fields: [String: Any] = [:], ids: [String: String] = [:]) {
        let wall = Int64(Date().timeIntervalSince1970 * 1_000), mono = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        guard admission.admit() else { return }
        worker.async { [self] in
            let losses = admission.takeDropped()
            store?.append(event: event, fields: fields, ids: ids, wallMs: wall, monoMs: mono, droppedBefore: losses)
            admission.finish()
        }
    }
    func export() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do {
                    guard let store else { throw CocoaError(.fileWriteUnknown) }
                    let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let url = try store.export(to: base.appendingPathComponent("KOEONDiagnostics/field-journal-export.json"), now: Int64(Date().timeIntervalSince1970 * 1_000))
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
