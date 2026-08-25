import AVFoundation
import Combine
import CryptoKit
import Foundation
import PushToTalk
import UIKit

enum PushToTalkFrameworkState: String, Sendable {
    case initializing = "INITIALIZING"
    case ready = "READY"
    case joining = "JOINING"
    case joined = "JOINED"
    case leaving = "LEAVING"
    case unavailable = "UNAVAILABLE"
    case error = "ERROR"
}

enum PttRequestGateState: String, Equatable, Sendable {
    case idle = "IDLE"
    case beginRequested = "BEGIN_REQUESTED"
    case transmitting = "TRANSMITTING"
    case endRequested = "END_REQUESTED"
    case rearming = "REARMING"
}

enum PttRequestGateAction: Equatable, Sendable {
    case requestBegin
    case stopSystemTransmission
    case beginFloor
    case finishFloor
    case busy
    case pending
    case error
}

struct PttRequestGate: Equatable, Sendable {
    private(set) var state: PttRequestGateState = .idle
    private(set) var releaseRequestedBeforeBegin = false
    private(set) var floorStarted = false
    private(set) var pendingPressHeld = false

    mutating func pressDown() -> [PttRequestGateAction] {
        if state == .endRequested || state == .rearming {
            pendingPressHeld = true
            return [.pending]
        }
        guard state == .idle else { return [.busy] }
        state = .beginRequested
        releaseRequestedBeforeBegin = false
        floorStarted = false
        pendingPressHeld = false
        return [.requestBegin]
    }

    mutating func pressUp() -> [PttRequestGateAction] {
        switch state {
        case .beginRequested:
            releaseRequestedBeforeBegin = true
            return []
        case .transmitting:
            state = .endRequested
            return [.stopSystemTransmission]
        case .endRequested, .rearming:
            pendingPressHeld = false
            return []
        case .idle:
            return []
        }
    }

    mutating func didBegin() -> [PttRequestGateAction] {
        guard state == .beginRequested else {
            state = .endRequested
            return [.stopSystemTransmission]
        }
        if releaseRequestedBeforeBegin {
            state = .endRequested
            return [.stopSystemTransmission]
        }
        state = .transmitting
        floorStarted = true
        return [.beginFloor]
    }

    mutating func didEnd() -> [PttRequestGateAction] {
        let finish = floorStarted
        state = .rearming
        releaseRequestedBeforeBegin = false
        floorStarted = false
        return finish ? [.finishFloor] : []
    }

    mutating func cancelBeforeSystemBegin() {
        guard state == .beginRequested else { return }
        state = .rearming
        releaseRequestedBeforeBegin = false
        floorStarted = false
    }

    mutating func didFail(recoverable: Bool) -> [PttRequestGateAction] {
        let finish = floorStarted
        state = .rearming
        releaseRequestedBeforeBegin = false
        floorStarted = false
        var actions: [PttRequestGateAction] = finish ? [.finishFloor] : []
        actions.append(recoverable ? .busy : .error)
        return actions
    }

    mutating func finishRearming() -> [PttRequestGateAction] {
        if pendingPressHeld {
            state = .beginRequested
            releaseRequestedBeforeBegin = false
            floorStarted = false
            pendingPressHeld = false
            return [.requestBegin]
        }
        state = .idle
        return []
    }
    mutating func reset() { self = PttRequestGate() }
}

enum PttTransmitOperation: String, Sendable { case begin, stop }

struct PttTransmitFailure: Sendable {
    let operation: PttTransmitOperation
    let message: String
    let recoverable: Bool
    let affectsAudioAvailability: Bool
    let code: String
}

enum ApplePttErrorClassifier {
    static func classify(_ error: Error, operation: PttTransmitOperation) -> PttTransmitFailure {
        let nsError = error as NSError
        let code = nsError.domain == PTChannelError.errorDomain
            ? PTChannelError.Code(rawValue: nsError.code)
            : nil
        let recoverable = code == .transmissionInProgress ||
            code == .transmissionNotAllowed ||
            code == .transmissionNotFound ||
            code == .callActive
        return PttTransmitFailure(
            operation: operation,
            message: String(error.localizedDescription.prefix(240)),
            recoverable: recoverable,
            affectsAudioAvailability: false,
            code: code.map { String(describing: $0) } ?? "unknown"
        )
    }
}

