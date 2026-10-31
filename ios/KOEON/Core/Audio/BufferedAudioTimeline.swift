import AVFoundation
import Foundation
import LiveKit

private let batv1BreadcrumbMaximumEvents = 64
let batv1ReleaseHangoverMilliseconds = 180
// Server publish schema permits 32 frames; never wait to fill a batch.
private let batv1MaximumPublishFrames = 32

struct Batv1CrashBreadcrumb: Codable, Equatable, Sendable {
    let timestamp: Date
    let platform: String
    let build: String
    let generationToken: String?
    let role: String
    let stage: String
    let actorClass: String
    let resultClass: String
}

final class Batv1CrashBreadcrumbStore: @unchecked Sendable {
    static let shared = Batv1CrashBreadcrumbStore()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let eventsKey = "batv1.crashBreadcrumbs.v1"
    private let runKnownKey = "batv1.runKnown"
    private let cleanExitKey = "batv1.cleanExit"
    private var events: [Batv1CrashBreadcrumb] = []
    private var build = "unknown"
    private(set) var previousRunTermination = "UNKNOWN"
    private var initialized = false

    func startRun(build: String) {
        lock.withLock {
            guard !initialized else { return }
            self.build = String(build.prefix(64))
            previousRunTermination = if !defaults.bool(forKey: runKnownKey) {
                "UNKNOWN"
            } else if defaults.bool(forKey: cleanExitKey) {
                "CLEAN"
            } else {
                "UNEXPECTED_TERMINATION_OR_KILL"
            }
            if let data = defaults.data(forKey: eventsKey),
               let saved = try? JSONDecoder().decode([Batv1CrashBreadcrumb].self, from: data) {
                events = Array(saved.suffix(batv1BreadcrumbMaximumEvents))
            }
            initialized = true
            defaults.set(true, forKey: runKnownKey)
            defaults.set(false, forKey: cleanExitKey)
        }
        record(role: "APP", stage: "APP_START")
    }

    func record(
        role: String,
        stage: String,
        generationId: String? = nil,
        actorClass: String = Thread.isMainThread ? "MAIN_ACTOR" : "BACKGROUND",
        resultClass: String = "OK"
    ) {
        lock.withLock {
            guard initialized else { return }
            events.append(Batv1CrashBreadcrumb(
                timestamp: Date(),
                platform: "ios",
                build: build,
                generationToken: generationId.map { String($0.prefix(8)) },
                role: String(role.prefix(8)),
                stage: String(stage.prefix(64)),
                actorClass: String(actorClass.prefix(32)),
                resultClass: String(resultClass.prefix(64))
            ))
            if events.count > batv1BreadcrumbMaximumEvents {
                events.removeFirst(events.count - batv1BreadcrumbMaximumEvents)
            }
            if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: eventsKey) }
            defaults.set(false, forKey: cleanExitKey)
        }
    }

    func markCleanExit() {
        record(role: "APP", stage: "APP_CLEAN_EXIT")
        lock.withLock { defaults.set(true, forKey: cleanExitKey) }
    }

    func snapshot() -> [Batv1CrashBreadcrumb] { lock.withLock { events } }
}

enum Batv1LifecycleState: String, Sendable {
    case idle = "IDLE"
    case starting = "STARTING"
    case active = "ACTIVE"
    case finishing = "FINISHING"
    case stopped = "STOPPED"
    case failed = "FAILED"
}

func batv1PlaybackRate(backlogMilliseconds: Int) -> Float {
    switch backlogMilliseconds {
    case ...250: 1.00
    case ...750: 1.10
    case ...1_500: 1.20
    case ...3_000: 1.325
    default: 1.45
    }
}

struct BufferedAudioTxDiagnostics: Equatable, Sendable {
    var generationId: String?
    var captureSource = "LIVEKIT_START_LOCAL_RECORDING"
    var captureState = "IDLE"
    var captureArmed = false
    var captureConfirmed = false
    var captureArmedAt: Date?
    var firstPcmAt: Date?
    var captureConfirmedAt: Date?
    var captureConfirmMilliseconds: Int?
    var preRollBufferedFrames = 0
    var preFloorAudioNetworkEgressFrames = 0
    var canonicalFramesSent = 0
    var canonicalBytesSent = 0
    var canonicalLastSequence = -1
    var canonicalDroppedFrames = 0
    var lastErrorCode: String?
    var pttUpAt: Date?
    var hangoverStartedAt: Date?
    var hangoverCompletedAt: Date?
    var hangoverMilliseconds: Int?
    var framesAcceptedAfterPttUp = 0
    var lastAudioSequence = -1
    var finalMarkerSequence: Int?
    var finalMarkerAt: Date?
    var captureCallbackCount = 0
    var captureCallbackSampleRate: Int?
    var captureCallbackChannels: Int?
    var captureCallbackFrameCount: Int?
    var unsupportedFormatFrameCount = 0
    var normalizedFrameCount = 0
    var captureNormalizationResult = "NOT_REQUIRED"
}

struct BufferedAudioRxDiagnostics: Equatable, Sendable {
    var generationId: String?
    var graphWireFormat = "PCM16LE_48000_MONO"
    var graphPlaybackFormat = "FLOAT32_48000_MONO_STANDARD"
    var graphPrepared = false
    var graphLastErrorCode: String?
    var playbackCursor = 0
    var latestSequence = -1
    var backlogMilliseconds = 0
    var playbackRate: Float = 1
    var missingSequenceCount = 0
    var duplicateSequenceCount = 0
    var outOfOrderCount = 0
    var bufferHeadExpired = false
    var timelineLost = false
    var finalSequence: Int?
    var controlEndReceivedAt: Date?
    var finalSequenceObservedAt: Date?
    var cursorAtFinalObservation: Int?
    var finalFrameWrittenAt: Date?
    var playerDrainCompletedAt: Date?
    var endCueAt: Date?
    var missingFinalFallbackEligibleAt: Date?
    var missingFinalFallbackCompletedAt: Date?
    var missingFinalFallbackStableMilliseconds: Int?
    var terminalReason: String?
}

struct Batv1PlaybackOutputObservation: Equatable, Sendable {
    var sampledAt: Date
    var outputPortTypes: [String]
    var outputVolume: Double
    var sampleRate: Double
    var engineRunning: Bool
    var playerPlaying: Bool
}

struct Batv1PlaybackDiagnostics: Equatable, Sendable {
    var generationToken: Int?
    var lastEnqueueOutput: Batv1PlaybackOutputObservation?
    var lastCompletionOutput: Batv1PlaybackOutputObservation?
    var configurationChanges = 0
    var recoveries = 0
    var ignoredCompletions = 0
    var lastErrorCode: String?
    var inputRmsDbfs: Double?
    var inputPeakDbfs: Double?
}

