import AVFoundation
import Combine
import Foundation
import LiveKit

func shouldKeepLiveKitEngineAvailableWhenEnteringPttManagedMode(
    appleAudioSessionAlreadyActive: Bool
) -> Bool {
    appleAudioSessionAlreadyActive
}

enum InputGainMode: String, CaseIterable, Sendable { case off = "OFF", auto = "AUTO", manual = "MANUAL" }

struct InputGainSnapshot: Sendable {
    var route = "Unknown"
    var mode: InputGainMode = .auto
    var manualGainDb: Float = 0
    var autoTrimDb: Float = 0
    var effectiveGainDb: Float = 0
    var rmsDbfs: Float?
    var peakDbfs: Float?
    var limiterHits = 0
    var calibrationState = "IDLE"
    var recommendationDb: Float?
}

/// In-place, no-lookahead capture trim. It never owns AVAudioSession or queues audio.
final class InputGainProcessor: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var value = InputGainSnapshot()
    private var transmitting = false
    private var fixedGainDb: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount = 0
    private var peak: Float = 0
    private var calibrationUntil: Date?
    private var calibrationRms: [Float] = []

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var audioProcessingName: String { "koeon_input_gain_v1" }
    func audioProcessingInitialize(sampleRate: Int, channels: Int) {}
    func audioProcessingRelease() {}

    func setRoute(_ route: String) {
        lock.withLock {
            guard value.route != route else { return }
            value.route = route
            value.manualGainDb = defaults.float(forKey: key("manual", route))
            value.autoTrimDb = defaults.float(forKey: key("auto", route))
            resetMeasurements()
        }
    }
    func setMode(_ mode: InputGainMode) { lock.withLock { value.mode = mode } }
    func setManualGainDb(_ gain: Float) { lock.withLock { value.manualGainDb = clamp(gain); defaults.set(value.manualGainDb, forKey: key("manual", value.route)) } }
    func beginTransmission() { lock.withLock { transmitting = true; fixedGainDb = effectiveGain(); resetMeasurements() } }
    func endTransmission() {
        lock.withLock {
            transmitting = false
            if value.mode == .auto, sampleCount >= 4_800, value.limiterHits < sampleCount / 20, let rms = rmsDbfs() {
                value.autoTrimDb = Self.nextAutoTrim(current: value.autoTrimDb, speechRmsDbfs: rms)
                defaults.set(value.autoTrimDb, forKey: key("auto", value.route))
            }
        }
    }
    func startCalibration(now: Date = Date()) { lock.withLock { calibrationRms = []; calibrationUntil = now.addingTimeInterval(3); value.calibrationState = "MEASURING"; value.recommendationDb = nil } }
    func resetProfile() { lock.withLock { defaults.removeObject(forKey: key("manual", value.route)); defaults.removeObject(forKey: key("auto", value.route)); value.manualGainDb = 0; value.autoTrimDb = 0; value.recommendationDb = nil } }
    func snapshot() -> InputGainSnapshot { lock.withLock { var copy = value; copy.effectiveGainDb = transmitting ? fixedGainDb : effectiveGain(); copy.rmsDbfs = rmsDbfs(); copy.peakDbfs = sampleCount > 0 ? dbfs(peak) : nil; return copy } }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        lock.withLock {
            let gainDb = transmitting ? fixedGainDb : effectiveGain()
            let multiplier = powf(10, gainDb / 20)
            let processingEnabled = value.mode != .off
            var frameSquares: Double = 0
            var frameSamples = 0
            for channel in 0..<audioBuffer.channels {
                let samples = audioBuffer.rawBuffer(forChannel: channel)
                for frame in 0..<audioBuffer.frames {
                    let normalized = samples[frame] / 32_768
                    frameSquares += Double(normalized * normalized)
                    peak = max(peak, abs(normalized))
                    if processingEnabled {
                        let processed = Self.softLimitSample(normalized * multiplier)
                        if processed.limited { value.limiterHits += 1 }
                        samples[frame] = processed.sample * 32_767
                    }
                    frameSamples += 1
                }
            }
            guard frameSamples > 0 else { return }
            sumSquares += frameSquares
            sampleCount += frameSamples
            if let deadline = calibrationUntil {
                calibrationRms.append(dbfs(sqrtf(Float(frameSquares / Double(frameSamples)))))
                if Date() >= deadline { finishCalibration() }
            }
        }
    }

    static func recommendedGain(speechRmsDbfs: Float) -> Float { min(12, max(-6, -18 - speechRmsDbfs)) }
    static func nextAutoTrim(current: Float, speechRmsDbfs: Float) -> Float { min(12, max(-6, current + min(1, max(-1, -18 - speechRmsDbfs)))) }
    static func processSample(_ sample: Float, gainDb: Float) -> (sample: Float, limited: Bool) {
        let amplified = sample * powf(10, min(12, max(-6, gainDb)) / 20)
        return softLimitSample(amplified)
    }
    private static func softLimitSample(_ amplified: Float) -> (sample: Float, limited: Bool) {
        let sign: Float = amplified < 0 ? -1 : 1, magnitude = abs(amplified), knee: Float = 0.75, ceiling: Float = 0.89125
        guard magnitude > knee else { return (amplified, false) }
        let output = sign * min(ceiling, knee + (ceiling - knee) * (1 - expf(-(magnitude - knee) / (ceiling - knee))))
        return (output, true)
    }
    private func finishCalibration() {
        calibrationUntil = nil
        value.calibrationState = "IDLE"
        let voiced = calibrationRms.filter { $0 > -45 }
        guard voiced.count >= 10 else { value.recommendationDb = nil; return }
        let speech = voiced.reduce(0, +) / Float(voiced.count)
        value.recommendationDb = Self.recommendedGain(speechRmsDbfs: speech)
        value.autoTrimDb = value.recommendationDb!
        defaults.set(value.autoTrimDb, forKey: key("auto", value.route))
    }
    private func effectiveGain() -> Float { clamp(value.mode == .off ? 0 : value.mode == .manual ? value.manualGainDb : value.autoTrimDb) }
    private func resetMeasurements() { sumSquares = 0; sampleCount = 0; peak = 0; value.limiterHits = 0 }
    private func rmsDbfs() -> Float? { sampleCount == 0 ? nil : dbfs(sqrtf(Float(sumSquares / Double(sampleCount)))) }
    private func dbfs(_ v: Float) -> Float { v <= 0 ? -120 : max(-120, 20 * log10f(v)) }
    private func clamp(_ v: Float) -> Float { min(12, max(-6, v)) }
    private func key(_ field: String, _ route: String) -> String { "audio.gain.\(route.lowercased().replacingOccurrences(of: " ", with: "_").prefix(80)).\(field)" }
}