struct PttRestoreDescriptor: Codable, Equatable, Sendable {
    let channelId: String
    let channelName: String
    let channelUUID: UUID
    let canPublish: Bool
    var lastBackendSessionId: String?

    static let defaultsKey = "ptt.restore.descriptor.v2"

    static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.channelUUID == PushToTalkChannelUUID.make(channelId: value.channelId),
              !value.channelId.isEmpty,
              !value.channelName.isEmpty else { return nil }
        return value
    }

    func persist(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
        // RestorationDelegate may be called before actor-owned runtime is rebuilt.
        defaults.set(channelId, forKey: "ptt.channel.id")
        defaults.set(channelName, forKey: "ptt.channel.name")
        defaults.set(channelUUID.uuidString, forKey: "ptt.channel.uuid")
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: "ptt.channel.id")
        defaults.removeObject(forKey: "ptt.channel.name")
        defaults.removeObject(forKey: "ptt.channel.uuid")
    }
}

func shouldPreserveRestoredPttChannel(
    restoredUUID: UUID,
    descriptor: PttRestoreDescriptor?,
    credentialAvailable: Bool
) -> Bool {
    credentialAvailable && descriptor?.channelUUID == restoredUUID
}

func shouldEnablePttAccessoryEvents(
    settingEnabled: Bool,
    canPublish: Bool,
    frameworkState: PushToTalkFrameworkState
) -> Bool {
    settingEnabled && canPublish && frameworkState == .joined
}

struct PttIncomingEvent: Equatable, Sendable {
    let channelId: String
    let speakerUserId: String
    let speakerSessionId: String
    let speakerDisplayName: String
    let leaseId: String
    let acquiredAt: Date
}

func isSelfOriginatedIncomingPush(_ event: PttIncomingEvent, currentSessionId: String?) -> Bool {
    currentSessionId != nil && event.speakerSessionId == currentSessionId
}

enum PttIncomingPayloadValidator {
    static func validate(_ payload: [String: Any], expectedChannelId: String) -> PttIncomingEvent? {
        let version = (payload["version"] as? NSNumber)?.intValue ?? payload["version"] as? Int
        guard version == 2,
              payload["aps"] is [String: Any],
              payload["event"] as? String == "floor_acquired",
              payload["channelId"] as? String == expectedChannelId,
              let speakerUserId = bounded(payload["speakerUserId"], max: 128),
              let speakerSessionId = bounded(payload["speakerSessionId"], max: 128),
              let speakerDisplayName = bounded(payload["speakerDisplayName"], max: 80, rejectControls: true),
              let leaseId = bounded(payload["leaseId"], max: 128),
              let acquiredAtValue = bounded(payload["acquiredAt"], max: 64),
              let acquiredAt = parseISO8601(acquiredAtValue)
        else { return nil }
        return PttIncomingEvent(
            channelId: expectedChannelId,
            speakerUserId: speakerUserId,
            speakerSessionId: speakerSessionId,
            speakerDisplayName: speakerDisplayName,
            leaseId: leaseId,
            acquiredAt: acquiredAt
        )
    }

    private static func bounded(_ value: Any?, max: Int, rejectControls: Bool = false) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= max else { return nil }
        if rejectControls, trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return nil }
        return trimmed
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

final class PttIncomingReplayProtector: @unchecked Sendable {
    private let lock = NSLock()
    private var latestByChannel: [String: PttIncomingEvent] = [:]
    private var localTransmitting = false

    func accept(_ event: PttIncomingEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let latest = latestByChannel[event.channelId],
           latest.leaseId == event.leaseId || event.acquiredAt <= latest.acquiredAt { return false }
        // Pushes use expiration=0, but reject obviously stale payload replay as defense in depth.
        guard event.acquiredAt > Date().addingTimeInterval(-120),
              event.acquiredAt < Date().addingTimeInterval(30) else { return false }
        latestByChannel[event.channelId] = event
        return true
    }

    func setLocalTransmitting(_ value: Bool) {
        lock.lock()
        localTransmitting = value
        lock.unlock()
    }