/// Realtime capture only copies post-processed PCM into bounded RAM.
/// It never performs network I/O and never writes audio to disk.
final class Batv1CaptureBuffer: @unchecked Sendable {
    private weak var inputGain: InputGainProcessor?
    init(inputGain: InputGainProcessor? = nil) { self.inputGain = inputGain }
    private let lock = NSLock()
    private var frames: [Data] = []
    private var partial = Data()
    private var generationId: String?
    private var forward: (@Sendable (Data) -> Void)?
    private var dropped = 0
    private var firstPcmAt: Date?
    private var callbackCount = 0
    private var callbackSampleRate: Int?
    private var callbackChannels: Int?
    private var callbackFrameCount: Int?
    private var unsupportedFormatFrames = 0
    private var normalizedFrames = 0
    private var frozen = false
    private var captureConverter: AVAudioConverter?
    private var converterSourceRate: Int?

    func arm(generationId: String) {
        lock.withLock {
            if self.generationId != nil { inputGain?.endTransmission(learn: false) }
            inputGain?.beginTransmission()
            frames.removeAll(keepingCapacity: true)
            partial.removeAll(keepingCapacity: true)
            self.generationId = generationId
            forward = nil
            dropped = 0
            firstPcmAt = nil
            callbackCount = 0
            callbackSampleRate = nil
            callbackChannels = nil
            callbackFrameCount = nil
            unsupportedFormatFrames = 0
            normalizedFrames = 0
            frozen = false
            captureConverter = nil
            converterSourceRate = nil
        }
    }

    /// Defines seq0 immediately before the user-visible start cue.
    func markCueBoundary() {
        lock.withLock {
            inputGain?.markCaptureBoundary()
            captureConverter?.reset()
            frames.removeAll(keepingCapacity: true)
            partial.removeAll(keepingCapacity: true)
            dropped = 0
        }
    }

    func append(samples: [Int16], sampleRate: Int, channels: Int) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard generationId != nil, !frozen else { return }
            callbackCount += 1
            callbackSampleRate = sampleRate
            callbackChannels = channels
            callbackFrameCount = samples.count
            guard channels == batv1Channels,
                  [8_000, 16_000, 24_000, 32_000, 44_100, 48_000].contains(sampleRate),
                  let bytes = canonicalPCM(samples: samples, sampleRate: sampleRate) else {
                unsupportedFormatFrames += samples.count
                captureConverter = nil
                converterSourceRate = nil
                return
            }
            guard !bytes.isEmpty else { return }
            if firstPcmAt == nil { firstPcmAt = Date() }
            partial.append(bytes)
            while partial.count >= batv1BytesPerFrame {
                let frame = Data(partial.prefix(batv1BytesPerFrame))
                partial.removeFirst(batv1BytesPerFrame)
                if frames.count == batv1MaximumFrames {
                    frames.removeFirst()
                    dropped += 1
                }
                frames.append(frame)
                forward?(frame)
            }
        }
    }

    /// Called under the capture lock. Keep converter history between callbacks,
    /// but reset it at a new capture/cue boundary so old speech cannot leak.
    private func canonicalPCM(samples: [Int16], sampleRate: Int) -> Data? {
        if sampleRate == batv1SampleRate {
            captureConverter = nil
            converterSourceRate = nil
            return samples.withUnsafeBytes { Data($0) }
        }
        if converterSourceRate != sampleRate {
            guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16,
                    sampleRate: Double(sampleRate), channels: 1, interleaved: true),
                  let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
                    sampleRate: Double(batv1SampleRate), channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: input, to: output) else { return nil }
            converter.primeMethod = .none
            captureConverter = converter
            converterSourceRate = sampleRate
        }
        guard let converter = captureConverter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) *
                        Double(batv1SampleRate) / Double(sampleRate))) + 64),
              let inputSamples = input.int16ChannelData?[0] else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            inputSamples.update(from: source.baseAddress!, count: source.count)
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
              let outputSamples = output.int16ChannelData?[0] else { return nil }
        normalizedFrames += Int(output.frameLength)
        return Data(bytes: outputSamples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    func awaitCapture(timeoutMilliseconds: Int = 750) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            if frameCount > 0 { return true }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return !Task.isCancelled && frameCount > 0
    }

    /// Seeds the consumer and installs forwarding while holding the same lock,
    /// so a live frame cannot overtake the pre-roll snapshot.
    func startForwarding(_ consumer: @escaping @Sendable (Data) -> Void) -> Int {
        lock.withLock {
            let count = frames.count
            frames.forEach(consumer)
            forward = frozen ? nil : consumer
            return count
        }
    }

    func stopForwarding() { lock.withLock { forward = nil; inputGain?.pauseCaptureMeasurements() } }

    func freeze(generationId: String) -> Bool {
        lock.withLock {
            guard self.generationId == generationId else { return false }
            guard !frozen else { return true }
            if !partial.isEmpty {
                partial.append(Data(count: batv1BytesPerFrame - partial.count))
                if frames.count == batv1MaximumFrames { frames.removeFirst(); dropped += 1 }
                frames.append(partial)
                partial = Data()
            }
            frozen = true
            inputGain?.pauseCaptureMeasurements()
            forward = nil
            return true
        }
    }

    func discard(learnFromCapture: Bool = false) {
        lock.withLock {
            if generationId != nil { inputGain?.endTransmission(learn: learnFromCapture) }
            generationId = nil
            captureConverter = nil
            converterSourceRate = nil
            forward = nil
            frames.removeAll(keepingCapacity: false)
            partial.removeAll(keepingCapacity: false)
        }
    }

    var frameCount: Int { lock.withLock { frames.count } }
    var droppedFrames: Int { lock.withLock { dropped } }
    var firstPcmTimestamp: Date? { lock.withLock { firstPcmAt } }
    var callbackDiagnostics: (count: Int, sampleRate: Int?, channels: Int?, frames: Int?, unsupported: Int, normalized: Int) {
        lock.withLock {
            (callbackCount, callbackSampleRate, callbackChannels, callbackFrameCount, unsupportedFormatFrames, normalizedFrames)
        }
    }
}

@MainActor
protocol Batv1LocalRecordingAuthority: AnyObject {
    func start() throws
    func stop() throws
    var isRecording: Bool { get }
}

@MainActor
final class LiveKitBatv1LocalRecordingAuthority: Batv1LocalRecordingAuthority {
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        try AudioManager.shared.startLocalRecording(
            audioProcessingOptions: AudioProcessingOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: true
            )
        )
        isRecording = true
    }

    func stop() throws {
        guard isRecording else { return }
        defer { isRecording = false }
        try AudioManager.shared.stopLocalRecording()
    }
}