enum AudioRouteKind: String, Sendable {
    case builtIn = "Built-in"
    case speaker = "Speaker"
    case receiver = "Receiver"
    case bluetooth = "Bluetooth"
    case wired = "Wired"
    case usb = "USB"
    case unknown = "Unknown"
}

enum AudioAvailabilityState: String, Sendable {
    case ready = "READY"
    case interrupted = "INTERRUPTED"
    case recovering = "RECOVERING"
    case recoveryFailed = "RECOVERY_FAILED"
}

struct AudioInterruptionSnapshot: Equatable, Sendable {
    var state: AudioAvailabilityState = .ready
    var interruptionStartedAt: Date?
    var interruptionEndedAt: Date?
    var interruptionReason: String?
    var recoveryStartedAt: Date?
    var recoveryCompletedAt: Date?
    var recoveryMilliseconds: Int?
    var autoRecoveryResult = "not_required"
    var lastRecoveryError: String?
    var generation = 0
}

struct AudioRouteChangeSnapshot: Equatable, Sendable {
    let previous: AudioRouteKind
    let current: AudioRouteKind
    let reason: String
    let lostExternalInputRoute: Bool
}

func shouldSafetyStopForRouteChange(
    lostExternalInputRoute: Bool,
    pttState: PTTState
) -> Bool {
    lostExternalInputRoute && (pttState == .transmitting || pttState == .requestingFloor)
}

struct AudioInterruptionStateMachine: Sendable {
    private(set) var snapshot = AudioInterruptionSnapshot()

    mutating func interrupt(reason: String, at now: Date) -> Int {
        if snapshot.state == .interrupted { return snapshot.generation }
        snapshot.state = .interrupted
        snapshot.interruptionStartedAt = now
        snapshot.interruptionEndedAt = nil
        snapshot.interruptionReason = reason
        snapshot.recoveryStartedAt = nil
        snapshot.recoveryCompletedAt = nil
        snapshot.recoveryMilliseconds = nil
        snapshot.autoRecoveryResult = "pending"
        snapshot.lastRecoveryError = nil
        snapshot.generation += 1
        return snapshot.generation
    }

    mutating func beginRecovery(generation: Int, at now: Date) -> Bool {
        guard generation == snapshot.generation,
              snapshot.state != .ready,
              snapshot.state != .recovering else { return false }
        snapshot.state = .recovering
        snapshot.interruptionEndedAt = now
        snapshot.recoveryStartedAt = now
        snapshot.autoRecoveryResult = "in_progress"
        snapshot.lastRecoveryError = nil
        return true
    }

    mutating func completeRecovery(generation: Int, at now: Date) -> Bool {
        guard generation == snapshot.generation, snapshot.state == .recovering else { return false }
        snapshot.state = .ready
        snapshot.recoveryCompletedAt = now
        snapshot.recoveryMilliseconds = max(0, Int(now.timeIntervalSince(snapshot.recoveryStartedAt ?? now) * 1_000))
        snapshot.autoRecoveryResult = "success"
        snapshot.lastRecoveryError = nil
        return true
    }