    func localTransmitIsActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return localTransmitting
    }

    func currentEvent(channelId: String) -> PttIncomingEvent? {
        lock.lock()
        defer { lock.unlock() }
        return latestByChannel[channelId]
    }
}

struct PttEphemeralTokenRegistration: Equatable, Sendable {
    let token: String
    let channelId: String
    let channelUUID: UUID
    let joinGeneration: Int
    let tokenGeneration: Int
    let backendSessionId: String
}

/// Memory-only ownership gate for Apple's channel-scoped ephemeral token.
/// A token can be reused after rejoining the same Apple channel UUID, but is
/// never carried across to a different UUID. Registration is independent of
/// whether the token callback or didJoin arrives first.
struct ApplePttTokenLifecycle: Equatable, Sendable {
    private struct Join: Equatable, Sendable {
        let channelId: String
        let channelUUID: UUID
        let generation: Int
        var joined: Bool
    }

    private struct Token: Equatable, Sendable {
        let value: Data
        var ownerChannelUUID: UUID?
        var ownerJoinGeneration: Int?
        let generation: Int
    }

    private struct RegistrationKey: Equatable, Sendable {
        let joinGeneration: Int
        let tokenGeneration: Int
        let backendSessionId: String
    }

    private(set) var currentJoinGeneration = 0
    private(set) var currentTokenGeneration = 0
    private var join: Join?
    private var token: Token?
    private var inFlight: RegistrationKey?
    private var submitted: RegistrationKey?

    mutating func beginJoin(channelId: String, channelUUID: UUID) {
        currentJoinGeneration += 1
        join = Join(
            channelId: channelId,
            channelUUID: channelUUID,
            generation: currentJoinGeneration,
            joined: false
        )
        inFlight = nil
        submitted = nil
        guard var token else { return }
        if let owner = token.ownerChannelUUID, owner != channelUUID {
            // Apple tokens are scoped to one active channel. Never submit a
            // token observed for channel A after joining channel B.
            self.token = nil
            return
        }
        token.ownerChannelUUID = channelUUID
        token.ownerJoinGeneration = currentJoinGeneration
        self.token = token
    }

    mutating func restoreJoined(channelId: String, channelUUID: UUID) {
        beginJoin(channelId: channelId, channelUUID: channelUUID)
        didJoin(channelUUID: channelUUID)
    }

    mutating func didJoin(channelUUID: UUID) {
        guard var join, join.channelUUID == channelUUID else { return }
        join.joined = true
        self.join = join
        guard var token,
              token.ownerChannelUUID == nil || token.ownerChannelUUID == channelUUID else { return }
        token.ownerChannelUUID = channelUUID
        token.ownerJoinGeneration = join.generation
        self.token = token
    }

    mutating func didLeave(channelUUID: UUID) {
        guard var join, join.channelUUID == channelUUID else { return }
        join.joined = false
        self.join = join
        inFlight = nil
        submitted = nil
    }

    mutating func receivedToken(_ value: Data, activeChannelUUID: UUID?) {
        let ownership: (UUID?, Int?)
        if let join,
           activeChannelUUID == join.channelUUID || (activeChannelUUID == nil && !join.joined) {
            ownership = (join.channelUUID, join.generation)
        } else if let activeChannelUUID {
            ownership = (
                activeChannelUUID,
                join?.channelUUID == activeChannelUUID ? join?.generation : nil
            )
        } else {
            // The first manager callback may precede the first requestJoin.
            // Keep it unbound only in memory and bind it to that first join.
            ownership = (nil, nil)
        }
        if token?.value == value,
           token?.ownerChannelUUID == ownership.0,
           token?.ownerJoinGeneration == ownership.1 {
            return
        }
        currentTokenGeneration += 1
        token = Token(
            value: value,
            ownerChannelUUID: ownership.0,
            ownerJoinGeneration: ownership.1,
            generation: currentTokenGeneration
        )
        inFlight = nil
        submitted = nil
    }