private final class Batv1PendingFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var appendedCount = 0

    func append(_ frame: Data) { lock.withLock { frames.append(frame); appendedCount += 1 } }
    func take(maximum: Int) -> [Data] {
        lock.withLock {
            let count = min(maximum, frames.count)
            guard count > 0 else { return [] }
            let result = Array(frames.prefix(count))
            frames.removeFirst(count)
            return result
        }
    }
    var isEmpty: Bool { lock.withLock { frames.isEmpty } }
    var totalAppended: Int { lock.withLock { appendedCount } }
    func removeAll() { lock.withLock { frames.removeAll(keepingCapacity: false); appendedCount = 0 } }
}

@MainActor
protocol BufferedAudioTransmitting: AnyObject {
    func prepare(generationId: String) async
    func audioSessionDidActivate() async throws
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool
    func authorize(leaseId: String, generationId: String) async throws
    func freezePendingCapture(generationId: String) throws -> Bool
    func performReleaseHangover(generationId: String) async -> Bool
    func finish(generationId: String) async throws
    func discard(generationId: String) async
    var diagnostics: BufferedAudioTxDiagnostics { get }
}

extension BufferedAudioTransmitting {
    func freezePendingCapture(generationId: String) throws -> Bool { false }
}

@MainActor
final class BufferedAudioTransmitter: BufferedAudioTransmitting {
    private let api: any KOEONAPIClientProtocol
    private let capture: Batv1CaptureBuffer
    private let channelId: String
    private let sessionId: String
    private let deviceId: String
    private let recordingAuthority: any Batv1LocalRecordingAuthority
    private let onFailure: @MainActor (String) -> Void
    private let pending = Batv1PendingFrames()
    private var generationId: String?
    private var leaseId: String?
    private var nextSequence = 0
    private var authorized = false
    private var sendTask: Task<Void, Never>?
    private var sendError: Error?
    private var lifecycleState: Batv1LifecycleState = .idle
    private var lifecycleToken = 0
    private var releaseHangoverStartAppendCount = 0
    private(set) var diagnostics = BufferedAudioTxDiagnostics()

    init(
        api: any KOEONAPIClientProtocol,
        capture: Batv1CaptureBuffer,
        channelId: String,
        sessionId: String,
        deviceId: String,
        recordingAuthority: (any Batv1LocalRecordingAuthority)? = nil,
        onFailure: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.api = api
        self.capture = capture
        self.channelId = channelId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.recordingAuthority = recordingAuthority ?? LiveKitBatv1LocalRecordingAuthority()
        self.onFailure = onFailure
    }

    func prepare(generationId: String) async {
        await discard(generationId: self.generationId ?? "")
        lifecycleToken += 1
        self.generationId = generationId
        lifecycleState = .starting
        diagnostics = BufferedAudioTxDiagnostics(generationId: generationId)
        diagnostics.captureState = lifecycleState.rawValue
        Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_PREPARE", generationId: generationId)
    }

    func audioSessionDidActivate() async throws {
        guard let generationId, !diagnostics.captureArmed else { return }
        guard lifecycleState == .starting else { throw BufferedAudioError.illegalLifecycle }
        capture.arm(generationId: generationId)
        diagnostics.captureState = "ARMED"
        diagnostics.captureArmed = true
        diagnostics.captureArmedAt = Date()
        do {
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_START", generationId: generationId)
            try recordingAuthority.start()
            lifecycleState = .active
            diagnostics.captureState = "RECORDING"
        } catch {
            lifecycleState = .failed
            diagnostics.captureState = "ERROR"
            diagnostics.lastErrorCode = "BATV1_LOCAL_RECORDING_START_FAILED"
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_START_FAILED", generationId: generationId, resultClass: String(describing: type(of: error)))
            throw error
        }
    }

    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool {
        guard self.generationId == generationId, diagnostics.captureArmed,
              lifecycleState == .active, !Task.isCancelled else { return false }
        let token = lifecycleToken
        let confirmed = await capture.awaitCapture()
        // The shared capture buffer may already belong to the next PTT after this await.
        // A stale completion must neither rewrite diagnostics nor clear its pre-roll.
        guard self.generationId == generationId, lifecycleToken == token,
              lifecycleState == .active, !Task.isCancelled else { return false }
        diagnostics.captureConfirmed = confirmed
        diagnostics.firstPcmAt = capture.firstPcmTimestamp
        diagnostics.captureConfirmedAt = confirmed ? Date() : nil
        if let armed = diagnostics.captureArmedAt, let confirmedAt = diagnostics.captureConfirmedAt {
            diagnostics.captureConfirmMilliseconds = max(0, Int(confirmedAt.timeIntervalSince(armed) * 1_000))
        }
        diagnostics.captureState = confirmed ? "ACTIVE" : "ERROR"
        let callback = capture.callbackDiagnostics
        diagnostics.captureCallbackCount = callback.count
        diagnostics.captureCallbackSampleRate = callback.sampleRate
        diagnostics.captureCallbackChannels = callback.channels
        diagnostics.captureCallbackFrameCount = callback.frames
        diagnostics.unsupportedFormatFrameCount = callback.unsupported
        diagnostics.normalizedFrameCount = callback.normalized
        diagnostics.captureNormalizationResult = callback.normalized > 0 ? "NORMALIZED_TO_PCM16LE_48000_MONO" : "NOT_REQUIRED"
        guard confirmed else {
            diagnostics.lastErrorCode = "BATV1_CAPTURE_ZERO_FRAMES"
            return false
        }
        capture.markCueBoundary()
        Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_CONFIRMED", generationId: generationId)
        return true
    }

    func authorize(leaseId: String, generationId: String) async throws {
        guard self.generationId == generationId, diagnostics.captureConfirmed else {
            throw BufferedAudioError.captureNotConfirmed
        }
        self.leaseId = leaseId
        authorized = true
        lifecycleState = .active
        let token = lifecycleToken
        let seeded = capture.startForwarding { [pending] frame in pending.append(frame) }
        diagnostics.preRollBufferedFrames = seeded
        Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_AUTHORIZED", generationId: generationId)
        sendTask = Task { @MainActor [weak self] in await self?.sendLoop(token: token, generationId: generationId) }
    }

    func freezePendingCapture(generationId: String) throws -> Bool {
        guard self.generationId == generationId, !authorized, diagnostics.captureConfirmed,
              lifecycleState == .active, capture.freeze(generationId: generationId) else { return false }
        do {
            // Stop local recording while preserving captured PCM. Publication
            // of these bytes does not require Apple's audio session to stay on.
            try recordingAuthority.stop()
        } catch {
            lifecycleState = .failed
            diagnostics.lastErrorCode = "BATV1_LOCAL_RECORDING_STOP_FAILED"
            throw error
        }
        diagnostics.captureState = "FROZEN_WAITING_READY"
        diagnostics.pttUpAt = Date()
        Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_FROZEN", generationId: generationId)
        return true
    }