    mutating func failRecovery(generation: Int, error: String) -> Bool {
        guard generation == snapshot.generation, snapshot.state == .recovering else { return false }
        snapshot.state = .recoveryFailed
        snapshot.autoRecoveryResult = "failed"
        snapshot.lastRecoveryError = error
        return true
    }

    mutating func reset() { snapshot = AudioInterruptionSnapshot() }
}

@MainActor
final class AudioSessionController: ObservableObject {
    @Published private(set) var route: AudioRouteKind = .unknown
    @Published private(set) var audioSessionState = "LiveKit managed"
    @Published private(set) var pushToTalkAudioSessionActive = false
    @Published private(set) var liveKitEngineAvailability = "DEFAULT"
    @Published private(set) var interruption = AudioInterruptionSnapshot()
    @Published private(set) var lastError: String?
    @Published private(set) var previousRoute: AudioRouteKind = .unknown
    @Published private(set) var routeChangeReason = "initial"
    @Published private(set) var mediaServicesState = "available"
    @Published private(set) var outputVolume: Float
    @Published private(set) var outputVolumeObservedAt: Date?
    @Published private(set) var inputProfileKey = "Unknown"

    var onUnsafeInterruption: (@MainActor @Sendable (String) -> Void)?
    var onInterruptionEnded: (@MainActor @Sendable (Int) -> Void)?
    var onRouteChanged: (@MainActor @Sendable (AudioRouteChangeSnapshot) -> Void)?

    private let center: NotificationCenter
    private let audioSession: AVAudioSession
    private var observers: [NSObjectProtocol] = []
    private var outputVolumeObservation: NSKeyValueObservation?
    private var interruptionState = AudioInterruptionStateMachine()

    init(center: NotificationCenter = .default, audioSession: AVAudioSession = .sharedInstance()) {
        self.center = center
        self.audioSession = audioSession
        self.outputVolume = audioSession.outputVolume
        AudioManager.prepare()
        observe()
        updateRoute()
    }

    deinit {
        observers.forEach(center.removeObserver)
        outputVolumeObservation?.invalidate()
    }

