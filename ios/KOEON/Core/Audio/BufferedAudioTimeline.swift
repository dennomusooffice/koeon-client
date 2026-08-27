import AVFoundation
import Foundation

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
    var captureArmed = false
    var captureConfirmed = false
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

    func arm(generationId: String) {
        lock.withLock {
            frames.removeAll(keepingCapacity: true)
            partial.removeAll(keepingCapacity: true)
            self.generationId = generationId
            forward = nil
            dropped = 0
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
    func prepare(generationId: String)
    func audioSessionDidActivate()
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool
    func authorize(leaseId: String, generationId: String) async throws
    func finish(generationId: String) async throws
    func discard(generationId: String)
    var diagnostics: BufferedAudioTxDiagnostics { get }
}

@MainActor
final class BufferedAudioTransmitter: BufferedAudioTransmitting {
    private let api: any KOEONAPIClientProtocol
    private let capture: Batv1CaptureBuffer
    private let channelId: String
    private let sessionId: String
    private let deviceId: String
    private let pending = Batv1PendingFrames()
    private var generationId: String?
    private var leaseId: String?
    private var nextSequence = 0
    private var authorized = false
    private var sendTask: Task<Void, Never>?
    private var sendError: Error?
    private(set) var diagnostics = BufferedAudioTxDiagnostics()

    init(
        api: any KOEONAPIClientProtocol,
        capture: Batv1CaptureBuffer,
        channelId: String,
        sessionId: String,
        deviceId: String
    ) {
        self.api = api
        self.capture = capture
        self.channelId = channelId
        self.sessionId = sessionId
        self.deviceId = deviceId
    }

    func prepare(generationId: String) {
        discard(generationId: self.generationId ?? "")
        self.generationId = generationId
        diagnostics = BufferedAudioTxDiagnostics(generationId: generationId)
    }

    func audioSessionDidActivate() {
        guard let generationId, !diagnostics.captureArmed else { return }
        capture.arm(generationId: generationId)
        diagnostics.captureArmed = true
    }

    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool {
        guard self.generationId == generationId, diagnostics.captureArmed else { return false }
        let confirmed = await capture.awaitCapture()
        diagnostics.captureConfirmed = confirmed
        guard confirmed else { return false }
        capture.markCueBoundary()
        return true
    }

    func authorize(leaseId: String, generationId: String) async throws {
        guard self.generationId == generationId, diagnostics.captureConfirmed else {
            throw BufferedAudioError.captureNotConfirmed
        }
        self.leaseId = leaseId
        authorized = true
        let seeded = capture.startForwarding { [pending] frame in pending.append(frame) }
        diagnostics.preRollBufferedFrames = seeded
        sendTask = Task { @MainActor [weak self] in await self?.sendLoop() }
    }

    func finish(generationId: String) async throws {
        guard self.generationId == generationId, authorized else { throw BufferedAudioError.generationMismatch }
        capture.stopForwarding()
        authorized = false
        await sendTask?.value
        if let sendError { throw sendError }
        let finalSequence = nextSequence - 1
        guard finalSequence >= 0, let leaseId else { throw BufferedAudioError.emptyGeneration }
        _ = try await api.publishBufferedAudio(request(
            leaseId: leaseId,
            generationId: generationId,
            frames: [],
            firstSequence: nextSequence,
            finalSequence: finalSequence
        ))
        capture.discard()
        pending.removeAll()
        sendTask = nil
    }

    func discard(generationId: String) {
        guard generationId.isEmpty || self.generationId == generationId else { return }
        authorized = false
        sendTask?.cancel()
        sendTask = nil
        capture.discard()
        pending.removeAll()
        self.generationId = nil
        leaseId = nil
        nextSequence = 0
        sendError = nil
    }

    private func sendLoop() async {
        guard let generationId, let leaseId else { return }
        while !Task.isCancelled {
            let batch = pending.take(maximum: 10)
            if batch.isEmpty {
                if !authorized { break }
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            do {
                _ = try await api.publishBufferedAudio(request(
                    leaseId: leaseId,
                    generationId: generationId,
                    frames: batch,
                    firstSequence: nextSequence,
                    finalSequence: nil
                ))
                nextSequence += batch.count
                diagnostics.canonicalFramesSent = nextSequence
                diagnostics.canonicalBytesSent = nextSequence * batv1BytesPerFrame
                diagnostics.canonicalLastSequence = nextSequence - 1
                diagnostics.canonicalDroppedFrames = capture.droppedFrames
            } catch {
                sendError = error
                diagnostics.lastErrorCode = "BATV1_PUBLISH_FAILED"
                authorized = false
                break
            }
        }
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
}

@MainActor
private final class IOSBatv1PcmPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(batv1SampleRate),
        channels: AVAudioChannelCount(batv1Channels),
        interleaved: false
    )!
    private(set) var pendingFrames = 0
    private(set) var completedFrames = 0

    func start() throws {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func setRate(_ rate: Float) {
        timePitch.rate = min(batv1MaximumPlaybackRate, max(1, rate))
        timePitch.pitch = 0
    }

    func enqueue(_ data: Data) throws {
        guard data.count == batv1BytesPerFrame,
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
                guard let self else { return }
                self.pendingFrames = max(0, self.pendingFrames - 1)
                self.completedFrames += 1
            }
        }
    }

    func drain() async {
        while pendingFrames > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.detach(player)
        engine.detach(timePitch)
        pendingFrames = 0
    }
}

@MainActor
final class BufferedAudioReceiver {
    private let api: any KOEONAPIClientProtocol
    private let sessionId: String
    private let onActivity: (String?, Bool) -> Void
    private let onPcm: (Date) -> Void
    private var task: Task<Void, Never>?
    private var audioSessionActive = false
    private(set) var diagnostics = BufferedAudioRxDiagnostics()

    init(
        api: any KOEONAPIClientProtocol,
        sessionId: String,
        onActivity: @escaping (String?, Bool) -> Void = { _, _ in },
        onPcm: @escaping (Date) -> Void = { _ in }
    ) {
        self.api = api
        self.sessionId = sessionId
        self.onActivity = onActivity
        self.onPcm = onPcm
    }

    func start(generationId: String, senderSessionId: String?) {
        stop()
        diagnostics = BufferedAudioRxDiagnostics(generationId: generationId)
        task = Task { @MainActor [weak self] in
            await self?.receive(generationId: generationId, senderSessionId: senderSessionId)
        }
    }

    func audioSessionDidActivate() { audioSessionActive = true }
    func audioSessionDidDeactivate() { audioSessionActive = false }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func receive(generationId: String, senderSessionId: String?) async {
        while !audioSessionActive, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        let player = IOSBatv1PcmPlayer()
        do {
            try player.start()
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
                    response = try await api.subscribeBufferedAudio(
                        Batv1SubscribeRequest(sessionId: sessionId, generationId: generationId, nextSequence: cursor)
                    )
                } catch {
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
                    try player.enqueue(data)
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
                    await player.drain()
                    diagnostics.playbackCursor = cursor
                    diagnostics.backlogMilliseconds = 0
                    diagnostics.playbackRate = 1
                    break
                }
                if response.chunks.isEmpty || player.pendingFrames > 75 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            diagnostics.timelineLost = true
        }
        player.setRate(1)
        player.stop()
        onActivity(senderSessionId, false)
    }
}