    func performReleaseHangover(generationId: String) async -> Bool {
        guard self.generationId == generationId, authorized, lifecycleState == .active else { return false }
        let token = lifecycleToken
        let startedAt = Date()
        releaseHangoverStartAppendCount = pending.totalAppended
        diagnostics.pttUpAt = startedAt
        diagnostics.hangoverStartedAt = startedAt
        diagnostics.hangoverCompletedAt = nil
        diagnostics.hangoverMilliseconds = nil
        diagnostics.framesAcceptedAfterPttUp = 0
        do { try await Task.sleep(for: .milliseconds(batv1ReleaseHangoverMilliseconds)) }
        catch { return false }
        guard token == lifecycleToken,
              self.generationId == generationId,
              authorized,
              lifecycleState == .active else { return false }
        let completedAt = Date()
        diagnostics.hangoverCompletedAt = completedAt
        diagnostics.hangoverMilliseconds = max(0, Int(completedAt.timeIntervalSince(startedAt) * 1_000))
        diagnostics.framesAcceptedAfterPttUp = max(0, pending.totalAppended - releaseHangoverStartAppendCount)
        return true
    }

    func finish(generationId: String) async throws {
        guard self.generationId == generationId, authorized, lifecycleState == .active else {
            throw BufferedAudioError.generationMismatch
        }
        lifecycleState = .finishing
        diagnostics.captureState = lifecycleState.rawValue
        let token = lifecycleToken
        Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_FINISH_BEGIN", generationId: generationId)
        capture.stopForwarding()
        authorized = false
        await sendTask?.value
        guard token == lifecycleToken, self.generationId == generationId else { throw BufferedAudioError.generationMismatch }
        if let sendError {
            await cleanup(generationId: generationId, state: .failed)
            throw sendError
        }
        let finalSequence = nextSequence - 1
        guard finalSequence >= 0, let leaseId else {
            await cleanup(generationId: generationId, state: .failed)
            throw BufferedAudioError.emptyGeneration
        }
        do {
            var lastFailure: Error?
            for attempt in 1...2 {
                do {
                    Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_FINAL_MARKER_BEGIN", generationId: generationId)
                    _ = try await api.publishBufferedAudio(request(
                        leaseId: leaseId,
                        generationId: generationId,
                        frames: [],
                        firstSequence: nextSequence,
                        finalSequence: finalSequence
                    ))
                    lastFailure = nil
                    break
                } catch {
                    lastFailure = error
                    guard attempt == 1, !Task.isCancelled else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if let lastFailure { throw lastFailure }
            diagnostics.finalMarkerSequence = finalSequence
            diagnostics.finalMarkerAt = Date()
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_FINAL_MARKER_END", generationId: generationId)
            await cleanup(generationId: generationId, state: .stopped, learnFromCapture: true)
        } catch {
            diagnostics.lastErrorCode = "BATV1_FINAL_MARKER_FAILED"
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_FINAL_MARKER_FAILED", generationId: generationId, resultClass: String(describing: type(of: error)))
            await cleanup(generationId: generationId, state: .failed)
            onFailure("BATV1_FINAL_MARKER_FAILED")
            throw error
        }
    }

    func discard(generationId: String) async {
        guard generationId.isEmpty || self.generationId == generationId else { return }
        let activeGeneration = self.generationId
        lifecycleToken += 1
        lifecycleState = .finishing
        authorized = false
        capture.stopForwarding()
        sendTask?.cancel()
        await sendTask?.value
        await cleanup(generationId: activeGeneration, state: .stopped)
    }

    private func stopLocalRecording(generationId: String?) {
        guard recordingAuthority.isRecording else { return }
        Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_STOP_BEGIN", generationId: generationId)
        do {
            try recordingAuthority.stop()
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_STOP_END", generationId: generationId)
        } catch {
            lifecycleState = .failed
            diagnostics.lastErrorCode = "BATV1_LOCAL_RECORDING_STOP_FAILED"
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_CAPTURE_STOP_FAILED", generationId: generationId, resultClass: String(describing: type(of: error)))
            onFailure("BATV1_LOCAL_RECORDING_STOP_FAILED")
        }
    }

    private func sendLoop(token: Int, generationId: String) async {
        guard token == lifecycleToken, self.generationId == generationId, let leaseId else { return }
        while !Task.isCancelled {
            let batch = pending.take(maximum: batv1MaximumPublishFrames)
            if batch.isEmpty {
                if !authorized { break }
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            do {
                Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_BATCH_BEGIN", generationId: generationId)
                _ = try await api.publishBufferedAudio(request(
                    leaseId: leaseId,
                    generationId: generationId,
                    frames: batch,
                    firstSequence: nextSequence,
                    finalSequence: nil
                ))
                guard token == lifecycleToken, self.generationId == generationId else { return }
                nextSequence += batch.count
                diagnostics.canonicalFramesSent = nextSequence
                diagnostics.canonicalBytesSent = nextSequence * batv1BytesPerFrame
                diagnostics.canonicalLastSequence = nextSequence - 1
                diagnostics.lastAudioSequence = nextSequence - 1
                diagnostics.canonicalDroppedFrames = capture.droppedFrames
                Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_BATCH_END", generationId: generationId)
            } catch {
                guard !Task.isCancelled, token == lifecycleToken, self.generationId == generationId else { return }
                sendError = error
                diagnostics.lastErrorCode = "BATV1_PUBLISH_FAILED"
                lifecycleState = .failed
                authorized = false
                capture.stopForwarding()
                Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_BATCH_FAILED", generationId: generationId, resultClass: String(describing: type(of: error)))
                onFailure("BATV1_PUBLISH_FAILED")
                break
            }
        }
    }

    private func cleanup(generationId: String?, state: Batv1LifecycleState, learnFromCapture: Bool = false) async {
        capture.stopForwarding()
        stopLocalRecording(generationId: generationId)
        capture.discard(learnFromCapture: learnFromCapture)
        pending.removeAll()
        sendTask = nil
        authorized = false
        self.generationId = nil
        leaseId = nil
        nextSequence = 0
        sendError = nil
        lifecycleState = state
        diagnostics.captureState = state.rawValue
    }

    private func request(
        leaseId: String,
        generationId: String,
        frames: [Data],
        firstSequence: Int,
        finalSequence: Int?
    ) -> Batv1PublishRequest {
        Batv1PublishRequest(
            protocolVersion: batv1ProtocolVersion,
            sessionId: sessionId,
            generationId: generationId,
            channelId: channelId,
            speakerSessionId: sessionId,
            speakerDeviceId: deviceId,
            leaseId: leaseId,
            codec: "pcm16le",
            sampleRate: batv1SampleRate,
            channels: batv1Channels,
            frameDurationMs: batv1FrameDurationMilliseconds,
            chunks: frames.enumerated().map {
                Batv1Chunk(sequence: firstSequence + $0.offset, payloadBase64: $0.element.base64EncodedString())
            },
            finalSequence: finalSequence
        )
    }
}

enum BufferedAudioError: Error {
    case captureNotConfirmed
    case generationMismatch
    case emptyGeneration
    case invalidWireFormat
    case sequenceGap
    case timelineHeadExpired
    case illegalLifecycle
    case invalidAudioGraphFormat
    case playbackEngineUnavailable
    case playbackBacklogExceeded
}

func makeBatv1PlaybackGraphFormat() -> AVAudioFormat? {
    AVAudioFormat(
        standardFormatWithSampleRate: Double(batv1SampleRate),
        channels: AVAudioChannelCount(batv1Channels)
    )
}

func isValidBatv1PlaybackGraphFormat(_ format: AVAudioFormat) -> Bool {
    format.sampleRate == Double(batv1SampleRate)
        && format.channelCount == AVAudioChannelCount(batv1Channels)
        && format.commonFormat == .pcmFormatFloat32
        && !format.isInterleaved
        && format.isStandard
}

enum Batv1Pcm16LEConverter {
    static let samplesPerFrame = batv1SampleRate * batv1FrameDurationMilliseconds / 1_000

    static func floatSamples(from data: Data) throws -> [Float] {
        guard data.count == batv1BytesPerFrame else {
            throw BufferedAudioError.invalidWireFormat
        }
        return data.withUnsafeBytes { bytes in
            (0..<samplesPerFrame).map { index in
                let byteOffset = index * MemoryLayout<Int16>.size
                let bits = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                return Float(Int16(bitPattern: bits)) / 32_768
            }
        }
    }

    static func playbackBuffer(from data: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard isValidBatv1PlaybackGraphFormat(format),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samplesPerFrame)
              ),
              let destination = buffer.floatChannelData?[0] else {
            throw BufferedAudioError.invalidAudioGraphFormat
        }
        let samples = try floatSamples(from: data)
        guard samples.count == samplesPerFrame else {
            throw BufferedAudioError.invalidWireFormat
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            destination[index] = samples[index]
        }
        return buffer
    }
}

@MainActor
protocol IOSBatv1PcmPlaying: AnyObject {
    var playbackDiagnostics: Batv1PlaybackDiagnostics { get }
    var pendingFrames: Int { get }
    var completedFrames: Int { get }
    func beginGeneration(token: Int) throws
    func setRate(_ rate: Float)
    func enqueue(_ data: Data, generationToken: Int) throws
    func drain(generationToken: Int) async throws
    func endGeneration(token: Int)
    func resumeIfNeeded() throws
    func audioSessionDidDeactivate()
    func checkPlaybackHealth() throws
    func shutdown()
}

extension IOSBatv1PcmPlaying {
    var playbackDiagnostics: Batv1PlaybackDiagnostics { Batv1PlaybackDiagnostics() }
    func audioSessionDidDeactivate() {}
    func checkPlaybackHealth() throws {}
}

/// Invalidated synchronously on the framework notification queue, before any
/// MainActor work. Late callbacks from an unscheduled queue cannot consume PCM.
final class Batv1PlaybackCallbackEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    func invalidate() -> Int { lock.withLock { revision += 1; return revision } }
    func accepts(_ value: Int) -> Bool { lock.withLock { revision == value } }
}