    func setOutputVolumeObservationEnabled(_ enabled: Bool) {
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = nil
        guard enabled else { outputVolumeObservedAt = nil; return }
        outputVolume = audioSession.outputVolume
        outputVolumeObservation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            Task { @MainActor in
                guard let self, let value = change.newValue else { return }
                self.outputVolume = value
                self.outputVolumeObservedAt = Date()
            }
        }
    }

    func prepareForIntercom(canPublish: Bool) async {
        // LiveKit remains the sole AVAudioSession category/activation owner.
        AudioManager.shared.isSpeakerOutputPreferred = true
        guard canPublish else { return }
        do {
            try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
            audioSessionState = "LiveKit managed / microphone prepared"
        } catch {
            // Prewarming is an optimization. The first PTT may still publish normally.
            lastError = "Microphone prewarm failed: \(safeMessage(error))"
        }
        updateRoute()
    }

    func beginPushToTalkManagedSession() async throws {
        // Apple PushToTalk owns AVAudioSession activation while the channel is active.
        // LiveKit is gated so it cannot activate or reconfigure the session behind it.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        if shouldKeepLiveKitEngineAvailableWhenEnteringPttManagedMode(
            appleAudioSessionAlreadyActive: pushToTalkAudioSessionActive
        ) {
            try AudioManager.shared.setEngineAvailability(.default)
            liveKitEngineAvailability = "DEFAULT"
            audioSessionState = "Apple PushToTalk active / LiveKit engine preserved"
            return
        }
        try AudioManager.shared.setEngineAvailability(.none)
        pushToTalkAudioSessionActive = false
        liveKitEngineAvailability = "NONE"
        audioSessionState = "Apple PushToTalk managed / waiting for activation"
    }

    func pushToTalkDidActivate(_ activatedSession: AVAudioSession) async {
        do {
            // Configure the already-activated session but never call setActive here.
            try activatedSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try AudioManager.shared.setEngineAvailability(.default)
            pushToTalkAudioSessionActive = true
            liveKitEngineAvailability = "DEFAULT"
            audioSessionState = "Apple PushToTalk active / LiveKit engine available"
            lastError = nil
            updateRoute()
            if interruption.state == .recovering {
                completeRecovery(generation: interruption.generation)
            }
        } catch {
            lastError = "PushToTalk audio activation failed: \(safeMessage(error))"
        }
    }

    func pushToTalkDidDeactivate() async {
        do {
            try AudioManager.shared.setEngineAvailability(.none)
            liveKitEngineAvailability = "NONE"
        } catch {
            lastError = "LiveKit audio engine suspension failed: \(safeMessage(error))"
        }
        pushToTalkAudioSessionActive = false
        audioSessionState = "Apple PushToTalk managed / inactive"
        updateRoute()
    }

    func endPushToTalkManagedSession() async {
        do {
            try AudioManager.shared.setEngineAvailability(.default)
            liveKitEngineAvailability = "DEFAULT"
        } catch {
            lastError = "LiveKit audio engine restore failed: \(safeMessage(error))"
        }
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        pushToTalkAudioSessionActive = false
        audioSessionState = "LiveKit managed / idle"
    }

    func endIntercom() async {
        do {
            try await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
        } catch {
            lastError = "Microphone prewarm cleanup failed: \(safeMessage(error))"
        }
        audioSessionState = "LiveKit managed / idle"
        interruptionState.reset()
        interruption = interruptionState.snapshot
        updateRoute()
    }

    @discardableResult
    func markInterrupted(_ reason: String) -> Int {
        let generation = interruptionState.interrupt(reason: reason, at: Date())
        interruption = interruptionState.snapshot
        audioSessionState = "Interrupted"
        onUnsafeInterruption?(reason)
        return generation
    }

    func beginRecovery(generation: Int) -> Bool {
        let began = interruptionState.beginRecovery(generation: generation, at: Date())
        interruption = interruptionState.snapshot
        if began { audioSessionState = "Recovering / awaiting PushToTalk audio activation" }
        return began
    }

    @discardableResult
    func completeRecovery(generation: Int) -> Bool {
        guard interruptionState.completeRecovery(generation: generation, at: Date()) else { return false }
        interruption = interruptionState.snapshot
        audioSessionState = "Apple PushToTalk managed / audio recovered"
        lastError = nil
        updateRoute()
        return true
    }

    func failRecovery(generation: Int, error: String) {
        guard interruptionState.failRecovery(generation: generation, error: error) else { return }
        interruption = interruptionState.snapshot
        audioSessionState = "Audio recovery failed"
        lastError = error
    }

    private func observe() {
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.audioSessionState = "Media services lost"
                self?.mediaServicesState = "lost"
                self?.markInterrupted("iOS audio media services were lost.")
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.audioSessionState = "Media services reset / LiveKit managed"
                self?.mediaServicesState = "reset"
                self?.routeChangeReason = "media_services_reset"
                self?.updateRoute()
                if let self, self.interruption.state != .ready {
                    self.onInterruptionEnded?(self.interruption.generation)
                }
            }
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            markInterrupted("iOS audio session interruption began.")
        case .ended:
            audioSessionState = "Interruption ended / LiveKit managed"
            updateRoute()
            if interruption.state != .ready { onInterruptionEnded?(interruption.generation) }
        @unknown default:
            audioSessionState = "Unknown interruption"
            markInterrupted("Unknown iOS audio interruption.")
        }
    }

    private func updateRoute() {
        let outputs = audioSession.currentRoute.outputs
        route = outputs.lazy.map(Self.mapRoute).first { $0 != .unknown } ?? .unknown
        if let input = audioSession.currentRoute.inputs.first {
            inputProfileKey = "ios|\(input.portType.rawValue)|\(input.portName)"
        } else {
            inputProfileKey = "ios|\(route.rawValue)|unavailable"
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let oldDescription = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let oldRoute = oldDescription.map(Self.mapRoute) ?? route
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        previousRoute = oldRoute
        updateRoute()
        routeChangeReason = Self.routeReasonLabel(reason)
        let lostExternal = reason == .oldDeviceUnavailable && (oldRoute == .bluetooth || oldRoute == .wired || oldRoute == .usb)
        onRouteChanged?(AudioRouteChangeSnapshot(
            previous: oldRoute,
            current: route,
            reason: routeChangeReason,
            lostExternalInputRoute: lostExternal
        ))
    }

    static func routeReasonLabel(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        case .unknown: "unknown"
        case nil: "unavailable"
        @unknown default: "unknown"
        }
    }

    private static func mapRoute(_ description: AVAudioSessionRouteDescription) -> AudioRouteKind {
        let outputs = description.outputs.lazy.map(mapRoute)
        let inputs = description.inputs.lazy.map(mapRoute)
        return outputs.first { $0 != .unknown } ?? inputs.first { $0 != .unknown } ?? .unknown
    }

    private static func mapRoute(_ port: AVAudioSessionPortDescription) -> AudioRouteKind {
        switch port.portType {
        case .builtInSpeaker: .speaker
        case .builtInReceiver: .receiver
        case .builtInMic: .builtIn
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: .bluetooth
        case .headphones, .headsetMic, .lineOut: .wired
        case .usbAudio: .usb
        default: .unknown
        }
    }

    private func safeMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }
}
