import AVFoundation
import Foundation
import LiveKit

private let batv1BreadcrumbMaximumEvents = 64

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
}

struct BufferedAudioRxDiagnostics: Equatable, Sendable {
    var generationId: String?
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
}

/// Realtime capture only copies post-processed PCM into bounded RAM.
/// It never performs network I/O and never writes audio to disk.
final class Batv1CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var partial = Data()
    private var generationId: String?
    private var forward: (@Sendable (Data) -> Void)?
    private var dropped = 0
    private var firstPcmAt: Date?

    func arm(generationId: String) {
        lock.withLock {
            frames.removeAll(keepingCapacity: true)
            partial.removeAll(keepingCapacity: true)
            self.generationId = generationId
            forward = nil
            dropped = 0
            firstPcmAt = nil
        }
    }

    /// Defines seq0 immediately before the user-visible start cue.
    func markCueBoundary() {
        lock.withLock {
            frames.removeAll(keepingCapacity: true)
            partial.removeAll(keepingCapacity: true)
            dropped = 0
        }
    }

    func append(samples: [Int16], sampleRate: Int, channels: Int) {
        guard sampleRate == batv1SampleRate, channels == batv1Channels, !samples.isEmpty else { return }
        let bytes = samples.withUnsafeBytes { Data($0) }
        lock.withLock {
            guard generationId != nil else { return }
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

    func awaitCapture(timeoutMilliseconds: Int = 750) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while ContinuousClock.now < deadline {
            if frameCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return frameCount > 0
    }

    /// Seeds the consumer and installs forwarding while holding the same lock,
    /// so a live frame cannot overtake the pre-roll snapshot.
    func startForwarding(_ consumer: @escaping @Sendable (Data) -> Void) -> Int {
        lock.withLock {
            let count = frames.count
            frames.forEach(consumer)
            forward = consumer
            return count
        }
    }

    func stopForwarding() { lock.withLock { forward = nil } }

    func discard() {
        lock.withLock {
            generationId = nil
            forward = nil
            frames.removeAll(keepingCapacity: false)
            partial.removeAll(keepingCapacity: false)
        }
    }

    var frameCount: Int { lock.withLock { frames.count } }
    var droppedFrames: Int { lock.withLock { dropped } }
    var firstPcmTimestamp: Date? { lock.withLock { firstPcmAt } }
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

    func append(_ frame: Data) { lock.withLock { frames.append(frame) } }
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
    func removeAll() { lock.withLock { frames.removeAll(keepingCapacity: false) } }
}

@MainActor
protocol BufferedAudioTransmitting: AnyObject {
    func prepare(generationId: String) async
    func audioSessionDidActivate() async throws
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool
    func authorize(leaseId: String, generationId: String) async throws
    func finish(generationId: String) async throws
    func discard(generationId: String) async
    var diagnostics: BufferedAudioTxDiagnostics { get }
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
        guard self.generationId == generationId, diagnostics.captureArmed else { return false }
        let confirmed = await capture.awaitCapture()
        diagnostics.captureConfirmed = confirmed
        diagnostics.firstPcmAt = capture.firstPcmTimestamp
        diagnostics.captureConfirmedAt = confirmed ? Date() : nil
        if let armed = diagnostics.captureArmedAt, let confirmedAt = diagnostics.captureConfirmedAt {
            diagnostics.captureConfirmMilliseconds = max(0, Int(confirmedAt.timeIntervalSince(armed) * 1_000))
        }
        diagnostics.captureState = confirmed ? "ACTIVE" : "ERROR"
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
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_FINAL_MARKER_BEGIN", generationId: generationId)
            _ = try await api.publishBufferedAudio(request(
                leaseId: leaseId,
                generationId: generationId,
                frames: [],
                firstSequence: nextSequence,
                finalSequence: finalSequence
            ))
            Batv1CrashBreadcrumbStore.shared.record(role: "TX", stage: "TX_FINAL_MARKER_END", generationId: generationId)
            await cleanup(generationId: generationId, state: .stopped)
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
            let batch = pending.take(maximum: 10)
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

    private func cleanup(generationId: String?, state: Batv1LifecycleState) async {
        capture.stopForwarding()
        stopLocalRecording(generationId: generationId)
        capture.discard()
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
}

@MainActor
protocol IOSBatv1PcmPlaying: AnyObject {
    var pendingFrames: Int { get }
    var completedFrames: Int { get }
    func beginGeneration(token: Int) throws
    func setRate(_ rate: Float)
    func enqueue(_ data: Data, generationToken: Int) throws
    func drain(generationToken: Int) async
    func endGeneration(token: Int)
    func resumeIfNeeded() throws
    func shutdown()
}

@MainActor
final class Batv1GenerationCompletionFence {
    private(set) var activeToken: Int?
    func begin(_ token: Int) { activeToken = token }
    func accepts(_ token: Int) -> Bool { activeToken == token }
    func end(_ token: Int) { if activeToken == token { activeToken = nil } }
}

@MainActor
private final class IOSBatv1PcmPlayer: IOSBatv1PcmPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(batv1SampleRate),
        channels: AVAudioChannelCount(batv1Channels),
        interleaved: false
    )!
    private var graphPrepared = false
    private let completionFence = Batv1GenerationCompletionFence()
    private(set) var pendingFrames = 0
    private(set) var completedFrames = 0

    func beginGeneration(token: Int) throws {
        if !graphPrepared {
            engine.attach(player)
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            engine.prepare()
            graphPrepared = true
        }
        if !engine.isRunning { try engine.start() }
        player.stop()
        player.reset()
        pendingFrames = 0
        completedFrames = 0
        completionFence.begin(token)
        setRate(1)
        player.play()
    }

    func setRate(_ rate: Float) {
        timePitch.rate = min(batv1MaximumPlaybackRate, max(1, rate))
        timePitch.pitch = 0
    }

    func enqueue(_ data: Data, generationToken: Int) throws {
        guard completionFence.accepts(generationToken),
              data.count == batv1BytesPerFrame,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(batv1SampleRate * batv1FrameDurationMilliseconds / 1_000)
              ),
              let destination = buffer.int16ChannelData?[0] else {
            throw BufferedAudioError.invalidWireFormat
        }
        buffer.frameLength = buffer.frameCapacity
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: data.count))
        pendingFrames += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.completionFence.accepts(generationToken) else {
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "IGNORE_STALE_CALLBACK", resultClass: "GENERATION_FENCED")
                    return
                }
                self.pendingFrames = max(0, self.pendingFrames - 1)
                self.completedFrames += 1
            }
        }
    }

    func drain(generationToken: Int) async {
        while completionFence.accepts(generationToken), pendingFrames > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func endGeneration(token: Int) {
        guard completionFence.accepts(token) else { return }
        player.stop()
        player.reset()
        setRate(1)
        pendingFrames = 0
        completedFrames = 0
        completionFence.end(token)
    }

    func resumeIfNeeded() throws {
        guard completionFence.activeToken != nil else { return }
        if !engine.isRunning { try engine.start() }
        if !player.isPlaying { player.play() }
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
    private let api: any KOEONAPIClientProtocol
    private let sessionId: String
    private let onActivity: (String?, Bool) -> Void
    private let onPcm: (Date) -> Void
    private let onFailure: (String) -> Void
    private let player: any IOSBatv1PcmPlaying
    private var task: Task<Void, Never>?
    private var audioSessionActive = false
    private var generationToken = 0
    private(set) var diagnostics = BufferedAudioRxDiagnostics()

    init(
        api: any KOEONAPIClientProtocol,
        sessionId: String,
        onActivity: @escaping (String?, Bool) -> Void = { _, _ in },
        onPcm: @escaping (Date) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in },
        player: (any IOSBatv1PcmPlaying)? = nil
    ) {
        self.api = api
        self.sessionId = sessionId
        self.onActivity = onActivity
        self.onPcm = onPcm
        self.onFailure = onFailure
        self.player = player ?? IOSBatv1PcmPlayer()
    }

    func start(generationId: String, senderSessionId: String?) {
        let previous = task
        previous?.cancel()
        generationToken += 1
        let token = generationToken
        diagnostics = BufferedAudioRxDiagnostics(generationId: generationId)
        task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generationToken == token else { return }
            await self.receive(generationId: generationId, senderSessionId: senderSessionId, generationToken: token)
        }
    }

    func audioSessionDidActivate() {
        audioSessionActive = true
        do { try player.resumeIfNeeded() } catch {
            diagnostics.timelineLost = true
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_RESUME_FAILED", resultClass: String(describing: type(of: error)))
            onFailure("BATV1_RX_RESUME_FAILED")
        }
    }
    func audioSessionDidDeactivate() { audioSessionActive = false }

    func stop() {
        generationToken += 1
        task?.cancel()
    }

    func stopAndAwait() async {
        generationToken += 1
        let previous = task
        previous?.cancel()
        await previous?.value
        task = nil
    }

    func awaitCurrentGenerationTermination() async { await task?.value }

    func shutdownAndAwait() async {
        await stopAndAwait()
        player.shutdown()
    }

    private func receive(generationId: String, senderSessionId: String?, generationToken: Int) async {
        while !audioSessionActive, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_START", generationId: generationId)
        do {
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_PREPARE", generationId: generationId)
            try player.beginGeneration(token: generationToken)
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_START", generationId: generationId)
            onActivity(senderSessionId, true)
            var cursor = 0
            var lastSequence = -1
            while !Task.isCancelled {
                if !audioSessionActive {
                    try? await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let response: Batv1SubscribeResponse
                do {
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: generationId)
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
                    await player.drain(generationToken: generationToken)
                    diagnostics.playbackCursor = cursor
                    diagnostics.backlogMilliseconds = 0
                    diagnostics.playbackRate = 1
                    Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_DRAIN_END", generationId: generationId)
                    break
                }
                if response.chunks.isEmpty || player.pendingFrames > 75 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            diagnostics.timelineLost = true
            Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_FAILED", generationId: generationId, resultClass: String(describing: type(of: error)))
            onFailure("BATV1_RX_\(String(describing: type(of: error)).uppercased())")
        }
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_STOP_BEGIN", generationId: generationId)
        player.endGeneration(token: generationToken)
        Batv1CrashBreadcrumbStore.shared.record(role: "RX", stage: "RX_PLAYER_STOP_END", generationId: generationId)
        onActivity(senderSessionId, false)
    }
}