@MainActor
final class Batv1GenerationCompletionFence {
    private(set) var activeToken: Int?
    func begin(_ token: Int) { activeToken = token }
    func accepts(_ token: Int) -> Bool { activeToken == token }
    func end(_ token: Int) { if activeToken == token { activeToken = nil } }
}

@MainActor
final class IOSBatv1PcmPlayer: IOSBatv1PcmPlaying {
    private let engine: AVAudioEngine
    private let startEngine: @MainActor (AVAudioEngine) throws -> Void
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    let playbackGraphFormat: AVAudioFormat?
    private(set) var graphPrepared = false
    private(set) var graphPreparationCount = 0
    private let completionFence = Batv1GenerationCompletionFence()
    private let callbackEpoch = Batv1PlaybackCallbackEpoch()
    private var configurationObserver: NSObjectProtocol?
    private var queued: [(id: Int, buffer: AVAudioPCMBuffer)] = []
    private var nextFrameId = 0
    private var playbackPermitted = false
    private var needsReschedule = false
    private var recoveryTask: Task<Void, Never>?
    private var playbackFailure: Error?
    private(set) var configurationChangeCount = 0
    private(set) var recoveryCount = 0
    private(set) var ignoredCompletionCount = 0
    var pendingFrames: Int { queued.count }
    private(set) var completedFrames = 0
    private(set) var playbackDiagnostics = Batv1PlaybackDiagnostics()
    private var inputSumSquares: Double = 0
    private var inputSampleCount = 0
    private var inputPeak: Double = 0

    init(
        playbackGraphFormat: AVAudioFormat? = makeBatv1PlaybackGraphFormat(),
        engine: AVAudioEngine = AVAudioEngine(),
        startEngine: @escaping @MainActor (AVAudioEngine) throws -> Void = { try $0.start() }
    ) {
        self.playbackGraphFormat = playbackGraphFormat
        self.engine = engine
        self.startEngine = startEngine
        let epoch = callbackEpoch
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            let revision = epoch.invalidate()
            Task { @MainActor [weak self] in self?.configurationDidChange(revision: revision) }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        recoveryTask?.cancel()
    }

    func beginGeneration(token: Int) throws {
        try beginGeneration(token: token, startEngine: true)
    }

    func prepareGraphIfNeeded() throws {
        guard !graphPrepared else { return }
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_FORMAT_VALIDATE")
        guard let playbackGraphFormat,
              isValidBatv1PlaybackGraphFormat(playbackGraphFormat) else {
            Batv1CrashBreadcrumbStore.shared.record(
                role: "RX", stage: "RX_GRAPH_FORMAT_INVALID", resultClass: "RX_AUDIO_GRAPH_FORMAT_INVALID"
            )
            throw BufferedAudioError.invalidAudioGraphFormat
        }
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_ATTACH_BEGIN")
        engine.attach(player)
        engine.attach(timePitch)
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_ATTACH_END")
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_CONNECT_PLAYER_TIMEPITCH_BEGIN")
        engine.connect(player, to: timePitch, format: playbackGraphFormat)
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_CONNECT_PLAYER_TIMEPITCH_END")
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_CONNECT_MIXER_BEGIN")
        engine.connect(timePitch, to: engine.mainMixerNode, format: playbackGraphFormat)
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_CONNECT_MIXER_END")
        engine.prepare()
        graphPrepared = true
        graphPreparationCount += 1
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_GRAPH_PREPARE_END")
    }