    mutating func claimRegistration(backendSessionId: String?) -> PttEphemeralTokenRegistration? {
        guard let backendSessionId, !backendSessionId.isEmpty,
              let join, join.joined,
              let token,
              token.ownerChannelUUID == join.channelUUID,
              token.ownerJoinGeneration == join.generation else { return nil }
        let key = RegistrationKey(
            joinGeneration: join.generation,
            tokenGeneration: token.generation,
            backendSessionId: backendSessionId
        )
        guard inFlight != key, submitted != key else { return nil }
        inFlight = key
        return PttEphemeralTokenRegistration(
            token: token.value.map { String(format: "%02x", $0) }.joined(),
            channelId: join.channelId,
            channelUUID: join.channelUUID,
            joinGeneration: join.generation,
            tokenGeneration: token.generation,
            backendSessionId: backendSessionId
        )
    }

    mutating func finishRegistration(_ registration: PttEphemeralTokenRegistration, succeeded: Bool) {
        let key = RegistrationKey(
            joinGeneration: registration.joinGeneration,
            tokenGeneration: registration.tokenGeneration,
            backendSessionId: registration.backendSessionId
        )
        guard inFlight == key else { return }
        inFlight = nil
        guard succeeded,
              join?.generation == key.joinGeneration,
              join?.channelUUID == registration.channelUUID,
              token?.generation == key.tokenGeneration else { return }
        submitted = key
    }
}

@MainActor
protocol PushToTalkChannelControlling: AnyObject {
    var state: PushToTalkFrameworkState { get }
    var channelUUID: UUID? { get }
    var tokenRegistrationState: String { get }
    var lastError: String? { get }
    var onEphemeralToken: (@MainActor @Sendable (PttEphemeralTokenRegistration) async -> Bool)? { get set }
    var onBeginTransmitting: (@MainActor @Sendable (String) -> Void)? { get set }
    var onTransmitRequestDidBegin: (@MainActor @Sendable (String) -> Void)? { get set }
    var onEndTransmitting: (@MainActor @Sendable (String) -> Void)? { get set }
    var onAudioSessionActivated: (@MainActor @Sendable (AVAudioSession) async -> Void)? { get set }
    var onAudioSessionDeactivated: (@MainActor @Sendable (AVAudioSession) async -> Void)? { get set }
    var onTransmitFailure: (@MainActor @Sendable (PttTransmitFailure) -> Void)? { get set }
    var onRestoreRequested: (@MainActor @Sendable (PttRestoreDescriptor, RuntimeRestoreReason) -> Void)? { get set }
    var onIncomingPush: (@MainActor @Sendable (PttIncomingEvent) -> Void)? { get set }
    var onRemoteParticipantSetResult: (@MainActor @Sendable (RemoteParticipantSetResult) -> Void)? { get set }
    var canRestorePersistedChannel: (@MainActor @Sendable () -> Bool)? { get set }

    func initialize() async throws
    func join(channelId: String, channelName: String, canPublish: Bool, knownUsers: [String: String]) async throws
    func leave() async
    func requestBeginTransmitting()
    func stopTransmitting()
    func setRemoteSpeaker(sessionId: String?, name: String?, context: RemoteParticipantRequestContext) -> Int?
    func setServiceConnection(_ state: KOEONConnectionState)
    func markTokenRegistration(_ value: String)
    func setHeadsetPttEnabled(_ enabled: Bool)
    func updateBackendSessionId(_ sessionId: String)
    func requestRuntimeRestoreIfNeeded()
    @discardableResult func requestRuntimeRestoreForIncomingPush() -> Bool
    func clearRestoreContext()
    func currentIncomingEvent(channelId: String) -> PttIncomingEvent?
}

enum PushToTalkChannelUUID {
    static func make(channelId: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("koeon-channel:\(channelId)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))")!
    }
}

@MainActor
final class ApplePushToTalkController: NSObject, ObservableObject, PushToTalkChannelControlling {
    @Published private(set) var state: PushToTalkFrameworkState = .initializing
    @Published private(set) var channelUUID: UUID?
    @Published private(set) var tokenRegistrationState = "Not registered"
    @Published private(set) var lastError: String?
    @Published private(set) var systemChannelRestored = false
    @Published private(set) var restoreState = "not_required"
    @Published private(set) var lastIncomingPushAt: Date?
    @Published private(set) var lastIncomingPushLeaseId: String?
    @Published private(set) var lastTransmitRequestSource = "unknown"
    @Published private(set) var accessoryButtonEventsEnabled = false
    @Published private(set) var headsetPttEnabled: Bool
    @Published private(set) var handsfreeBeginCount = 0
    @Published private(set) var handsfreeEndCount = 0
    @Published private(set) var lastHandsfreeBeginAt: Date?
    @Published private(set) var lastHandsfreeEndAt: Date?
    @Published private(set) var genericMfbSupportState = "GENERIC_MFB_NOT_TESTED"

