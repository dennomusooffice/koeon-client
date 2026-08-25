import AVFoundation
import Foundation

enum CuePlayerError: LocalizedError {
    case invalidAudioFormat
    case playbackDidNotStart

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat: "Could not create the PTT cue audio."
        case .playbackDidNotStart: "PTT cue playback did not start."
        }
    }
}

struct CuePolicy: Sendable {
    enum Profile: Sendable { case transmit, receive }
    var koeonCueEnabled: Bool
    var systemCuePreferred: Bool
    var profile: Profile

    // PTChannelManager owns AVAudioSession activation. AVAudioPlayer must not
    // implicitly activate that session before Apple reports didActivate.
    static let alpha = CuePolicy(koeonCueEnabled: false, systemCuePreferred: true, profile: .transmit)
    static let transmitReady = CuePolicy(koeonCueEnabled: true, systemCuePreferred: false, profile: .transmit)
    static let receiveAndStatus = CuePolicy(koeonCueEnabled: true, systemCuePreferred: false, profile: .receive)
}

protocol PttStatusCuePlaying: Sendable {
    func playBusy() async throws
    func playError() async throws
}

struct PttStatusCueRateLimiter: Sendable {
    private var lastAt: [String: Date] = [:]

    mutating func accept(_ type: String, at now: Date = Date()) -> Bool {
        if let last = lastAt[type],
           now.timeIntervalSince(last) * 1_000 < Double(PttCuePlayer.statusCueRateLimitMilliseconds) {
            return false
        }
        lastAt[type] = now
        return true
    }
}

actor PttCuePlayer: PttCuePlaying, PttStatusCuePlaying {
    static let txStartFrequency = 1_350.0
    static let txEndFrequency = 850.0
    static let rxStartFrequency = 1_100.0
    static let rxEndFrequency = 700.0
    static let durationMilliseconds = 100
    static let txRxAmplitude = 0.36
    static let busyAmplitude = 0.50
    static let errorAmplitude = 0.68
    static let statusCueRateLimitMilliseconds = 500

    private var player: AVAudioPlayer?
    private let policy: CuePolicy
    private var statusRateLimiter = PttStatusCueRateLimiter()

    init(policy: CuePolicy = .alpha) {
        self.policy = policy
    }

    func playStart() async throws {
        try await play(
            frequency: policy.profile == .transmit ? Self.txStartFrequency : Self.rxStartFrequency,
            amplitude: Self.txRxAmplitude
        )
    }

    func playEnd() async throws {
        try await play(
            frequency: policy.profile == .transmit ? Self.txEndFrequency : Self.rxEndFrequency,
            amplitude: Self.txRxAmplitude
        )
    }

    func playBusy() async throws {
        guard acceptStatusCue("busy") else { return }
        try await play(sequence: [(600, 100), (0, 60), (600, 100), (0, 60), (600, 100)], amplitude: Self.busyAmplitude)
    }

    func playError() async throws {
        guard acceptStatusCue("error") else { return }
        try await play(sequence: [(1_000, 140), (0, 55), (700, 140), (0, 55), (400, 200)], amplitude: Self.errorAmplitude)
    }

    private func play(frequency: Double, amplitude: Double) async throws {
        try await play(sequence: [(frequency, Self.durationMilliseconds)], amplitude: amplitude)
    }

    private func play(sequence: [(Double, Int)], amplitude: Double) async throws {
        guard policy.koeonCueEnabled else { return }
        let data = Self.makeWave(sequence: sequence, amplitude: min(0.95, max(0, amplitude)))
        let audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer.volume = 1.0
        audioPlayer.prepareToPlay()
        player = audioPlayer
        guard audioPlayer.play() else { throw CuePlayerError.playbackDidNotStart }
        try await Task.sleep(for: .milliseconds(sequence.reduce(0) { $0 + $1.1 }))
        audioPlayer.stop()
        player = nil
    }

    private func acceptStatusCue(_ type: String) -> Bool {
        statusRateLimiter.accept(type)
    }

    private static func makeWave(sequence: [(Double, Int)], amplitude: Double) -> Data {
        let sampleRate = 48_000
        let samples = sequence.flatMap { item in
            makeSamples(frequency: item.0, durationMilliseconds: item.1, sampleRate: sampleRate, amplitude: amplitude)
        }
        return makeWaveData(samples: samples, sampleRate: sampleRate)
    }

    private static func makeSamples(frequency: Double, durationMilliseconds: Int, sampleRate: Int, amplitude: Double) -> [Int16] {
        let sampleCount = sampleRate * durationMilliseconds / 1_000
        guard frequency > 0 else { return Array(repeating: 0, count: sampleCount) }
        let fadeSamples = max(1, sampleRate / 200)
        return (0 ..< sampleCount).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let fadeIn = min(1, Double(index) / Double(fadeSamples))
            let fadeOut = min(1, Double(sampleCount - index - 1) / Double(fadeSamples))
            let envelope = min(fadeIn, fadeOut)
            return Int16((sin(phase) * envelope * amplitude * Double(Int16.max)).rounded())
        }
    }

    private static func makeWaveData(samples: [Int16], sampleRate: Int) -> Data {
        let sampleCount = samples.count
        let bytesPerSample = 2
        let dataSize = sampleCount * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        data.appendASCII("RIFF")
        data.appendLE(UInt32(36 + dataSize))
        data.appendASCII("WAVEfmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * bytesPerSample))
        data.appendLE(UInt16(bytesPerSample))
        data.appendLE(UInt16(16))
        data.appendASCII("data")
        data.appendLE(UInt32(dataSize))

        for sample in samples {
            data.appendLE(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