    func beginGeneration(token: Int, startEngine: Bool) throws {
        recoveryTask?.cancel()
        activeScheduleRevision = callbackEpoch.invalidate()
        playbackPermitted = startEngine
        needsReschedule = false
        playbackFailure = nil
        configurationChangeCount = 0
        recoveryCount = 0
        ignoredCompletionCount = 0
        playbackDiagnostics = Batv1PlaybackDiagnostics(generationToken: token)
        inputSumSquares = 0
        inputSampleCount = 0
        inputPeak = 0
        queued.removeAll()
        completionFence.begin(token)
        try prepareGraphIfNeeded()
        if startEngine, !engine.isRunning { try self.startEngine(engine) }
        player.stop()
        player.reset()
        completedFrames = 0
        setRate(1)
        if startEngine { player.play() }
    }

    func setRate(_ rate: Float) {
        timePitch.rate = min(batv1MaximumPlaybackRate, max(1, rate))
        timePitch.pitch = 0
    }

    func enqueue(_ data: Data, generationToken: Int) throws {
        guard completionFence.accepts(generationToken),
              let playbackGraphFormat else {
            throw BufferedAudioError.invalidWireFormat
        }
        if let playbackFailure { throw playbackFailure }
        guard queued.count < batv1MaximumFrames else {
            playbackDiagnostics.lastErrorCode = "RX_PLAYBACK_BACKLOG_EXCEEDED"
            throw BufferedAudioError.playbackBacklogExceeded
        }
        let buffer = try Batv1Pcm16LEConverter.playbackBuffer(from: data, format: playbackGraphFormat)
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                let value = Double(samples[index])
                inputSumSquares += value * value
                inputPeak = max(inputPeak, abs(value))
            }
            inputSampleCount += Int(buffer.frameLength)
            playbackDiagnostics.inputRmsDbfs = 20 * log10(max(0.000_001, sqrt(inputSumSquares / Double(inputSampleCount))))
            playbackDiagnostics.inputPeakDbfs = 20 * log10(max(0.000_001, inputPeak))
        }
        playbackDiagnostics.lastEnqueueOutput = outputObservation()
        nextFrameId += 1
        let frame = (id: nextFrameId, buffer: buffer)
        queued.append(frame)
        if !needsReschedule { schedule(frame, generationToken: generationToken, revision: activeScheduleRevision) }
    }

    private var activeScheduleRevision = 0

    private func schedule(_ frame: (id: Int, buffer: AVAudioPCMBuffer), generationToken: Int, revision: Int) {
        let epoch = callbackEpoch
        let frameId = frame.id
        player.scheduleBuffer(frame.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Never query AVAudioEngine here: stop() drains this callback queue
            // while holding the engine lock. Only our own small fence is read.
            let currentAtCallback = epoch.accepts(revision)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.completionFence.accepts(generationToken) else { return }
                guard currentAtCallback, self.callbackEpoch.accepts(revision), self.playbackPermitted,
                      self.engine.isRunning, self.player.isPlaying,
                      let index = self.queued.firstIndex(where: { $0.id == frameId }) else {
                    self.ignoredCompletionCount += 1
                    self.playbackDiagnostics.ignoredCompletions = self.ignoredCompletionCount
                    return
                }
                self.queued.remove(at: index)
                self.completedFrames += 1
                self.playbackDiagnostics.lastCompletionOutput = self.outputObservation()
            }
        }
    }

    func drain(generationToken: Int) async throws {
        while completionFence.accepts(generationToken), pendingFrames > 0, !Task.isCancelled {
            if let playbackFailure { throw playbackFailure }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                // A stopped engine may never deliver the queued callbacks.
                // Cancellation must release stopAndAwait / the next generation;
                // the receiver checks cancellation before declaring playback done.
                return
            }
        }
    }

    func checkPlaybackHealth() throws {
        if let playbackFailure { throw playbackFailure }
    }

    func endGeneration(token: Int) {
        guard completionFence.accepts(token) else { return }
        playbackPermitted = false
        recoveryTask?.cancel()
        _ = callbackEpoch.invalidate()
        completionFence.end(token)
        player.stop()
        player.reset()
        setRate(1)
        queued.removeAll()
        completedFrames = 0
    }

    func resumeIfNeeded() throws {
        guard completionFence.activeToken != nil else { return }
        playbackPermitted = true
        if needsReschedule || !engine.isRunning { requestRecovery() }
        else if !player.isPlaying { player.play() }
    }

    func audioSessionDidDeactivate() {
        playbackPermitted = false
        recoveryTask?.cancel()
        _ = callbackEpoch.invalidate()
        needsReschedule = true
        player.pause()
    }

    private func configurationDidChange(revision: Int) {
        guard callbackEpoch.accepts(revision), completionFence.activeToken != nil else { return }
        configurationChangeCount += 1
        playbackDiagnostics.configurationChanges = configurationChangeCount
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_ENGINE_CONFIGURATION_CHANGE")
        needsReschedule = true
        requestRecovery()
    }

    private func requestRecovery() {
        recoveryTask?.cancel()
        guard playbackPermitted, let token = completionFence.activeToken else { return }
        playbackFailure = nil
        recoveryTask = Task { @MainActor [weak self] in
            for attempt in 0..<6 {
                guard let self, !Task.isCancelled, self.playbackPermitted,
                      self.completionFence.accepts(token) else { return }
                do {
                    self.activeScheduleRevision = self.callbackEpoch.invalidate()
                    self.player.stop()
                    self.player.reset()
                    if !self.engine.isRunning { try self.startEngine(self.engine) }
                    guard self.engine.isRunning else { throw BufferedAudioError.playbackEngineUnavailable }
                    for frame in self.queued {
                        self.schedule(frame, generationToken: token, revision: self.activeScheduleRevision)
                    }
                    self.player.play()
                    self.needsReschedule = false
                    self.recoveryCount += 1
                    self.playbackDiagnostics.recoveries = self.recoveryCount
                    self.playbackDiagnostics.lastErrorCode = nil
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_ENGINE_RECOVERED")
                    return
                } catch {
                    if attempt == 5 {
                        self.playbackFailure = error
                        self.playbackDiagnostics.lastErrorCode = "RX_ENGINE_RECOVERY_FAILED"
                        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_ENGINE_RECOVERY_FAILED")
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func outputObservation() -> Batv1PlaybackOutputObservation {
        let session = AVAudioSession.sharedInstance()
        return Batv1PlaybackOutputObservation(
            sampledAt: Date(), outputPortTypes: session.currentRoute.outputs.map { $0.portType.rawValue },
            outputVolume: Double(session.outputVolume), sampleRate: session.sampleRate,
            engineRunning: engine.isRunning, playerPlaying: player.isPlaying
        )
    }

    func shutdown() {
        if let token = completionFence.activeToken { endGeneration(token: token) }
        guard graphPrepared else { return }
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.detach(player)
        engine.detach(timePitch)
        graphPrepared = false
    }
}

@MainActor
final class BufferedAudioReceiver {
    var playbackDiagnostics: Batv1PlaybackDiagnostics {
        let snapshot = player.playbackDiagnostics
        return snapshot.generationToken == generationToken ? snapshot : Batv1PlaybackDiagnostics()
    }
    private static let missingFinalStableGraceSeconds: TimeInterval = 0.75
    private static let floorStatusPollIntervalSeconds: TimeInterval = 0.25
    private let api: any KOEONAPIClientProtocol
    private let sessionId: String
    private let onActivity: (String?, Bool) -> Void
    private let onPcm: (Date) -> Void
    private let onTimelineDrained: @MainActor () async -> Void
    private let onFailure: (String) -> Void
    private let player: any IOSBatv1PcmPlaying
    private let monotonicNow: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var audioSessionActive = false
    private var isRetired = false
    private var generationToken = 0
    private var expectedLeaseId: String?
    private var senderUserId: String?
    private var controlEndUptime: TimeInterval?
    private var floorTerminalUptime: TimeInterval?
    private var lastFloorStatusPollUptime: TimeInterval?
    private var latestSequenceStableSinceUptime: TimeInterval?
    private var observedLatestSequence = -1
    private var activeSenderSessionId: String?
    private(set) var subscriptionActive = false
    private(set) var diagnostics = BufferedAudioRxDiagnostics()

    init(
        api: any KOEONAPIClientProtocol,
        sessionId: String,
        onActivity: @escaping (String?, Bool) -> Void = { _, _ in },
        onPcm: @escaping (Date) -> Void = { _ in },
        onTimelineDrained: @escaping @MainActor () async -> Void = {},
        onFailure: @escaping (String) -> Void = { _ in },
        player: (any IOSBatv1PcmPlaying)? = nil,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.api = api
        self.sessionId = sessionId
        self.onActivity = onActivity
        self.onPcm = onPcm
        self.onTimelineDrained = onTimelineDrained
        self.onFailure = onFailure
        self.player = player ?? IOSBatv1PcmPlayer()
        self.monotonicNow = monotonicNow
    }

    func start(generationId: String, senderSessionId: String?, leaseId: String? = nil, senderUserId: String? = nil) {
        guard !isRetired else { return }
        // Reliable/fast START duplicates must not rewind an already playing timeline.
        if diagnostics.generationId == generationId, activeSenderSessionId == senderSessionId,
           task != nil, !diagnostics.timelineLost { return }
        subscriptionActive = false
        let previous = task
        previous?.cancel()
        generationToken += 1
        let token = generationToken
        diagnostics = BufferedAudioRxDiagnostics(generationId: generationId)
        expectedLeaseId = leaseId
        self.senderUserId = senderUserId
        controlEndUptime = nil
        floorTerminalUptime = nil
        lastFloorStatusPollUptime = nil
        latestSequenceStableSinceUptime = nil
        observedLatestSequence = -1
        activeSenderSessionId = senderSessionId
        task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generationToken == token else { return }
            await self.receive(generationId: generationId, senderSessionId: senderSessionId, generationToken: token)
        }
    }

    func audioSessionDidActivate() {
        guard !isRetired else { return }
        audioSessionActive = true
        do { try player.resumeIfNeeded() } catch {
            diagnostics.timelineLost = true
            diagnostics.terminalReason = player.playbackDiagnostics.lastErrorCode ?? "receive_failed"
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_RESUME_FAILED", resultClass: String(describing: type(of: error)))
            onFailure("BATV1_RX_RESUME_FAILED")
        }
    }
    func audioSessionDidDeactivate() {
        audioSessionActive = false
        player.audioSessionDidDeactivate()
    }

    func noteControlEnd(at: Date = Date()) {
        guard diagnostics.generationId != nil || diagnostics.terminalReason != nil else { return }
        diagnostics.controlEndReceivedAt = at
        controlEndUptime = monotonicNow()
    }

    func noteEndCue(at: Date = Date()) {
        guard diagnostics.generationId != nil else { return }
        diagnostics.endCueAt = at
    }

    func stop() {
        subscriptionActive = false
        generationToken += 1
        task?.cancel()
        let stoppedSender = activeSenderSessionId
        activeSenderSessionId = nil
        diagnostics.generationId = nil
        if let stoppedSender { onActivity(stoppedSender, false) }
    }

    func stopAndAwait() async {
        subscriptionActive = false
        generationToken += 1
        let stoppingToken = generationToken
        let previous = task
        previous?.cancel()
        await previous?.value
        // start() can replace the receive task while its predecessor finishes.
        // A late stop owns only the generation it invalidated, not that replacement.
        guard generationToken == stoppingToken else { return }
        task = nil
        let stoppedSender = activeSenderSessionId
        activeSenderSessionId = nil
        diagnostics.generationId = nil
        if let stoppedSender { onActivity(stoppedSender, false) }
    }

    func awaitCurrentGenerationTermination() async { await task?.value }

    func shutdownAndAwait() async {
        // Runtime teardown is terminal for this receiver, unlike a receive stop.
        // Reject late START/activation callbacks before yielding to the old task.
        isRetired = true
        audioSessionActive = false
        await stopAndAwait()
        player.shutdown()
    }

    private func receive(generationId: String, senderSessionId: String?, generationToken: Int) async {
        while !audioSessionActive, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_START", generationId: generationId)
        var terminalDrainPublished = false
        do {
            diagnostics.graphWireFormat = "PCM16LE_48000_MONO"
            diagnostics.graphPlaybackFormat = "FLOAT32_48000_MONO_STANDARD"
            diagnostics.graphPrepared = false
            diagnostics.graphLastErrorCode = nil
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_PREPARE", generationId: generationId)
            try player.beginGeneration(token: generationToken)
            diagnostics.graphPrepared = true
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_START", generationId: generationId)
            onActivity(senderSessionId, true)
            var cursor = 0
            var lastSequence = -1
            while !Task.isCancelled {
                try player.checkPlaybackHealth()
                if !audioSessionActive {
                    try? await Task.sleep(for: .milliseconds(20))
                    continue
                }
                // Stop fetching while playback catches up. Merely sleeping after
                // each HTTP batch can still fill the RAM queue faster than audio.
                if player.pendingFrames > 75 {
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let response: Batv1SubscribeResponse
                do {
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: generationId)
                    subscriptionActive = true
                    response = try await api.subscribeBufferedAudio(
                        Batv1SubscribeRequest(sessionId: sessionId, generationId: generationId, nextSequence: cursor)
                    )
                    if self.generationToken != generationToken { break }
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_SUBSCRIBE_END", generationId: generationId)
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(40))
                    continue
                }
                guard response.protocolVersion == batv1ProtocolVersion,
                      response.generationId == generationId,
                      response.codec == "pcm16le",
                      response.sampleRate == batv1SampleRate,
                      response.channels == batv1Channels,
                      response.frameDurationMs == batv1FrameDurationMilliseconds else {
                    throw BufferedAudioError.invalidWireFormat
                }
                if response.bufferHeadExpired {
                    diagnostics.bufferHeadExpired = true
                    throw BufferedAudioError.timelineHeadExpired
                }
                let now = monotonicNow()
                if response.latestSequence != observedLatestSequence {
                    observedLatestSequence = response.latestSequence
                    latestSequenceStableSinceUptime = now
                } else if latestSequenceStableSinceUptime == nil {
                    latestSequenceStableSinceUptime = now
                }
                if let final = response.finalSequence, diagnostics.finalSequenceObservedAt == nil {
                    diagnostics.finalSequence = final
                    diagnostics.finalSequenceObservedAt = Date()
                    diagnostics.cursorAtFinalObservation = cursor
                }
                for chunk in response.chunks {
                    guard chunk.sequence == cursor else {
                        if chunk.sequence < cursor { diagnostics.duplicateSequenceCount += 1 }
                        if chunk.sequence > cursor { diagnostics.missingSequenceCount += chunk.sequence - cursor }
                        throw BufferedAudioError.sequenceGap
                    }
                    if chunk.sequence <= lastSequence { diagnostics.outOfOrderCount += 1 }
                    guard let data = Data(base64Encoded: chunk.payloadBase64), data.count == batv1BytesPerFrame else {
                        throw BufferedAudioError.invalidWireFormat
                    }
                    let backlog = max(0, response.latestSequence - (chunk.sequence - player.pendingFrames))
                        * batv1FrameDurationMilliseconds
                    let rate = batv1PlaybackRate(backlogMilliseconds: backlog)
                    player.setRate(rate)
                    try player.enqueue(data, generationToken: generationToken)
                    if response.finalSequence == chunk.sequence { diagnostics.finalFrameWrittenAt = Date() }
                    onPcm(Date())
                    lastSequence = chunk.sequence
                    cursor = chunk.sequence + 1
                    diagnostics.playbackCursor = player.completedFrames
                    diagnostics.latestSequence = response.latestSequence
                    diagnostics.backlogMilliseconds = backlog
                    diagnostics.playbackRate = rate
                    diagnostics.finalSequence = response.finalSequence
                }
                if response.timelineEnded, let final = response.finalSequence, cursor > final {
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_DRAIN_BEGIN", generationId: generationId)
                    try await player.drain(generationToken: generationToken)
                    guard !Task.isCancelled, self.generationToken == generationToken else { break }
                    diagnostics.playbackCursor = cursor
                    diagnostics.backlogMilliseconds = 0
                    diagnostics.playbackRate = 1
                    diagnostics.playerDrainCompletedAt = Date()
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_DRAIN_END", generationId: generationId)
                    onActivity(senderSessionId, false)
                    await onTimelineDrained()
                    terminalDrainPublished = true
                    guard self.generationToken == generationToken else { break }
                    diagnostics.endCueAt = Date()
                    diagnostics.terminalReason = "final_sequence"
                    break
                }
                if response.finalSequence == nil,
                   await missingFinalFallbackEligible(response: response, cursor: cursor, now: now) {
                    diagnostics.missingFinalFallbackEligibleAt = Date()
                    diagnostics.missingFinalFallbackStableMilliseconds = latestSequenceStableSinceUptime.map {
                        max(0, Int((now - $0) * 1_000))
                    }
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_MISSING_FINAL_DRAIN_BEGIN", generationId: generationId)
                    try await player.drain(generationToken: generationToken)
                    guard !Task.isCancelled, self.generationToken == generationToken else { break }
                    diagnostics.playbackCursor = cursor
                    diagnostics.backlogMilliseconds = 0
                    diagnostics.playbackRate = 1
                    diagnostics.playerDrainCompletedAt = Date()
                    diagnostics.missingFinalFallbackCompletedAt = Date()
                    diagnostics.terminalReason = "missing_final_floor_terminal_stable"
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_MISSING_FINAL_DRAIN_END", generationId: generationId)
                    onActivity(senderSessionId, false)
                    await onTimelineDrained()
                    terminalDrainPublished = true
                    guard self.generationToken == generationToken else { break }
                    diagnostics.endCueAt = Date()
                    break
                }
                if response.chunks.isEmpty || player.pendingFrames > 75 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            guard !Task.isCancelled, self.generationToken == generationToken else {
                player.endGeneration(token: generationToken)
                return
            }
            diagnostics.timelineLost = true
            if !diagnostics.graphPrepared {
                if case BufferedAudioError.invalidAudioGraphFormat = error {
                    diagnostics.graphLastErrorCode = "RX_AUDIO_GRAPH_FORMAT_INVALID"
                } else {
                    diagnostics.graphLastErrorCode = "RX_AUDIO_GRAPH_PREPARE_FAILED"
                }
            }
            diagnostics.terminalReason = player.playbackDiagnostics.lastErrorCode ?? "receive_failed"
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_FAILED", generationId: generationId, resultClass: String(describing: type(of: error)))
            onFailure("BATV1_RX_\(String(describing: type(of: error)).uppercased())")
        }
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_STOP_BEGIN", generationId: generationId)
        player.endGeneration(token: generationToken)
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_STOP_END", generationId: generationId)
        guard self.generationToken == generationToken else { return }
        subscriptionActive = false
        if !terminalDrainPublished {
            onActivity(senderSessionId, false)
            await onTimelineDrained()
            guard self.generationToken == generationToken else { return }
            diagnostics.endCueAt = diagnostics.endCueAt ?? Date()
        }
        diagnostics.generationId = nil
        activeSenderSessionId = nil
    }

    private func missingFinalFallbackEligible(
        response: Batv1SubscribeResponse,
        cursor: Int,
        now: TimeInterval
    ) async -> Bool {
        guard diagnostics.controlEndReceivedAt != nil,
              controlEndUptime != nil,
              cursor > response.latestSequence,
              let stableSince = latestSequenceStableSinceUptime else { return false }
        if floorTerminalUptime == nil,
           lastFloorStatusPollUptime.map({ now - $0 >= Self.floorStatusPollIntervalSeconds }) ?? true {
            lastFloorStatusPollUptime = now
            if let floor = try? await api.floorStatus(sessionId: sessionId), senderNoLongerOwnsFloor(floor) {
                floorTerminalUptime = monotonicNow()
            }
        }
        guard let floorTerminalUptime else { return false }
        let evidenceSince = max(stableSince, max(controlEndUptime ?? now, floorTerminalUptime))
        return now - evidenceSince >= Self.missingFinalStableGraceSeconds
    }

    private func senderNoLongerOwnsFloor(_ floor: FloorResponse) -> Bool {
        if floor.outcome == .available || floor.outcome == .released { return true }
        if let expectedLeaseId, let actualLeaseId = floor.leaseId, actualLeaseId != expectedLeaseId { return true }
        if let senderUserId, let ownerId = floor.owner?.id, ownerId != senderUserId { return true }
        return false
    }
}