    var onEphemeralToken: (@MainActor @Sendable (PttEphemeralTokenRegistration) async -> Bool)?
    var onBeginTransmitting: (@MainActor @Sendable (String) -> Void)?
    var onTransmitRequestDidBegin: (@MainActor @Sendable (String) -> Void)?
    var onEndTransmitting: (@MainActor @Sendable (String) -> Void)?
    var onAudioSessionActivated: (@MainActor @Sendable (AVAudioSession) async -> Void)?
    var onAudioSessionDeactivated: (@MainActor @Sendable (AVAudioSession) async -> Void)?
    var onTransmitFailure: (@MainActor @Sendable (PttTransmitFailure) -> Void)?
    var onRestoreRequested: (@MainActor @Sendable (PttRestoreDescriptor, RuntimeRestoreReason) -> Void)?
    var onIncomingPush: (@MainActor @Sendable (PttIncomingEvent) -> Void)?
    var onRemoteParticipantSetResult: (@MainActor @Sendable (RemoteParticipantSetResult) -> Void)?
    var canRestorePersistedChannel: (@MainActor @Sendable () -> Bool)?

    private var manager: PTChannelManager?
    private var channelId: String?
    private var channelName = "KOEON"
    private var canPublish = false
    private var tokenLifecycle = ApplePttTokenLifecycle()
    private var backendSessionId: String?
    private var joinContinuation: CheckedContinuation<Void, Error>?
    private var leaveContinuation: CheckedContinuation<Void, Never>?
    private var audioSessionIsActive = false
    private var beginPendingForAudio = false
    private var remoteParticipantRequestSequence = 0
    private let defaults: UserDefaults
    nonisolated private let incomingState = PttIncomingReplayProtector()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        headsetPttEnabled = defaults.bool(forKey: "ptt.headset.enabled")
        super.init()
    }

    func initialize() async throws {
        if manager != nil { return }
        state = .initializing
        do {
            manager = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self)
            guard let manager else { throw PushToTalkControllerError.notInitialized }
            if let restoredUUID = manager.activeChannelUUID {
                let descriptor = PttRestoreDescriptor.load(from: defaults)
                guard shouldPreserveRestoredPttChannel(
                    restoredUUID: restoredUUID,
                    descriptor: descriptor,
                    credentialAvailable: canRestorePersistedChannel?() == true
                ), let descriptor else {
                    manager.leaveChannel(channelUUID: restoredUUID)
                    PttRestoreDescriptor.clear(from: defaults)
                    state = .ready
                    restoreState = "rejected_missing_context"
                    return
                }
                applyRestoredDescriptor(descriptor)
                try await configureTransmissionMode(manager: manager, uuid: restoredUUID)
                try await configureAccessoryButtonEvents(manager: manager, uuid: restoredUUID)
                onRestoreRequested?(descriptor, .systemChannelRestoration)
            } else {
                state = .ready
                restoreState = "not_required"
            }
        } catch {
            state = .unavailable
            lastError = safeMessage(error)
            throw error
        }
    }

    func join(channelId: String, channelName: String, canPublish: Bool, knownUsers: [String: String]) async throws {
        _ = knownUsers // v2 incoming push no longer depends on a local User cache.
        try await initialize()
        guard let manager else { throw PushToTalkControllerError.notInitialized }
        let uuid = PushToTalkChannelUUID.make(channelId: channelId)
        tokenLifecycle.beginJoin(channelId: channelId, channelUUID: uuid)
        self.channelId = channelId
        self.channelName = channelName
        self.channelUUID = uuid
        self.canPublish = canPublish
        PttRestoreDescriptor(
            channelId: channelId,
            channelName: channelName,
            channelUUID: uuid,
            canPublish: canPublish,
            lastBackendSessionId: backendSessionId
        ).persist(to: defaults)

        if manager.activeChannelUUID == uuid {
            state = .joined
            tokenLifecycle.didJoin(channelUUID: uuid)
            try await configureTransmissionMode(manager: manager, uuid: uuid)
            try await configureAccessoryButtonEvents(manager: manager, uuid: uuid)
            await submitTokenIfPossible()
            return
        }

        state = .joining
        try await withCheckedThrowingContinuation { continuation in
            joinContinuation = continuation
            manager.requestJoinChannel(
                channelUUID: uuid,
                descriptor: PTChannelDescriptor(name: channelName, image: nil)
            )
        }
        try await configureTransmissionMode(manager: manager, uuid: uuid)
        try await configureAccessoryButtonEvents(manager: manager, uuid: uuid)
        await submitTokenIfPossible()
    }

    func leave() async {
        if let manager, let uuid = channelUUID {
            try? await manager.setAccessoryButtonEventsEnabled(false, channelUUID: uuid)
            accessoryButtonEventsEnabled = false
        }
        guard let manager, let uuid = channelUUID, manager.activeChannelUUID == uuid else {
            if let uuid = channelUUID { tokenLifecycle.didLeave(channelUUID: uuid) }
            resetChannelState()
            return
        }
        state = .leaving
        await withCheckedContinuation { continuation in
            leaveContinuation = continuation
            manager.leaveChannel(channelUUID: uuid)
        }
    }

    func requestBeginTransmitting() {
        guard canPublish, state == .joined, let manager, let channelUUID else { return }
        manager.requestBeginTransmitting(channelUUID: channelUUID)
    }

    func stopTransmitting() {
        guard let manager, let channelUUID else { return }
        manager.stopTransmitting(channelUUID: channelUUID)
    }

    func setRemoteSpeaker(
        sessionId: String?,
        name: String?,
        context: RemoteParticipantRequestContext
    ) -> Int? {
        guard state == .joined, let manager, let channelUUID else { return nil }
        remoteParticipantRequestSequence += 1
        let requestId = remoteParticipantRequestSequence
        let participant: PTParticipant?
        if let sessionId, !sessionId.isEmpty,
           let trustedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trustedName.isEmpty {
            participant = PTParticipant(name: trustedName, image: nil)
        } else {
            participant = nil
        }
        manager.setActiveRemoteParticipant(participant, channelUUID: channelUUID) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let errorCode = error.map { self.safeMessage($0) }
                if let errorCode { self.lastError = errorCode }
                self.onRemoteParticipantSetResult?(RemoteParticipantSetResult(
                    requestId: requestId,
                    context: context,
                    errorCode: errorCode
                ))
            }
        }
        return requestId
    }

    func setServiceConnection(_ connection: KOEONConnectionState) {
        guard state == .joined, let manager, let channelUUID else { return }
        let status: PTServiceStatus = switch connection {
        case .connected: .ready
        case .connecting, .reconnecting: .connecting
        case .disconnected: .unavailable
        }
        manager.setServiceStatus(status, channelUUID: channelUUID) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = self?.safeMessage(error) }
        }
    }

    func markTokenRegistration(_ value: String) { tokenRegistrationState = value }

    func setHeadsetPttEnabled(_ enabled: Bool) {
        headsetPttEnabled = enabled
        if enabled, handsfreeBeginCount == 0 {
            genericMfbSupportState = "GENERIC_MFB_NOT_SUPPORTED_BY_APPLE_PTT_IF_NO_CALLBACK"
        } else if !enabled {
            genericMfbSupportState = "DISABLED"
        }
        defaults.set(enabled, forKey: "ptt.headset.enabled")
        guard let manager, let channelUUID, state == .joined else {
            accessoryButtonEventsEnabled = false
            return
        }
        Task {
            do { try await configureAccessoryButtonEvents(manager: manager, uuid: channelUUID) }
            catch { lastError = "Accessory PTT configuration failed: \(safeMessage(error))" }
        }
    }

    func updateBackendSessionId(_ sessionId: String) {
        backendSessionId = sessionId
        if var descriptor = PttRestoreDescriptor.load(from: defaults) {
            descriptor.lastBackendSessionId = sessionId
            descriptor.persist(to: defaults)
        }
        Task { await submitTokenIfPossible() }
    }

    func requestRuntimeRestoreIfNeeded() {
        guard systemChannelRestored, let descriptor = PttRestoreDescriptor.load(from: defaults) else { return }
        onRestoreRequested?(descriptor, .systemChannelRestoration)
    }

    @discardableResult
    func requestRuntimeRestoreForIncomingPush() -> Bool {
        guard let descriptor = PttRestoreDescriptor.load(from: defaults) else { return false }
        onRestoreRequested?(descriptor, .incomingPushColdWake)
        return true
    }

    func clearRestoreContext() { PttRestoreDescriptor.clear(from: defaults) }

    func currentIncomingEvent(channelId: String) -> PttIncomingEvent? {
        incomingState.currentEvent(channelId: channelId)
    }

    private func applyRestoredDescriptor(_ descriptor: PttRestoreDescriptor) {
        channelId = descriptor.channelId
        channelName = descriptor.channelName
        channelUUID = descriptor.channelUUID
        canPublish = descriptor.canPublish
        backendSessionId = descriptor.lastBackendSessionId
        tokenLifecycle.restoreJoined(channelId: descriptor.channelId, channelUUID: descriptor.channelUUID)
        state = .joined
        systemChannelRestored = true
        restoreState = "runtime_restore_requested"
    }

    private func configureTransmissionMode(manager: PTChannelManager, uuid: UUID) async throws {
        try await manager.setTransmissionMode(canPublish ? .halfDuplex : .listenOnly, channelUUID: uuid)
    }

    private func configureAccessoryButtonEvents(manager: PTChannelManager, uuid: UUID) async throws {
        let enabled = shouldEnablePttAccessoryEvents(
            settingEnabled: headsetPttEnabled,
            canPublish: canPublish,
            frameworkState: state
        )
        try await manager.setAccessoryButtonEventsEnabled(enabled, channelUUID: uuid)
        accessoryButtonEventsEnabled = enabled
    }

    private func submitTokenIfPossible() async {
        guard state == .joined,
              let registration = tokenLifecycle.claimRegistration(backendSessionId: backendSessionId) else { return }
        guard let onEphemeralToken else {
            tokenLifecycle.finishRegistration(registration, succeeded: false)
            return
        }
        let succeeded = await onEphemeralToken(registration)
        tokenLifecycle.finishRegistration(registration, succeeded: succeeded)
    }

    private func resetChannelState() {
        state = manager == nil ? .initializing : .ready
        channelUUID = nil
        channelId = nil
        canPublish = false
        // The lifecycle gate keeps a same-UUID token in memory only. A future
        // join to a different UUID discards it before registration.
        backendSessionId = nil
        tokenRegistrationState = "Not registered"
        audioSessionIsActive = false
        beginPendingForAudio = false
        systemChannelRestored = false
        restoreState = "not_required"
        accessoryButtonEventsEnabled = false
        incomingState.setLocalTransmitting(false)
        PttRestoreDescriptor.clear(from: defaults)
    }

    private func safeMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }

    private static func sourceLabel(_ source: PTChannelTransmitRequestSource) -> String {
        switch source {
        case .userRequest: "userRequest"
        case .developerRequest: "developerRequest"
        case .handsfreeButton: "handsfreeButton"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
}

extension ApplePushToTalkController: PTChannelRestorationDelegate {
    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        let name = PttRestoreDescriptor.load(from: .standard)?.channelName ?? "KOEON"
        return PTChannelDescriptor(name: name, image: nil)
    }
}

extension ApplePushToTalkController: PTChannelManagerDelegate {
    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didJoinChannel channelUUID: UUID,
        reason: PTChannelJoinReason
    ) {
        Task { @MainActor in
            state = .joined
            tokenLifecycle.didJoin(channelUUID: channelUUID)
            joinContinuation?.resume()
            joinContinuation = nil
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        Task { @MainActor in
            leaveContinuation?.resume()
            leaveContinuation = nil
            tokenLifecycle.didLeave(channelUUID: channelUUID)
            resetChannelState()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        Task { @MainActor in
            tokenLifecycle.receivedToken(pushToken, activeChannelUUID: channelManager.activeChannelUUID)
            await submitTokenIfPossible()
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didBeginTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        incomingState.setLocalTransmitting(true)
        Task { @MainActor in
            let label = Self.sourceLabel(source)
            lastTransmitRequestSource = label
            onTransmitRequestDidBegin?(label)
            if label == "handsfreeButton" {
                handsfreeBeginCount += 1
                lastHandsfreeBeginAt = Date()
                genericMfbSupportState = "APPLE_PTT_HANDSFREE_CALLBACK_RECEIVED"
            }
            if audioSessionIsActive { onBeginTransmitting?(label) }
            else { beginPendingForAudio = true }
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didEndTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        incomingState.setLocalTransmitting(false)
        Task { @MainActor in
            let label = Self.sourceLabel(source)
            lastTransmitRequestSource = label
            if label == "handsfreeButton" {
                handsfreeEndCount += 1
                lastHandsfreeEndAt = Date()
                genericMfbSupportState = "APPLE_PTT_HANDSFREE_CALLBACK_RECEIVED"
            }
            beginPendingForAudio = false
            onEndTransmitting?(label)
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            audioSessionIsActive = true
            await onAudioSessionActivated?(audioSession)
            if beginPendingForAudio {
                beginPendingForAudio = false
                onBeginTransmitting?(lastTransmitRequestSource)
            }
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            audioSessionIsActive = false
            await onAudioSessionDeactivated?(audioSession)
        }
    }

    nonisolated func incomingPushResult(
        channelManager: PTChannelManager,
        channelUUID: UUID,
        pushPayload: [String: Any]
    ) -> PTPushResult {
        guard let descriptor = PttRestoreDescriptor.load(from: .standard),
              descriptor.channelUUID == channelUUID,
              let incomingEvent = PttIncomingPayloadValidator.validate(pushPayload, expectedChannelId: descriptor.channelId)
        else { return .leaveChannel }
        // APNs registration rotation is best-effort. A stale same-device
        // registration must never preempt the current local transmission.
        guard !isSelfOriginatedIncomingPush(incomingEvent, currentSessionId: descriptor.lastBackendSessionId) else {
            return .leaveChannel
        }
        let accepted = incomingState.accept(incomingEvent)
        guard let event = accepted ? incomingEvent : incomingState.currentEvent(channelId: descriptor.channelId)
        else { return .leaveChannel }

        if incomingState.localTransmitIsActive() {
            // Required for half-duplex: batch local stop with remote activation.
            channelManager.stopTransmitting(channelUUID: channelUUID)
            incomingState.setLocalTransmitting(false)
        }
        if accepted {
            Task { @MainActor in
                lastIncomingPushAt = Date()
                lastIncomingPushLeaseId = String(event.leaseId.prefix(8))
                onIncomingPush?(event)
            }
        }
        return .activeRemoteParticipant(PTParticipant(name: event.speakerDisplayName, image: nil))
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToJoinChannel channelUUID: UUID,
        error: Error
    ) {
        Task { @MainActor in
            state = .error
            lastError = safeMessage(error)
            tokenLifecycle.didLeave(channelUUID: channelUUID)
            joinContinuation?.resume(throwing: error)
            joinContinuation = nil
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToLeaveChannel channelUUID: UUID,
        error: Error
    ) {
        Task { @MainActor in
            lastError = safeMessage(error)
            leaveContinuation?.resume()
            leaveContinuation = nil
            tokenLifecycle.didLeave(channelUUID: channelUUID)
            resetChannelState()
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToBeginTransmittingInChannel channelUUID: UUID,
        error: Error
    ) {
        incomingState.setLocalTransmitting(false)
        let failure = ApplePttErrorClassifier.classify(error, operation: .begin)
        Task { @MainActor in
            beginPendingForAudio = false
            if !failure.recoverable { lastError = failure.message }
            onTransmitFailure?(failure)
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToStopTransmittingInChannel channelUUID: UUID,
        error: Error
    ) {
        incomingState.setLocalTransmitting(false)
        let failure = ApplePttErrorClassifier.classify(error, operation: .stop)
        Task { @MainActor in
            if !failure.recoverable { lastError = failure.message }
            onTransmitFailure?(failure)
        }
    }
}

private enum PushToTalkControllerError: LocalizedError {
    case notInitialized
    var errorDescription: String? { "Apple PushToTalk channel manager is unavailable." }
}
