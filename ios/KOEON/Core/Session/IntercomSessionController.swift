import Combine
import AudioToolbox
import AVFoundation
import Foundation
import CryptoKit
import LiveKit
import UIKit

func shouldUseBoundedBackgroundCleanup(transmitSource: String, appLifecycleState: String) -> Bool {
    transmitSource == "handsfreeButton" || appLifecycleState != "active"
}

func isTerminalRuntimeRestoreError(_ error: Error) -> Bool {
    guard let apiError = error as? APIClientError,
          case let .http(status, _) = apiError else { return false }
    return status == 401 || status == 403 || status == 404
}

/// A response describes the state at request time, not a later RX/TX generation.
@MainActor
func withCurrentFloorStatus<Context: Equatable>(
    context: () -> Context,
    request: () async throws -> FloorResponse,
    apply: (FloorResponse) async -> Void
) async throws -> Bool {
    let requestedContext = context()
    let floor = try await request()
    guard !Task.isCancelled, requestedContext == context() else { return false }
    await apply(floor)
    return true
}

private struct FloorStatusContext: Equatable {
    let sessionId: String?
    let runtime: Int
    let txAttempt: Int
    let rxGeneration: Int
}

let postCallStableMilliseconds = 500

func shouldFinishPostCallRecovery(onAppleActivation state: AudioAvailabilityState) -> Bool {
    state == .recovering
}

func shouldSafetyStopForAppleDeactivation(
    gateState: PttRequestGateState,
    pttState: PTTState,
    nextBeginIsRearmingPreviousRelease: Bool = false
) -> Bool {
    if gateState == .beginRequested, nextBeginIsRearmingPreviousRelease { return false }
    let expectedEnd = gateState == .endRequested || gateState == .rearming
    return !expectedEnd && (pttState == .transmitting || pttState == .requestingFloor)
}

enum IncomingPushRuntimeAction: String, Sendable {
    case useWarmRuntime = "WARM_RUNTIME"
    case awaitReconnectThenResume = "AWAIT_RECONNECT_THEN_RESUME"
    case resumeImmediately = "RESUME_IMMEDIATELY"
}

func isConfirmedDeviceCredentialFailure(_ error: Error) -> Bool {
    guard case let APIClientError.http(status, body) = error, status == 401,
          let data = body.data(using: .utf8),
          let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let detail = envelope["error"] as? [String: Any],
          let code = detail["code"] as? String else { return false }
    return ["DEVICE_CREDENTIAL_INVALID", "DEVICE_CREDENTIAL_EXPIRED"].contains(code)
}

func shouldRestoreExpiredBackendSession(
    _ error: Error, requestedSessionId: String, currentSessionId: String?, poweredOn: Bool
) -> Bool {
    guard poweredOn, requestedSessionId == currentSessionId,
          case let APIClientError.http(status, body) = error, status == 401,
          let data = body.data(using: .utf8),
          let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let detail = envelope["error"] as? [String: Any] else { return false }
    return detail["code"] as? String == "SESSION_INVALID"
}

enum RuntimeRestoreReason: String, Sendable {
    case rxSelfHeal = "RX_SELF_HEAL"
    case backendSessionExpired = "BACKEND_SESSION_EXPIRED"
    case incomingPushColdWake = "INCOMING_PUSH_COLD_WAKE"
    case foregroundRecovery = "FOREGROUND_RECOVERY"
    case systemChannelRestoration = "SYSTEM_CHANNEL_RESTORATION"
}

enum RuntimeRestoreEntryDecision: String, Sendable {
    case useConnectedRuntime = "USE_CONNECTED_RUNTIME"
    case performFreshResume = "PERFORM_FRESH_RESUME"
}

struct RuntimeRestoreSingleFlightGate: Sendable {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func finish() {
        isActive = false
    }
}

func runtimeRestoreEntryDecision(
    reason: RuntimeRestoreReason,
    hasJoinedRuntime: Bool,
    connectionState: KOEONConnectionState,
    runtimeDirty: Bool = false
) -> RuntimeRestoreEntryDecision {
    // Once the Apple incoming-Push path has classified this runtime as a cold
    // wake, a stale SDK `.connected` snapshot must not cancel the fresh resume.
    if runtimeDirty || reason == .incomingPushColdWake || reason == .rxSelfHeal || reason == .backendSessionExpired { return .performFreshResume }
    return hasJoinedRuntime && connectionState == .connected
        ? .useConnectedRuntime
        : .performFreshResume
}

func canUseFastColdReconnect(
    cached: JoinResponse?,
    descriptor: PttRestoreDescriptor,
    now: Date = Date(),
    expirySafetyMargin: TimeInterval = 30
) -> Bool {
    guard let cached,
          cached.sessionId == descriptor.lastBackendSessionId,
          cached.channel.id == descriptor.channelId,
          let expiresAt = cached.tokenExpiresAt,
          expiresAt.timeIntervalSince(now) > expirySafetyMargin else { return false }
    return true
}

@MainActor
func performFreshRuntimeRestore<Response>(
    requestFreshSession: () async throws -> Response,
    onFreshSessionReceived: (Response) -> Void,
    teardownStaleRuntime: () async -> Void,
    establishFreshRuntime: (Response) async -> Bool,
    discardFreshSession: (Response) async -> Void = { _ in }
) async throws -> Bool {
    try Task.checkCancellation()
    let response = try await requestFreshSession()
    do {
        try Task.checkCancellation()
        onFreshSessionReceived(response)
        await teardownStaleRuntime()
        try Task.checkCancellation()
        return await establishFreshRuntime(response)
    } catch {
        await discardFreshSession(response)
        throw error
    }
}

func incomingPushRuntimeAction(
    hasJoinedRuntime: Bool,
    connectionState: KOEONConnectionState,
    appLifecycleState: String,
    runtimeDirty: Bool = false
) -> IncomingPushRuntimeAction {
    guard hasJoinedRuntime else { return .resumeImmediately }
    switch connectionState {
    case .connected:
        return !runtimeDirty && appLifecycleState == "active" ? .useWarmRuntime : .awaitReconnectThenResume
    case .connecting, .reconnecting: return .awaitReconnectThenResume
    case .disconnected: return .resumeImmediately
    }

}

// Runtime replacement and incoming wake exclusively own recovery while pending.
func shouldDeferRxRecovery(runtimeRestoring: Bool, incomingWakePending: Bool) -> Bool {
    runtimeRestoring || incomingWakePending
}


func incomingMatchesStart(_ incoming: PttIncomingEvent, _ event: PttControlEvent?) -> Bool {
    guard let event else { return false }
    return event.type == "start" &&
        event.channelId == incoming.channelId && event.sessionId == incoming.speakerSessionId &&
        event.speakerUserId == incoming.speakerUserId && event.leaseId == incoming.leaseId
}

enum ForegroundRuntimeRecoveryAction: String, Sendable {
    case noJoinedRuntime = "NO_JOINED_RUNTIME"
    case keepConnectedRuntime = "KEEP_CONNECTED_RUNTIME"
    case awaitExistingReconnect = "AWAIT_EXISTING_RECONNECT"
    case requestPersistedRuntimeRestore = "REQUEST_PERSISTED_RUNTIME_RESTORE"
}

func foregroundRuntimeRecoveryAction(
    hasJoinedRuntime: Bool,
    connectionState: KOEONConnectionState
) -> ForegroundRuntimeRecoveryAction {
    guard hasJoinedRuntime else { return .noJoinedRuntime }
    switch connectionState {
    case .connected: return .keepConnectedRuntime
    case .connecting, .reconnecting: return .awaitExistingReconnect
    case .disconnected: return .requestPersistedRuntimeRestore
    }
}

func shouldIgnoreLateStopFailure(
    operation: PttTransmitOperation,
    gateState: PttRequestGateState,
    previousDidEndAt: Date?,
    nextPttDownAt: Date?
) -> Bool {
    guard operation == .stop,
          gateState == .beginRequested,
          let previousDidEndAt,
          let nextPttDownAt else { return false }
    return nextPttDownAt >= previousDidEndAt
}

func pairedDurationMilliseconds(
    start: Date?,
    end: Date?,
    startGeneration: Int?,
    endGeneration: Int?
) -> Int? {
    guard let start, let end, let startGeneration, startGeneration == endGeneration else { return nil }
    return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
}

struct ReconnectAttemptDiagnostic: Sendable {
    let id: Int
    let startedAt: Date
    let reason: String
    var completedAt: Date?
    var result: String?

    var durationMilliseconds: Int? {
        guard let completedAt else { return nil }
        return max(0, Int((completedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
    }
}

/// Process-lifetime coldness is not cleared by a transient UIApplication active callback.
struct RuntimeLiveness: Sendable {
    private(set) var dirty = true
    private(set) var generation = 0
    private(set) var validatedGeneration = 0
    private(set) var lastValidatedAt: Date?
    mutating func invalidate() { dirty = true }
    mutating func beginRuntime() { generation += 1; dirty = true }
    mutating func validate(bindingsReady: Bool, at: Date = Date()) {
        guard bindingsReady else { return }
        dirty = false
        validatedGeneration = generation
        lastValidatedAt = at
    }
}

struct LifecycleAttemptRecord: Codable, Sendable {
    let attemptId: Int
    let generation: Int
    let channelHash: String
    let sessionGeneration: Int
    let startedAt: Date
    var completedAt: Date?
}

struct LifecycleAttemptLedger: Sendable {
    private(set) var current: LifecycleAttemptRecord?
    private(set) var lastCompleted: LifecycleAttemptRecord?
    private var sequence = 0
    mutating func begin(generation: Int, channelId: String, sessionGeneration: Int, at: Date = Date()) {
        finish(at: at)
        sequence += 1
        current = LifecycleAttemptRecord(attemptId: sequence, generation: generation,
            channelHash: SHA256.hash(data: Data(channelId.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined(),
            sessionGeneration: sessionGeneration, startedAt: at)
    }
    mutating func finish(at: Date = Date()) {
        guard var completed = current else { return }
        completed.completedAt = at
        lastCompleted = completed
        current = nil
    }
}

enum AppTxPath: String, CaseIterable { case prearmFast = "PREARM_FAST", postBeginControl = "POST_BEGIN_CONTROL" }
enum RxReadyPolicy: String, CaseIterable { case off = "OFF", fast250 = "FAST_250", adaptive = "ADAPTIVE" }
enum RestorePath: String, CaseIterable { case fastResume = "FAST_RESUME", legacySerial = "LEGACY_SERIAL" }
enum RxStartCueMode: String, CaseIterable { case on = "ON", off = "OFF" }
enum IOSVolumeProbeMode: String, CaseIterable { case off = "OFF", observeOnly = "OBSERVE ONLY" }

enum AudioPublishProfile: String, CaseIterable, Sendable {
    case telephone12k = "TELEPHONE_12K"
    case speech24k = "SPEECH_24K"
    case highQuality48k = "HIGH_QUALITY_48K"

    static let persistenceKey = "koeon.audioPublishProfile"

    var displayName: String {
        switch self {
        case .telephone12k: "低帯域 12 kbps"
        case .speech24k: "標準 24 kbps"
        case .highQuality48k: "高音質 48 kbps"
        }
    }

    var liveKitEncoding: AudioEncoding {
        switch self {
        case .telephone12k: .presetTelephone
        case .speech24k: .presetSpeech
        case .highQuality48k: .presetMusic
        }
    }

    var maxBitrate: Int { liveKitEncoding.maxBitrate }

    static func load(from defaults: UserDefaults) -> AudioPublishProfile {
        guard let stored = defaults.string(forKey: persistenceKey),
              let profile = AudioPublishProfile(rawValue: stored) else { return .speech24k }
        return profile
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.persistenceKey)
    }
}

func audioPublishProfileForConnection(
    selected: AudioPublishProfile,
    applied: AudioPublishProfile?
) -> AudioPublishProfile {
    applied ?? selected
}

struct AppPttTouchEdgeGate: Sendable {
    private(set) var isPressed = false

    mutating func changed() -> Bool {
        guard !isPressed else { return false }
        isPressed = true
        return true
    }

    mutating func ended() -> Bool {
        guard isPressed else { return false }
        isPressed = false
        return true
    }

    mutating func reset() {
        isPressed = false
    }
}

/// G6 deliberately ships no iOS volume-button PTT trigger. Observation never fabricates input.
func iosVolumeProbeCanTriggerPtt(
    mode: IOSVolumeProbeMode,
    foreground: Bool,
    joined: Bool,
    outputVolumeChanged: Bool
) -> Bool { false }

func shouldRequestAppleBeginAfterFloorGrant(
    attempt: Int,
    currentAttempt: Int,
    gateState: PttRequestGateState,
    releaseRequestedBeforeBegin: Bool,
    alreadyIssued: Bool
) -> Bool {
    attempt == currentAttempt &&
        gateState == .beginRequested &&
        !releaseRequestedBeforeBegin &&
        !alreadyIssued
}

/// User intent survives a temporary loss of the transport/session.
struct RuntimeRecoveryIntent: Sendable {
    private(set) var isPoweredOn = false
    private(set) var allowsRestoration = true // Allow Apple's persisted channel on cold launch.
    private(set) var retryAttempt = 0
    private(set) var descriptor: PttRestoreDescriptor?

    mutating func powerOn() {
        isPoweredOn = true
        allowsRestoration = true
        retryAttempt = 0
    }
    mutating func beginRestore(_ descriptor: PttRestoreDescriptor? = nil) -> Bool {
        guard allowsRestoration else { return false }
        if let descriptor { self.descriptor = descriptor }
        isPoweredOn = true
        return true
    }
    mutating func powerOff() {
        isPoweredOn = false
        allowsRestoration = false
        retryAttempt = 0
        descriptor = nil
    }
    mutating func resetRetries() { retryAttempt = 0 }
    mutating func nextRetryDelay(isForeground: Bool) -> Int? {
        guard isPoweredOn, allowsRestoration, isForeground, retryAttempt < 3 else { return nil }
        let delay = [1, 2, 4][retryAttempt]
        retryAttempt += 1
        return delay
    }
}

enum ActionButtonPttResult: Equatable {
    case startRequested, stopRequested, settling, disabled, unavailable
}

/// Stop takes precedence over readiness; repeated calls during release never queue TX.
func actionButtonPttDecision(enabled: Bool, state: PttRequestGateState,
                             eligible: Bool) -> ActionButtonPttResult {
    guard enabled else { return .disabled }
    switch state {
    case .beginRequested, .transmitting: return .stopRequested
    case .endRequested, .rearming: return .settling
    case .idle: return eligible ? .startRequested : .unavailable
    }
}

@MainActor
final class IntercomSessionController: ObservableObject {
    // One session owner for SwiftUI and system App Intents, including background launch.
    static let shared = IntercomSessionController()
    @Published private(set) var actionButtonPttEnabled = false
    private var actionButtonOwnsAttempt = false

    @Published private(set) var fixture: FixtureResponse?
    @Published private(set) var identity: MeResponse?
    @Published private(set) var enrollmentRequired = false
    @Published var selectedUserId: String?
    @Published var selectedChannelId: String?
    @Published private(set) var recoveryIntent = RuntimeRecoveryIntent()
    @Published private(set) var isRestoringRuntime = false
    private var runtimeRetryTask: Task<Void, Never>?
    private var isStoppingRuntime = false
    private var isJoiningRuntime = false
    @Published private(set) var joinedSession: JoinResponse?
    @Published private(set) var pttSnapshot = PTTSnapshot.initial(role: .staff)
    @Published private(set) var lastReleaseSnapshot = PTTSnapshot.initial(role: .staff)
    @Published private(set) var rxSnapshot = RxSnapshot()
    @Published private(set) var remoteReceiveSnapshot = RemoteReceiveActivationSnapshot()
    @Published private(set) var rxConsistencySnapshot = RxConsistencySnapshot()
    @Published private(set) var rxDivergenceDiagnostics: [RxDivergenceDiagnostic] = []
    @Published private(set) var hapticSnapshot = HapticSnapshot()
    @Published private(set) var sessionUptimeSeconds = 0
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var operationalState: OperationalState = .unenrolled
    @Published private(set) var appLifecycleState = "active"
    @Published private(set) var pttRestoreState = "not_required"
    @Published private(set) var pttRestoreStartedAt: Date?
    @Published private(set) var pttRestoreCompletedAt: Date?
    @Published private(set) var pttRestoreMilliseconds: Int?
    @Published private(set) var backgroundTaskState = "idle"
    @Published private(set) var pttRequestGateState: PttRequestGateState = .idle
    @Published private(set) var lastStatusCueResult = "Not played"
    @Published private(set) var postCallRearmState: PostCallRearmState = .ready
    @Published private(set) var rxPath = "warm"
    @Published private(set) var appleBeginRequestedAt: Date?
    @Published private(set) var appleDidBeginAt: Date?
    @Published private(set) var appleDidActivateAt: Date?
    @Published private(set) var appleDidBeginAttemptGeneration: Int?
    @Published private(set) var appleDidActivateAttemptGeneration: Int?
    @Published private(set) var appleLastEndAt: Date?
    @Published private(set) var appleLastEndSource: String?
    @Published private(set) var appleLastDeactivateAt: Date?
    @Published private(set) var appleLastTransmitFailureAt: Date?
    @Published private(set) var appleLastTransmitFailureOperation: String?
    @Published private(set) var appleLastTransmitFailureCode: String?
    @Published private(set) var appleLastTransmitFailureRecoverable: Bool?
    @Published private(set) var lastBackgroundAt: Date?
    @Published private(set) var lastForegroundAt: Date?
    @Published private(set) var lastPttIncomingPushAt: Date?
    @Published private(set) var pttChannelRestoredAt: Date?
    @Published private(set) var liveKitReconnectStartedAt: Date?
    @Published private(set) var liveKitReconnectCompletedAt: Date?
    @Published private(set) var reconnectAttempt: ReconnectAttemptDiagnostic?
    @Published private(set) var rxWakeGeneration = 0
    @Published private(set) var rxWakeSource = "none"
    @Published private(set) var rxWakeFailureStage: String?
    @Published private(set) var runtimeRestoreReason = "none"
    @Published private(set) var runtimeRestoreDecision = "none"
    @Published private(set) var runtimeRestorePath = "NONE"
    @Published private(set) var runtimeRestoreEarlyExitReason = "none"
    @Published private(set) var roomConnectionStateAtIncomingPush = "none"
    @Published private(set) var roomConnectionStateAtRestoreEntry = "none"
    @Published private(set) var joinedSessionPresentAtRestoreEntry = false
    @Published private(set) var staleRuntimeTeardownStartedAt: Date?
    @Published private(set) var staleRuntimeTeardownCompletedAt: Date?
    @Published private(set) var liveKitEngineReadyAt: Date?
    @Published private(set) var appleStopRequestedAt: Date?
    @Published private(set) var requestGateIdleAt: Date?
    @Published private(set) var audioRearmedAt: Date?
    @Published private(set) var readyAt: Date?
    @Published private(set) var nextPttDownAt: Date?
    @Published private(set) var resumeRequestAt: Date?
    @Published private(set) var resumeResponseAt: Date?
    @Published private(set) var resumeLiveKitConnectStartedAt: Date?
    @Published private(set) var resumeLiveKitConnectedAt: Date?
    @Published var appTxPath: AppTxPath = .prearmFast { didSet { persistFieldLab() } }
    @Published var rxReadyPolicy: RxReadyPolicy = .adaptive { didSet { persistFieldLab() } }
    @Published var restorePath: RestorePath = .fastResume { didSet { persistFieldLab() } }
    @Published var rxStartCueMode: RxStartCueMode = .on { didSet { persistFieldLab(); rx?.setStartCueEnabled(rxStartCueMode == .on) } }
    @Published var volumeProbeMode: IOSVolumeProbeMode = .off {
        didSet { persistFieldLab(); audio.setOutputVolumeObservationEnabled(volumeProbeMode == .observeOnly) }
    }
    @Published private(set) var selectedAudioPublishProfile: AudioPublishProfile = .speech24k
    @Published private(set) var appliedAudioPublishProfile: AudioPublishProfile?
    @Published private(set) var fieldDiagnosticCopyResult = "Not copied"
    @Published private(set) var rxReadyStartReceivedAt: Date?
    @Published private(set) var rxReadyAppleAudioReadyAt: Date?
    @Published private(set) var rxReadyPublishAttemptedAt: Date?
    @Published private(set) var rxReadyPublishedAt: Date?
    @Published private(set) var rxReadyPublishResult = "NOT_ATTEMPTED"
    @Published private(set) var rxReadyPublishSessionIdGeneration: Int?
    @Published private(set) var rxReadyPublishDeviceIdPresent: Bool?

    let room: LiveKitRoomController
    let audio: AudioSessionController
    let network: ConnectionMonitor
    let pushToTalk: ApplePushToTalkController
    let inputGain = InputGainProcessor()

    private let api: any KOEONAPIClientProtocol
    private let credentialStore: any DeviceCredentialStoring
    private let deviceDisplayNameStore: any DeviceDisplayNameStoring
    private let audioPublishDefaults: UserDefaults
    private let cuePlayer: any PttCuePlaying
    private let rxCuePlayer: any PttCuePlaying
    private let statusCuePlayer: any PttStatusCuePlaying
    private var haptics: PttHapticFeedbackController?
    private var ptt: PTTController?
    private var rx: RxAudioController?
    private var remoteReceive: RemoteReceiveActivationCoordinator?
    private var rxConsistencyGuard = RxConsistencyGuard()
    private var rxDivergenceWatchdogTask: Task<Void, Never>?
    private var joinedAt: Date?
    private var appleTransmitAttemptGeneration = 0
    private var reconnectAttemptSequence = 0
    private var incomingPushLifecycleState: String?
    private var incomingPushRxGeneration: Int?
    private var appleActivateLifecycleState: String?
    private var appleActivateRxGeneration: Int?
    private var firstPcmLifecycleState: String?
    private var firstPcmRxGeneration: Int?
    private var uptimeTask: Task<Void, Never>?
    private var floorStatusTask: Task<Void, Never>?
    private var pttRequestGate = PttRequestGate()
    private var appPttTouchEdgeGate = AppPttTouchEdgeGate()
    private var pendingJoinResponse: JoinResponse?
    private var audioRecoveryTask: Task<Void, Never>?
    private var pttStoppedForAudioInterruption = false
    private var audioCancellable: AnyCancellable?
    private var switchGeneration = 0
    private var restoreTask: Task<Void, Never>?
    private var restoreSingleFlight = RuntimeRestoreSingleFlightGate()
    private var runtimeLiveness = RuntimeLiveness()
    private var rxRecoveryTask: Task<Void, Never>?
    private var rxRecoveryEvent: PttControlEvent?
    private var rxRecoveryRebuiltLease: String?
    private var rxTerminalFloorTask: Task<Void, Never>?
    private var remoteFloorBusy = false
    private var activationWatchdogTask: Task<Void, Never>?
    private var txAttempts = LifecycleAttemptLedger()
    private var rxAttempts = LifecycleAttemptLedger()
    private var wakeAttempts = LifecycleAttemptLedger()
    private var foregroundRecoveryPending = false
    private var lastForegroundRecoveryRequestedAt: Date?
    private var lastForegroundRecoveryCompletedAt: Date?
    private var lastForegroundRecoveryResult: String?

    private var appPrearmTask: Task<Void, Never>?
    private var appPrearmAwaitingApple = false
    private var appPrearmReady = false
    private var appAppleBeginReady = false
    private var appActivationCommitted = false
    private var appleBeginIssuedForAttempt = false
    private var txAttemptGeneration = 0
    private var releaseGeneration = 0
    private var releaseFloorCompleted = false
    private var releaseAppleCompleted = false
    private var pendingAppAppleStop = false
    private var releaseCleanupTask: Task<Void, Never>?
    private var incomingWakeRecoveryTask: Task<Void, Never>?
    private var receivedControlStart: (event: PttControlEvent, runtime: Int)?

    private let backgroundCleanup = BoundedBackgroundCleanup()

    private var journalRxPcmGate = FieldJournalRxPcmGate()
    @Published private(set) var fieldJournalURL: URL?
    @Published private(set) var fieldJournalExporting = false
    @Published private(set) var fieldJournalStatus = ""
    private var journalAudioSignature = ""
    private var journalHeartbeatAt: TimeInterval = 0

    private func journal(_ event: String, fields: [String: Any] = [:], lease: String? = nil, speaker: String? = nil) {
        var data: [String: Any] = ["ptt": pttSnapshot.state.rawValue.uppercased(),
            "rx": rxSnapshot.state.rawValue.uppercased(), "connection": room.connectionState.rawValue.uppercased(),
            "lifecycle": appLifecycleState.uppercased(), "runtimeGeneration": runtimeLiveness.generation,
            "receiveGeneration": rxSnapshot.generation, "route": audio.route.rawValue.uppercased().replacingOccurrences(of: "-", with: "_")]
        fields.forEach { data[$0.key] = $0.value }
        var ids: [String: String] = [:]
        ids["sessionHash"] = joinedSession?.sessionId
        ids["channelHash"] = joinedSession?.channel.id
        ids["leaseHash"] = lease ?? rxSnapshot.leaseId ?? pttSnapshot.leaseId
        ids["speakerSessionHash"] = speaker ?? rxSnapshot.sessionId
        FieldJournal.shared.record(event, fields: data, ids: ids)
    }

    func exportFieldJournal() {
        guard !fieldJournalExporting else { return }
        fieldJournalExporting = true; fieldJournalURL = nil; fieldJournalStatus = "Exporting…"
        journal("EXPORT")
        Task { [weak self] in
            do {
                let url = try await FieldJournal.shared.export()
                self?.fieldJournalURL = url; self?.fieldJournalStatus = "Ready to share (up to 24 hours)"
            } catch { self?.fieldJournalStatus = "Export failed; retry when storage is available" }
            self?.fieldJournalExporting = false
        }
    }

    init(
        api: (any KOEONAPIClientProtocol)? = nil,
        credentialStore: any DeviceCredentialStoring = KeychainDeviceCredentialStore(),
        deviceDisplayNameStore: any DeviceDisplayNameStoring = PersistentDeviceDisplayNameStore(),
        room: LiveKitRoomController? = nil,
        audio: AudioSessionController? = nil,
        network: ConnectionMonitor? = nil,
        cuePlayer: any PttCuePlaying = PttCuePlayer(policy: .transmitReady),
        rxCuePlayer: any PttCuePlaying = PttCuePlayer(policy: .receiveAndStatus),
        statusCuePlayer: any PttStatusCuePlaying = PttCuePlayer(policy: .receiveAndStatus),
        hapticPerformer: (any PttHapticPerforming)? = nil,
        pushToTalk: ApplePushToTalkController? = nil,
        audioPublishDefaults: UserDefaults = .standard
    ) {
        let room = room ?? LiveKitRoomController()
        let audio = audio ?? AudioSessionController()
        let network = network ?? ConnectionMonitor()
        let hapticPerformer = hapticPerformer ?? UIKitPttHapticPerformer()
        let pushToTalk = pushToTalk ?? ApplePushToTalkController()
        self.api = api ?? KOEONAPIClient(credentialStore: credentialStore)
        self.credentialStore = credentialStore
        self.deviceDisplayNameStore = deviceDisplayNameStore
        self.audioPublishDefaults = audioPublishDefaults
        actionButtonPttEnabled = audioPublishDefaults.bool(forKey: "ptt.actionButtonEnabled")
        self.room = room
        self.audio = audio
        self.network = network
        self.cuePlayer = cuePlayer
        self.rxCuePlayer = rxCuePlayer
        self.statusCuePlayer = statusCuePlayer
        self.pushToTalk = pushToTalk
        FieldJournal.shared.record("START")
        selectedAudioPublishProfile = AudioPublishProfile.load(from: audioPublishDefaults)
        appTxPath = AppTxPath(rawValue: UserDefaults.standard.string(forKey: "field.appTxPath") ?? "") ?? .prearmFast
        rxReadyPolicy = RxReadyPolicy(rawValue: UserDefaults.standard.string(forKey: "field.rxReadyPolicy") ?? "") ?? .adaptive
        restorePath = RestorePath(rawValue: UserDefaults.standard.string(forKey: "field.restorePath") ?? "") ?? .fastResume
        rxStartCueMode = RxStartCueMode(rawValue: UserDefaults.standard.string(forKey: "field.rxStartCue") ?? "") ?? .on
        volumeProbeMode = IOSVolumeProbeMode(rawValue: UserDefaults.standard.string(forKey: "field.volumeProbe") ?? "") ?? .off
        audio.setOutputVolumeObservationEnabled(volumeProbeMode == .observeOnly)
        AudioManager.shared.capturePostProcessingDelegate = inputGain

        audioCancellable = audio.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.inputGain.setRoute(self.audio.inputProfileKey)
                let journalSignature = "\(self.audio.route.rawValue)-\(self.audio.pushToTalkAudioSessionActive)"
                if self.journalAudioSignature != journalSignature {
                    self.journalAudioSignature = journalSignature
                    self.journal("AUDIO", fields: ["audio": self.audio.pushToTalkAudioSessionActive ? "ACTIVE" : "INACTIVE"])
                }
            }
        }
        inputGain.setRoute(audio.inputProfileKey)
        haptics = PttHapticFeedbackController(performer: hapticPerformer) { [weak self] snapshot in
            self?.hapticSnapshot = snapshot
        }
        haptics?.prepare()

        room.onUnsafeDisconnect = { [weak self] reason in
            guard let self else { return }
            self.runtimeLiveness.invalidate()
            // A transport failure is not the end of an Apple PTT reception.
            // The APNs response may have just activated it. Keep ownership
            // until drain/terminal cleanup
            // or the runtime replacement, which preserves Apple's participant.
            self.resetRxConsistency()
            let controller = self.ptt
            let runtime = self.runtimeLiveness.generation
            Task { [weak self] in
                guard self?.runtimeLiveness.generation == runtime else { return }
                await controller?.stopForSafety(reason: reason)
            }
        }
        room.onReconnected = { [weak self] in
            guard let self else { return }
            let controller = self.ptt
            let runtime = self.runtimeLiveness.generation
            Task { [weak self] in
                guard self?.runtimeLiveness.generation == runtime else { return }
                await controller?.resetAfterReconnect()
            }
        }
        room.onConnectionStateChanged = { [weak self] state in
            guard let self else { return }
            self.journal("CONNECTION", fields: ["connection": state.rawValue.uppercased()])
            if state != .connected { self.runtimeLiveness.invalidate() }
            self.pushToTalk.setServiceConnection(state)
            if state == .reconnecting {
                self.beginReconnectAttempt(reason: "livekit_reconnecting")
            } else if state == .connected {
                self.completeReconnectAttempt(result: "connected")
                if self.audio.pushToTalkAudioSessionActive { self.rx?.audioSessionDidActivate() }
            } else if state == .disconnected {
                self.completeReconnectAttempt(result: "disconnected")
                if self.restoreTask == nil { self.scheduleRuntimeRetry() }
            }
        }
        room.onPttControl = { [weak self] event, senderSessionId in
            guard event.bufferedGenerationId == nil else { return }
            if event.type == "start" { self?.rxReadyStartReceivedAt = Date() }
            self?.rx?.handleControl(event, senderSessionId: senderSessionId)

            if let self, event.type == "start",
               event.sessionId == senderSessionId, self.rx?.currentSnapshot().leaseId == event.leaseId,
               self.rx?.currentSnapshot().sessionId == event.sessionId {
                self.receivedControlStart = (event, self.runtimeLiveness.generation)
            }
            if self?.audio.pushToTalkAudioSessionActive == true {
                self?.rxReadyAppleAudioReadyAt = Date()
                self?.rx?.audioSessionDidActivate()
            }
        }
        room.onRemoteAudioActivity = { [weak self] senderSessionId, active in
            self?.handleRemoteMediaActivity(sessionId: senderSessionId, active: active)
        }
        room.onRemotePcm = { [weak self] timestamp in
            guard let self, self.rxRecoveryEvent?.bufferedGenerationId == nil,
                  let rx = self.rx, let sessionId = rx.currentSnapshot().sessionId else { return }
            guard rx.handleLiveKitRemotePcm(at: timestamp, subscriptionActive:
                self.room.isRemoteAudioSubscriptionActive(sessionId: sessionId,
                    generation: rx.currentSnapshot().generation)) else { return }
            self.remoteReceive?.handleRemotePcm()
            let currentRx = self.rx?.currentSnapshot() ?? RxSnapshot()
            self.applyRxSnapshot(currentRx)
            let pcmResult = self.rxConsistencyGuard.handleRemotePcm(
                sessionId: currentRx.sessionId,
                generation: currentRx.generation,
                at: timestamp
            )
            self.rxConsistencySnapshot = self.rxConsistencyGuard.snapshot
            if pcmResult == .recovered {
                self.appendRxDivergenceDiagnostic(
                    event: "rx_divergence_recovered",
                    elapsedMilliseconds: rxDivergenceWatchdogMilliseconds,
                    state: self.rxConsistencySnapshot
                )
            }
            self.scheduleRxDivergenceWatchdogIfNeeded()
            let generation = currentRx.generation
            if generation > 0, self.firstPcmRxGeneration != generation {
                self.firstPcmRxGeneration = generation
                self.firstPcmLifecycleState = self.appLifecycleState
            }
        }
        audio.onUnsafeInterruption = { [weak self] reason in
            guard let self else { return }
            self.postCallRearmState = .interrupted
            self.resetPttRequestGate()
            self.pushToTalk.stopTransmitting()
            Task {
                if let snapshot = await self.ptt?.currentSnapshot(),
                   snapshot.state == .transmitting || snapshot.state == .requestingFloor {
                    self.pttStoppedForAudioInterruption = true
                }
                await self.ptt?.stopForSafety(reason: reason)
            }
        }
        audio.onInterruptionEnded = { [weak self] generation in
            self?.recoverAudio(generation: generation)
        }
        audio.onRouteChanged = { [weak self] change in
            guard let self, change.lostExternalInputRoute else { return }
            Task {
                if let snapshot = await self.ptt?.currentSnapshot(),
                   shouldSafetyStopForRouteChange(
                       lostExternalInputRoute: change.lostExternalInputRoute,
                       pttState: snapshot.state
                   ) {
                    self.resetPttRequestGate()
                    self.pushToTalk.stopTransmitting()
                    await self.ptt?.stopForSafety(reason: "External audio route lost; TX stopped before microphone fallback.")
                    self.lastError = "External audio device disconnected during TX. Press PTT again to use the new route."
                }
            }
        }
        pushToTalk.canRestorePersistedChannel = { [credentialStore] in
            credentialStore.read() != nil
        }
        pushToTalk.onRestoreRequested = { [weak self] descriptor, reason in
            if reason == .systemChannelRestoration { self?.runtimeLiveness.invalidate() }
            self?.journal("RESTORE")
            self?.pttChannelRestoredAt = Date()
            self?.requestRuntimeRestore(descriptor, reason: reason)
        }
        pushToTalk.onIncomingPush = { [weak self] incoming in
            guard let self else { return }
            self.journal("WAKE")
            self.lastPttIncomingPushAt = Date()
            self.rxWakeGeneration += 1
            self.wakeAttempts.begin(generation: self.rxWakeGeneration, channelId: incoming.channelId,
                sessionGeneration: self.runtimeLiveness.generation)
            self.resetCurrentWakeDiagnostics()
            self.incomingPushLifecycleState = self.appLifecycleState
            self.rxWakeFailureStage = nil
            let wakeGeneration = self.rxWakeGeneration
            let runtimeAction = incomingPushRuntimeAction(
                hasJoinedRuntime: self.joinedSession != nil,
                connectionState: self.room.connectionState,
                appLifecycleState: self.appLifecycleState,
                runtimeDirty: self.runtimeLiveness.dirty
            )
            self.roomConnectionStateAtIncomingPush = self.room.connectionState.rawValue
            self.rxWakeSource = runtimeAction.rawValue
            self.rxPath = runtimeAction == .useWarmRuntime ? "warm" : "cold_resume"
            self.rx?.handleTrustedIncomingStart(incoming)
            self.incomingPushRxGeneration = self.rx?.currentSnapshot().generation
            self.scheduleIncomingPushRuntimeRecovery(runtimeAction, generation: wakeGeneration)
            Task {
                if let snapshot = await self.ptt?.currentSnapshot(),
                   snapshot.state == .transmitting || snapshot.state == .requestingFloor {
                    await self.ptt?.stopForSafety(reason: "Validated incoming remote PushToTalk preempted local TX.")
                }
            }
        }
        pushToTalk.onRemoteParticipantSetResult = { [weak self] result in
            guard let self else { return }
            if result.context.clearing {
                _ = self.remoteReceive?.handleParticipantSetResult(result)
                return
            }
            if result.errorCode != nil {
                Task {
                    do {
                        _ = try await self.room.discardRemoteAudioSubscription(
                            sessionId: result.context.sessionId, generation: result.context.generation
                        )
                        _ = self.remoteReceive?.handleParticipantSetResult(result)
                    } catch {
                        self.remoteReceive?.markMediaDiscardFailure(
                            generation: result.context.generation,
                            sessionId: result.context.sessionId,
                            leaseId: result.context.leaseId,
                            errorCode: "remote_audio_discard_failed"
                        )
                    }
                }
                return
            }
            let becamePlaybackReady = self.remoteReceive?.handleParticipantSetResult(result) == true
            if becamePlaybackReady,
                      self.audio.pushToTalkAudioSessionActive,
                      self.audio.liveKitEngineAvailability == "DEFAULT" {
                self.activateRemoteReceiveAudio(AVAudioSession.sharedInstance())
            }
        }
        pushToTalk.onEphemeralToken = { [weak self] registration in
            guard let self,
                  let response = self.joinedSession ?? self.pendingJoinResponse,
                  response.sessionId == registration.backendSessionId,
                  response.channel.id == registration.channelId else { return false }
            do {
                try await self.api.registerPttToken(
                    sessionId: response.sessionId,
                    channelId: response.channel.id,
                    token: registration.token
                )
                self.pushToTalk.markTokenRegistration("Registered")
                return true
            } catch {
                self.pushToTalk.markTokenRegistration("Registration failed")
                self.lastError = "PTT token registration failed: \(self.safeMessage(error))"
                return false
            }
        }
        pushToTalk.onBeginTransmitting = { [weak self] source in
            guard let self else { return }
            let actions = self.pttRequestGate.didBegin()
            self.appAppleBeginReady = true
            let filtered = self.appPrearmAwaitingApple
                ? actions.filter { $0 != .beginFloor }
                : actions
            self.handlePttGateActions(filtered, source: source)
            self.tryActivateAppTransmission()
        }
        pushToTalk.onTransmitRequestDidBegin = { [weak self] _ in
            guard let self else { return }
            if !self.appPrearmAwaitingApple {
                self.resetCurrentTxDiagnostics()
                self.txAttemptGeneration += 1
                self.txAttempts.begin(generation: self.txAttemptGeneration,
                    channelId: self.joinedSession?.channel.id ?? "", sessionGeneration: self.runtimeLiveness.generation)
            }
            self.appleTransmitAttemptGeneration += 1
            self.appleDidBeginAttemptGeneration = self.appleTransmitAttemptGeneration
            self.appleDidActivateAttemptGeneration = nil
            self.appleDidBeginAt = Date()
            self.appleDidActivateAt = nil
        }
        pushToTalk.onEndTransmitting = { [weak self] source in
            guard let self else { return }
            self.pendingAppAppleStop = false
            self.appleLastEndAt = Date()
            self.appleLastEndSource = source
            let actions = self.pttRequestGate.didEnd()
            self.handlePttGateActions(actions, source: source)
            if !actions.contains(.finishFloor) {
                self.startFloorCleanup(source: source)
            }
            // Completing release may start a queued press. Dispatch all old
            // cleanup actions first so they cannot cancel that new press.
            self.markAppleReleaseCompleted(source: source)
        }
        pushToTalk.onAudioSessionActivated = { [weak self] audioSession in
            guard let self else { return }
            AudioLifecycleBreadcrumbStore.shared.record(role: "APP", stage: "APPLE_DID_ACTIVATE")
            if let generation = self.appleDidBeginAttemptGeneration,
               (self.pttRequestGate.state == .beginRequested || self.pttRequestGate.state == .transmitting) {
                self.appleDidActivateAt = Date()
                self.appleDidActivateAttemptGeneration = generation
            }
            await self.audio.pushToTalkDidActivate(audioSession)
            self.rxReadyAppleAudioReadyAt = Date()
            self.liveKitEngineReadyAt = self.audio.liveKitEngineAvailability == "DEFAULT" ? Date() : nil
            if self.audio.pushToTalkAudioSessionActive,
               self.audio.liveKitEngineAvailability == "DEFAULT",
               self.remoteReceive?.audioSessionDidActivate() == true {
                self.appleActivateRxGeneration = self.rx?.currentSnapshot().generation
                self.appleActivateLifecycleState = self.appLifecycleState
                self.activateRemoteReceiveAudio(audioSession)
            }
            self.tryActivateAppTransmission()
            // Normal Apple activation is not a post-call recovery. Resetting the
            // request gate here loses the active TX generation and makes a later
            // normal deactivation look like an unexpected safety failure.
            if shouldFinishPostCallRecovery(onAppleActivation: self.audio.interruption.state) {
                await self.finishRecoveredPTTState()
            }
        }
        pushToTalk.onTransmitFailure = { [weak self] failure in
            guard let self else { return }
            self.appleLastTransmitFailureAt = Date()
            self.appleLastTransmitFailureOperation = failure.operation.rawValue
            self.appleLastTransmitFailureCode = failure.code
            self.appleLastTransmitFailureRecoverable = failure.recoverable
            let failureClass = ("APPLE_" + failure.operation.rawValue + "_" + failure.code)
                .uppercased().replacingOccurrences(of: "[^A-Z0-9_]", with: "_", options: .regularExpression)
            self.journal("APPLE_TX_FAILURE", fields: ["reason": String(failureClass.prefix(64))])
            if shouldIgnoreLateStopFailure(
                operation: failure.operation,
                gateState: self.pttRequestGate.state,
                previousDidEndAt: self.appleLastEndAt,
                nextPttDownAt: self.nextPttDownAt
            ) {
                // A delayed stop result belongs to the completed release generation,
                // never to the newly armed press.
                return
            }
            let actions = self.pttRequestGate.didFail(recoverable: failure.recoverable)
            self.handlePttGateActions(actions, source: failure.operation.rawValue)
            if !actions.contains(.finishFloor) {
                self.startFloorCleanup(source: failure.operation.rawValue)
            }
            if failure.completesAppleRelease {
                self.markAppleReleaseCompleted(source: failure.operation.rawValue)
            }
            if failure.affectsAudioAvailability { self.audio.markInterrupted(failure.message) }
            if !failure.recoverable { self.lastError = "Apple PushToTalk: \(failure.message)" }
        }
        pushToTalk.onAudioSessionDeactivated = { [weak self] _ in
            guard let self else { return }
            AudioLifecycleBreadcrumbStore.shared.record(role: "APP", stage: "APPLE_DID_DEACTIVATE")
            self.appleLastDeactivateAt = Date()
            self.rx?.audioSessionDidDeactivate()
            await self.audio.pushToTalkDidDeactivate()
            self.audioRearmedAt = Date()
            if shouldSafetyStopForAppleDeactivation(
                gateState: self.pttRequestGate.state,
                pttState: self.pttSnapshot.state,
                nextBeginIsRearmingPreviousRelease: self.pttRequestGate.state == .beginRequested &&
                    self.appleLastEndAt != nil &&
                    self.nextPttDownAt.map { down in
                        down >= (self.appleLastEndAt ?? down)
                    } == true
            ) {
                await self.ptt?.stopForSafety(reason: "Apple PushToTalk audio session deactivated.")
            }
        }
        Task { try? await pushToTalk.initialize() }
    }

    var isPoweredOn: Bool { recoveryIntent.isPoweredOn }
    var needsRuntimeRecovery: Bool {
        isPoweredOn && (isRestoringRuntime || !isJoined || room.connectionState == .disconnected || operationalState == .error)
    }
    var isJoined: Bool { joinedSession != nil }
    var selectedUser: User? { fixture?.users.first { $0.id == selectedUserId } }
    var selectedChannel: Channel? { fixture?.channels.first { $0.id == selectedChannelId } }
    var canPressPTT: Bool {
        isPoweredOn && !isStoppingRuntime && operationalState == .active && isJoined && joinedSession?.canPublish == true && room.connectionState == .connected &&
            audio.interruption.state == .ready && !rxConsistencySnapshot.remoteBusyBlocksLocalPtt &&
            !remoteFloorBusy && pttSnapshot.state != .error && pttSnapshot.state != .releasing && restoreTask == nil
    }

    var pttEligible: Bool { canPressPTT }

    var pttBlockReason: String {
        if !isJoined { return "not_joined" }
        if joinedSession?.canPublish != true { return "rx_only" }
        if room.connectionState != .connected { return "connection_not_ready" }
        if audio.interruption.state == .recovering { return "recovering" }
        if audio.interruption.state != .ready { return "audio_not_ready" }
        if remoteFloorBusy { return "floor_busy" }
        if rxConsistencySnapshot.remoteMediaSpeakerActive { return "remote_media_active" }
        if rxConsistencySnapshot.validatedRemoteRxActive { return "remote_rx_active" }
        if rxConsistencySnapshot.rxPathReconciliationActive { return "remote_rx_reconciling" }
        if pttRequestGate.state != .idle { return "request_gate_busy" }
        if pttSnapshot.state == .error { return "ptt_error" }
        return "none"
    }

    var pttSemanticState: PTTSemanticState {
        if needsRuntimeRecovery { return .recovering }
        if joinedSession?.canPublish != true { return .rxOnly }
        if pttSnapshot.state == .error || operationalState == .error { return .error }
        if room.connectionState == .disconnected || !isJoined { return .offline }
        if room.connectionState == .reconnecting || audio.interruption.state == .recovering { return .recovering }
        if remoteFloorBusy || rxConsistencySnapshot.remoteBusyBlocksLocalPtt || pttSnapshot.state == .busy {
            return .busyRemote
        }
        if pttSnapshot.state == .transmitting { return .talking }
        if pttRequestGate.state != .idle || pttSnapshot.state == .requestingFloor { return .preparing }
        return canPressPTT ? .ready : .preparing
    }

    func loadFixture() async {
        guard restoreTask == nil, fixture == nil, !isLoading else { return }
        guard let credential = credentialStore.read() else {
            enrollmentRequired = true
            operationalState = .unenrolled
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let identity = try await api.me()
            guard !Task.isCancelled, credentialStore.read() == credential else { return }
            applyIdentity(identity)
            lastError = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  credentialStore.read() == credential else { return }
            if isConfirmedDeviceCredentialFailure(error) {
                try? credentialStore.clear()
                enrollmentRequired = true
                operationalState = .unenrolled
                lastError = nil
            } else {
                // Connectivity and service failures must not revoke local enrollment.
                enrollmentRequired = false
                operationalState = .error
                lastError = "接続できませんでした。通信状態を確認して再試行してください。"
            }
        }
    }

    func enroll(inviteTokenOrURL: String) async {
        do {
            try await enroll(credential: EnrollmentInputParser.parse(inviteTokenOrURL))
        } catch {
            enrollmentRequired = true
            lastError = "Invite URL or token is invalid"
        }
    }

    func enroll(inviteToken token: String) async {
        await enroll(credential: .token(token))
    }

    private func enroll(credential: EnrollmentCredential) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let response = try await api.enroll(EnrollmentRequest(
                token: credential.token,
                code: credential.code,
                deviceName: deviceDisplayNameStore.getOrCreate(),
                osVersion: UIDevice.current.systemVersion,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "ios-alpha"
            ))
            try credentialStore.write(response.deviceCredential)
            applyIdentity(response.identity)
        } catch {
            enrollmentRequired = true
            lastError = safeMessage(error)
        }
    }

    private func applyIdentity(_ identity: MeResponse) {
        self.identity = identity
        enrollmentRequired = false
        let channels = identity.channels.map {
            Channel(id: $0.id, workspaceId: identity.workspace.id, name: $0.name)
        }
        let user = User(
            id: identity.user.id,
            workspaceId: identity.workspace.id,
            name: identity.user.displayName,
            role: identity.user.role,
            channelIds: channels.map(\.id)
        )
        fixture = FixtureResponse(
            tenant: Tenant(id: "authenticated", name: "KOEON"),
            workspace: Workspace(id: identity.workspace.id, tenantId: "authenticated", name: identity.workspace.name),
            channels: channels,
            users: [user]
        )
        selectedUserId = user.id
        selectedChannelId = channels.first?.id
        operationalState = .enrolledPoweredOff
    }

    @discardableResult
    func join(channelId: String? = nil, preserveSystemPttChannelOnFailure: Bool = false) async -> Bool {
        if let channelId { selectedChannelId = channelId }
        guard !isJoined, !isLoading, !isStoppingRuntime, restoreTask == nil,
              let user = selectedUser, let channel = selectedChannel else { return false }
        if !isPoweredOn { recoveryIntent = RuntimeRecoveryIntent() }
        isJoiningRuntime = true
        defer { isJoiningRuntime = false }
        isLoading = true
        operationalState = .connecting
        lastError = nil
        defer { isLoading = false }
        let connectionAudioPublishProfile = audioPublishProfileForConnection(
            selected: selectedAudioPublishProfile,
            applied: appliedAudioPublishProfile
        )

        do {
            let response = try await api.join(JoinRequest(
                channelId: channel.id,
                wantsToPublish: user.role.canPublish
            ))
            pendingJoinResponse = response
            runtimeLiveness.beginRuntime()
            let runtimeGeneration = runtimeLiveness.generation
            pushToTalk.updateBackendSessionId(response.sessionId)
            let remoteReceive = RemoteReceiveActivationCoordinator(
                resolveSpeaker: { [weak room] sessionId in
                    room?.trustedRemoteSpeaker(sessionId: sessionId)
                },
                setRemoteParticipant: { _ in },
                setRemoteParticipantRequest: { [weak pushToTalk] speaker, context in
                    pushToTalk?.setRemoteSpeaker(
                        sessionId: speaker?.sessionId,
                        name: speaker?.displayName,
                        context: context
                    )
                },
                onClearCompleted: { [weak self, weak room] context in
                    guard self?.runtimeLiveness.generation == runtimeGeneration else { return }
                    _ = room?.completeRemoteAudioGeneration(sessionId: context.sessionId, generation: context.generation)
                }
            ) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self, self.runtimeLiveness.generation == runtimeGeneration else { return }
                    self.applyRemoteReceiveSnapshot(snapshot)
                }
            }
            self.remoteReceive = remoteReceive
            room.onParticipantAvailable = { [weak self] sessionId in
                self?.handleRemoteParticipantAvailable(sessionId: sessionId)
            }
            rx = RxAudioController(
                channelId: response.channel.id,
                cuePlayer: rxCuePlayer,
                onValidatedStart: { [weak self, weak room, weak remoteReceive] event, generation in
                    guard self?.runtimeLiveness.generation == runtimeGeneration else { return }
                    self?.rxRecoveryEvent = event
                    Task { [weak room] in try? await room?.activateRemoteAudioSubscription(
                        sessionId: event.sessionId, generation: generation
                    ) }
                    remoteReceive?.handleValidatedStart(event, generation: generation)
                },
                onAudioActivity: { [weak remoteReceive] sessionId, active in
                    remoteReceive?.handleRemoteAudioActivity(sessionId: sessionId, active: active)
                },
                onDrainCompleted: { [weak self, weak remoteReceive] generation, sessionId, leaseId, reason in
                    return remoteReceive?.completeDrain(
                        generation: generation, sessionId: sessionId, leaseId: leaseId, reason: reason
                    ) ?? false
                },
                onReceiverReady: { [weak self, weak room] speakerSessionId, leaseId in
                    guard let self, let room else { return }
                    try await self.publishReceiverReadyWithDiagnostics(
                        room: room, speakerSessionId: speakerSessionId, leaseId: leaseId
                    )
                },
                startCueEnabled: rxStartCueMode == .on
            ) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self, self.runtimeLiveness.generation == runtimeGeneration else { return }
                    self.applyRxSnapshot(snapshot)
                }
            }
            try await room.connect(
                url: response.livekitUrl,
                token: response.token,
                canPublish: response.canPublish,
                channelId: response.channel.id,
                userId: response.user.id,
                sessionId: response.sessionId,
                deviceId: response.deviceId ?? identity?.device.id,
                audioPublishProfile: connectionAudioPublishProfile
            )
            appliedAudioPublishProfile = connectionAudioPublishProfile
            if let incoming = pushToTalk.currentIncomingEvent(channelId: response.channel.id) {
                rx?.handleTrustedIncomingStart(incoming)
            }
            await audio.prepareForIntercom(canPublish: response.canPublish)
            try await audio.beginPushToTalkManagedSession()
            try await pushToTalk.join(
                channelId: response.channel.id,
                channelName: response.channel.name,
                canPublish: response.canPublish,
                knownUsers: Dictionary(uniqueKeysWithValues: (fixture?.users ?? []).map { ($0.id, $0.name) })
            )
            remoteReceive.reapplyAfterChannelJoin()
            if audio.pushToTalkAudioSessionActive,
               audio.liveKitEngineAvailability == "DEFAULT",
               remoteReceive.audioSessionDidActivate() {
                activateRemoteReceiveAudio(AVAudioSession.sharedInstance())
            }

            joinedSession = response
            pushToTalk.updateBackendSessionId(response.sessionId)
            pendingJoinResponse = nil
            joinedAt = Date()
            sessionUptimeSeconds = 0
            guard let deviceId = response.deviceId, !deviceId.isEmpty else {
                throw APIClientError.invalidResponse
            }
            // LiveKit Opus is the only audio transport.
            let controller = PTTController(
                role: response.user.role,
                floor: FloorClient(sessionId: response.sessionId, api: api),
                microphone: room,
                cuePlayer: cuePlayer,
                control: room,
                rtpReleaseHangoverMilliseconds: 180
            ) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self, self.runtimeLiveness.generation == runtimeGeneration else { return }
                    self.applyPttSnapshot(snapshot)
                }
            }
            ptt = controller
            pttSnapshot = .initial(role: response.user.role)
            startUptimeTimer()
            startServiceStatusPolling()
            recoveryIntent.powerOn()
            operationalState = .active
            lastError = nil
            validateCurrentRuntime()
            if let incoming = pushToTalk.currentIncomingEvent(channelId: response.channel.id) {
            }
            return true
        } catch {
            if !preserveSystemPttChannelOnFailure { await pushToTalk.leave() }
            await room.disconnect()
            await audio.endPushToTalkManagedSession()
            await audio.endIntercom()
            if let pendingJoinResponse {
                try? await api.unregisterPttToken(sessionId: pendingJoinResponse.sessionId)
                try? await api.leave(sessionId: pendingJoinResponse.sessionId)
            }
            pendingJoinResponse = nil
            joinedSession = nil
            ptt = nil
            rx?.reset()
            rx = nil
            remoteReceive?.reset()
            self.remoteReceive = nil
            resetRxConsistency()
            remoteReceiveSnapshot = RemoteReceiveActivationSnapshot()
            rxSnapshot = RxSnapshot()
            lastError = safeMessage(error)
            operationalState = .error
            return false
        }
    }

    func leave(powerOff: Bool = true) async {
        guard !isStoppingRuntime else { return }
        isStoppingRuntime = true
        isLoading = true
        defer { isStoppingRuntime = false; isLoading = false }
        runtimeRetryTask?.cancel()
        runtimeRetryTask = nil
        if powerOff { recoveryIntent.powerOff() }
        let restoring = restoreTask
        restoring?.cancel()
        await restoring?.value
        incomingWakeRecoveryTask?.cancel()
        incomingWakeRecoveryTask = nil
        let leavingSessionId = joinedSession?.sessionId ?? pendingJoinResponse?.sessionId
            ?? pushToTalk.listeningSessionId
        await ptt?.stopForSafety(reason: "Channel left.")
        guard await ptt?.cleanupIsConfirmed() != false else {
            recoveryIntent.powerOn()
            lastError = "CHANNEL_LEAVE_BLOCKED_PENDING_OWN_LEASE"
            operationalState = .error
            return
        }
        await invalidateRuntimeCallbacks()
        rxRecoveryTask?.cancel()
        await rxRecoveryTask?.value
        rxRecoveryTask = nil
        rxRecoveryEvent = nil
        rxRecoveryRebuiltLease = nil
        remoteFloorBusy = false
        AudioLifecycleBreadcrumbStore.shared.record(role: "APP", stage: "SESSION_LEAVE")
        isLoading = true
        haptics?.cancel()
        resetPttRequestGate()
        audioRecoveryTask?.cancel()
        audioRecoveryTask = nil
        floorStatusTask?.cancel()
        floorStatusTask = nil
        await ptt?.stopForSafety(reason: "Channel left.")
        ptt = nil
        remoteReceive?.reset()
        remoteReceive = nil
        resetRxConsistency()
        rx?.reset()
        rx = nil
        if let leavingSessionId { try? await api.unregisterPttToken(sessionId: leavingSessionId) }
        await pushToTalk.leave()
        await room.disconnect()
        await audio.endPushToTalkManagedSession()
        await audio.endIntercom()
        do {
            if let leavingSessionId { try await api.leave(sessionId: leavingSessionId) }
        } catch {
            lastError = "Backend leave failed: \(safeMessage(error))"
        }
        joinedSession = nil
        if powerOff { appliedAudioPublishProfile = nil }
        joinedAt = nil
        uptimeTask?.cancel()
        uptimeTask = nil
        sessionUptimeSeconds = 0
        pttSnapshot = .initial(role: selectedUser?.role ?? .staff)
        rxSnapshot = RxSnapshot()
        remoteReceiveSnapshot = RemoteReceiveActivationSnapshot()
        pttStoppedForAudioInterruption = false
        isLoading = false
        operationalState = powerOff ? .enrolledPoweredOff : .switchingChannel
    }

    func switchChannel(to targetChannelId: String) async {
        guard let current = joinedSession,
              targetChannelId != current.channel.id,
              identity?.channels.contains(where: { $0.id == targetChannelId }) == true,
              operationalState != .switchingChannel else { return }
        let previousChannelId = current.channel.id
        switchGeneration += 1
        let generation = switchGeneration
        operationalState = .switchingChannel
        await leave(powerOff: false)
        guard generation == switchGeneration, joinedSession == nil else { return }
        if await join(channelId: targetChannelId) { return }
        guard generation == switchGeneration else { return }
        let restored = await join(channelId: previousChannelId)
        lastError = restored
            ? "Target Channel join failed; previous Channel restored"
            : "Target Channel and previous Channel recovery failed"
    }

    func setActionButtonPttEnabled(_ enabled: Bool) {
        if !enabled, actionButtonOwnsAttempt { endPttInput(usingIntent: true) }
        actionButtonPttEnabled = enabled
        audioPublishDefaults.set(enabled, forKey: "ptt.actionButtonEnabled")
    }

    /// No awaits or restoration queue: a stale shortcut cannot start a later session.
    func toggleActionButtonPtt() -> ActionButtonPttResult {
        let decision = actionButtonPttDecision(enabled: actionButtonPttEnabled,
            state: pttRequestGate.state, eligible: canPressPTT)
        journal("PTT_INTENT", fields: [
            "reason": decision == .unavailable ? pttBlockReason.uppercased() : String(describing: decision).uppercased(),
            "operational": operationalState.rawValue.uppercased()
        ])
        switch decision {
        case .startRequested:
            actionButtonOwnsAttempt = true
            beginPttInput(usingIntent: true)
        case .stopRequested:
            endPttInput(usingIntent: true)
        case .disabled, .unavailable, .settling:
            break
        }
        return decision
    }

    /// Keep the system intent alive while its asynchronous OS start is pending.
    /// Never retain a request for a future session or interfere with a newer attempt.
    func toggleActionButtonPttFromIntent() async -> ActionButtonPttResult {
        guard !Task.isCancelled else { return .unavailable }
        let result = toggleActionButtonPtt()
        guard result == .startRequested else { return result }
        let attempt = txAttemptGeneration
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !Task.isCancelled, clock.now < deadline,
              attempt == txAttemptGeneration, actionButtonOwnsAttempt {
            if pttSnapshot.state == .transmitting { return .startRequested }
            guard pttRequestGate.state == .beginRequested || pttRequestGate.state == .transmitting else { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if attempt == txAttemptGeneration, actionButtonOwnsAttempt {
            journal("PTT_INTENT_WAIT_END", fields: ["reason": Task.isCancelled ? "CANCELLED" : "NOT_STARTED"])
            endPttInput(usingIntent: true)
        }
        return .unavailable
    }

    func pttDown() { beginPttInput(usingIntent: false) }

    private func beginPttInput(usingIntent: Bool) {
        guard joinedSession?.canPublish == true else { return }
        guard usingIntent || appPttTouchEdgeGate.changed() else { return }
        nextPttDownAt = Date()
        if pttRequestGate.state == .endRequested || pttRequestGate.state == .rearming {
            guard usingIntent || (haptics?.press(eligible: true) ?? true) else { return }
            let actions = pttRequestGate.pressDown()
            pttRequestGateState = pttRequestGate.state
            if actions.contains(.pending) { return }
            playStatusCue(.busy)
            return
        }
        guard pttRequestGate.state == .idle else {
            playStatusCue(.busy)
            return
        }
        guard canPressPTT else {
            if isJoined, audio.interruption.state != .ready {
                lastError = "AUDIO INTERRUPTED: 音声復旧が完了するまでPTTは利用できません"
                playStatusCue(.error)
            } else if rxConsistencySnapshot.remoteBusyBlocksLocalPtt {
                playStatusCue(.busy)
            }
            return
        }
        guard usingIntent || (haptics?.press(eligible: true) ?? true) else { return }
        let gateActions = pttRequestGate.pressDown()
        pttRequestGateState = pttRequestGate.state
        guard gateActions.contains(.requestBegin) else {
            if gateActions.contains(.busy) { playStatusCue(.busy) }
            return
        }
        if !usingIntent, appTxPath == .postBeginControl {
            appleBeginRequestedAt = Date()
            pushToTalk.requestBeginTransmitting()
            return
        }
        startParallelAppTransmissionAttempt(requestAppleImmediately: usingIntent)
    }

    private func startParallelAppTransmissionAttempt(requestAppleImmediately: Bool = false) {
        resetCurrentTxDiagnostics()
        txAttemptGeneration += 1
        let attempt = txAttemptGeneration
        let runtime = runtimeLiveness.generation
        let controller = ptt
        txAttempts.begin(generation: attempt, channelId: joinedSession?.channel.id ?? "",
            sessionGeneration: runtimeLiveness.generation)
        appPrearmAwaitingApple = true
        appPrearmReady = false
        appAppleBeginReady = false
        appActivationCommitted = false
        appleBeginIssuedForAttempt = false
        appleBeginRequestedAt = nil
        appleDidBeginAt = nil
        appleDidActivateAt = nil
        appleDidBeginAttemptGeneration = nil
        appleDidActivateAttemptGeneration = nil
        liveKitEngineReadyAt = nil
        appPrearmTask?.cancel()
        appPrearmTask = Task { [weak self] in
            guard let self else { return }
            guard self.runtimeLiveness.generation == runtime, !Task.isCancelled else { return }
            let prepared = await controller?.preArmForAppleActivation(
                maximumReadyWaitMilliseconds: self.maximumReadyWaitMilliseconds,
                onFloorGranted: { [weak self] in
                    await self?.requestAppleBeginForAttempt(attempt: attempt)
                }
            ) == true
            guard self.runtimeLiveness.generation == runtime,
                  attempt == self.txAttemptGeneration else { return }
            self.appPrearmTask = nil
            guard !Task.isCancelled, prepared else {
                if self.pttRequestGate.state == .beginRequested || self.pttRequestGate.state == .transmitting {
                    let stopActions = self.pttRequestGate.pressUp()
                    self.startFloorCleanup(source: "developerRequest")
                    self.handlePttGateActions(stopActions, source: "developerRequest")
                }
                return
            }
            guard !self.pttRequestGate.releaseRequestedBeforeBegin else { return }
            self.appPrearmReady = true
            guard self.pttRequestGate.state == .beginRequested ||
                    self.pttRequestGate.state == .transmitting else { return }
            self.requestAppleBeginForAttempt(attempt: attempt)
            self.tryActivateAppTransmission()
        }
        // The PTT-specific intent issues the OS request before returning. Audio
        // publication still waits for BOTH Floor preparation and Apple activation.
        if requestAppleImmediately { requestAppleBeginForAttempt(attempt: attempt) }
    }

    private func requestAppleBeginForAttempt(attempt: Int) {
        guard shouldRequestAppleBeginAfterFloorGrant(
            attempt: attempt,
            currentAttempt: txAttemptGeneration,
            gateState: pttRequestGate.state,
            releaseRequestedBeforeBegin: pttRequestGate.releaseRequestedBeforeBegin,
            alreadyIssued: appleBeginIssuedForAttempt
        ) else { return }
        appleBeginRequestedAt = Date()
        appleBeginIssuedForAttempt = true
        pushToTalk.requestBeginTransmitting()
        activationWatchdogTask?.cancel()
        activationWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, attempt == self.txAttemptGeneration,
                  self.appleDidActivateAt == nil, self.pttSnapshot.talkingAt == nil,
                  !self.releaseFloorCompleted else { return }
            await self.ptt?.stopForSafety(reason: "TX_ACTIVATION_TIMEOUT")
            self.beginRecoverableAppleAbort()
        }
    }

    func pttUp() { endPttInput(usingIntent: false) }

    private func endPttInput(usingIntent: Bool) {
        guard usingIntent || appPttTouchEdgeGate.ended() else { return }
        guard usingIntent || (haptics?.release() ?? true) else { return }
        if pttRequestGate.state == .endRequested || pttRequestGate.state == .rearming {
            _ = pttRequestGate.pressUp()
            pttRequestGateState = pttRequestGate.state
            return
        }
        let actions = pttRequestGate.pressUp()
        if pttRequestGate.state == .beginRequested,
           appPrearmAwaitingApple,
           !appleBeginIssuedForAttempt {
            pttRequestGate.cancelBeforeSystemBegin()
            pttRequestGateState = pttRequestGate.state
            markAppleReleaseCompleted(source: "developerRequest_cancelled_before_apple")
        }
        if pttRequestGate.state == .endRequested || pttRequestGate.releaseRequestedBeforeBegin {
            startFloorCleanup(source: "developerRequest")
        } else if pttRequestGate.state == .rearming {
            startFloorCleanup(source: "developerRequest")
        }
        handlePttGateActions(actions, source: "userRequest")
    }

    func retryAudioRecovery() {
        recoverAudio(generation: audio.interruption.generation)
    }

    func reportEnrollmentError(_ message: String) {
        enrollmentRequired = true
        lastError = message
    }

    func setHeadsetPttEnabled(_ enabled: Bool) {
        pushToTalk.setHeadsetPttEnabled(enabled)
    }

    func setAudioPublishProfile(_ profile: AudioPublishProfile) {
        selectedAudioPublishProfile = profile
        profile.persist(to: audioPublishDefaults)
    }

    func appLifecycleDidChange(_ value: String) {
        appLifecycleState = value
        journal("LIFECYCLE")
        if value == "active" {
            lastForegroundAt = Date()
            recoveryIntent.resetRetries()
            requestForegroundRuntimeRecoveryIfNeeded()
        } else if value == "background" || value == "inactive" {
            lastBackgroundAt = Date()
            runtimeLiveness.invalidate()
        }
    }

    func retryRuntimeRecovery() {
        guard isPoweredOn, !isStoppingRuntime else { return }
        recoveryIntent.resetRetries()
        runtimeLiveness.invalidate()
        requestForegroundRuntimeRecoveryIfNeeded()
    }

    private func scheduleRuntimeRetry() {
        guard !isStoppingRuntime, !isJoiningRuntime, runtimeRetryTask == nil,
              let delay = recoveryIntent.nextRetryDelay(isForeground: appLifecycleState == "active") else { return }
        runtimeRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.runtimeRetryTask = nil
            guard self.appLifecycleState == "active" else { return }
            self.requestForegroundRuntimeRecoveryIfNeeded()
        }
    }

    private func requestForegroundRuntimeRecoveryIfNeeded() {
        guard isPoweredOn, !isStoppingRuntime else { return }
        if (runtimeLiveness.dirty || joinedSession == nil),
           let descriptor = PttRestoreDescriptor.load(from: .standard) ?? recoveryIntent.descriptor,
           pttSnapshot.state != .transmitting, pttSnapshot.state != .releasing {
            requestRuntimeRestore(descriptor, reason: .foregroundRecovery)
            return
        }
        let action = foregroundRuntimeRecoveryAction(
            hasJoinedRuntime: joinedSession != nil,
            connectionState: room.connectionState
        )
        switch action {
        case .noJoinedRuntime, .keepConnectedRuntime, .awaitExistingReconnect:
            lastForegroundRecoveryResult = action.rawValue
        case .requestPersistedRuntimeRestore:
            lastForegroundRecoveryRequestedAt = Date()
            lastForegroundRecoveryCompletedAt = nil
            lastForegroundRecoveryResult = "REQUESTED"
            foregroundRecoveryPending = true
            guard let descriptor = PttRestoreDescriptor.load(from: .standard) ?? recoveryIntent.descriptor else {
                completeForegroundRecovery(result: "FAILED_MISSING_DESCRIPTOR")
                return
            }
            requestRuntimeRestore(descriptor, reason: .foregroundRecovery)
        }
    }

    private func completeForegroundRecovery(result: String) {
        guard foregroundRecoveryPending else { return }
        foregroundRecoveryPending = false
        lastForegroundRecoveryCompletedAt = Date()
        lastForegroundRecoveryResult = result
    }

    private func scheduleIncomingPushRuntimeRecovery(
        _ action: IncomingPushRuntimeAction,
        generation: Int
    ) {
        incomingWakeRecoveryTask?.cancel()
        incomingWakeRecoveryTask = nil
        switch action {
        case .useWarmRuntime:
            runtimeRestoreReason = "WARM_RUNTIME_NO_RESTORE"
            runtimeRestoreDecision = "USE_WARM_RUNTIME"
            runtimeRestoreEarlyExitReason = "NONE"
            completeReconnectAttempt(result: "warm_runtime_connected")
        case .resumeImmediately:
            runtimeRestoreReason = RuntimeRestoreReason.incomingPushColdWake.rawValue
            runtimeRestoreDecision = "REQUEST_FRESH_RESUME"
            runtimeRestoreEarlyExitReason = "NONE"
            beginReconnectAttempt(reason: "incoming_push_resume")
            if !pushToTalk.requestRuntimeRestoreForIncomingPush() {
                rxWakeFailureStage = "missing_restore_descriptor"
                completeReconnectAttempt(result: "failed_missing_descriptor")
            }
        case .awaitReconnectThenResume:
            runtimeRestoreReason = RuntimeRestoreReason.incomingPushColdWake.rawValue
            runtimeRestoreDecision = "AWAIT_RECONNECT_THEN_FRESH_RESUME"
            runtimeRestoreEarlyExitReason = "NONE"
            beginReconnectAttempt(reason: "incoming_push_await_reconnect")
            incomingWakeRecoveryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, generation == self.rxWakeGeneration else { return }
                defer {
                    self.incomingWakeRecoveryTask = nil
                    self.scheduleRxDivergenceWatchdogIfNeeded()
                }
                if let incoming = self.pushToTalk.currentIncomingEvent(channelId: self.joinedSession?.channel.id ?? ""),
                   self.room.connectionState == .connected,
                   ((self.receivedControlStart?.runtime == self.runtimeLiveness.generation &&
                     incomingMatchesStart(incoming, self.receivedControlStart?.event)) ||
                    (self.rx?.currentSnapshot().rxFirstPcmAt != nil &&
                     incomingMatchesStart(incoming, self.rxRecoveryEvent))) {
                    // A matching authenticated START received by this runtime is
                    // fresh transport evidence; a cached .connected flag is not.
                    self.validateCurrentRuntime()
                    self.runtimeRestoreDecision = "KEEP_VERIFIED_INCOMING_RUNTIME"
                    self.completeReconnectAttempt(result: "verified_incoming_start")
                    return
                }
                if !self.pushToTalk.requestRuntimeRestoreForIncomingPush() {
                    self.rxWakeFailureStage = "missing_restore_descriptor"
                    self.completeReconnectAttempt(result: "failed_missing_descriptor")
                }
            }
        }
    }

    private func beginReconnectAttempt(reason: String, startedAt: Date = Date()) {
        if reconnectAttempt?.completedAt == nil, reconnectAttempt != nil { return }
        reconnectAttemptSequence += 1
        reconnectAttempt = ReconnectAttemptDiagnostic(
            id: reconnectAttemptSequence,
            startedAt: startedAt,
            reason: reason,
            completedAt: nil,
            result: nil
        )
        liveKitReconnectStartedAt = startedAt
        liveKitReconnectCompletedAt = nil
    }

    private func completeReconnectAttempt(result: String, completedAt: Date = Date()) {
        guard var attempt = reconnectAttempt, attempt.completedAt == nil else { return }
        attempt.completedAt = completedAt
        attempt.result = result
        reconnectAttempt = attempt
        liveKitReconnectCompletedAt = completedAt
    }

    func resetDeviceAssignment() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        if isPoweredOn || isJoined { await leave(powerOff: true) }
        do {
            try await api.logout()
            try credentialStore.clear()
            pushToTalk.clearRestoreContext()
            fixture = nil
            identity = nil
            selectedUserId = nil
            selectedChannelId = nil
            enrollmentRequired = true
            operationalState = .unenrolled
            pttRestoreState = "not_required"
            isLoading = false
        } catch {
            lastError = "ユーザー割当の解除に失敗しました。再試行してください: \(safeMessage(error))"
            isLoading = false
        }
    }

    private func requestRuntimeRestore(
        _ descriptor: PttRestoreDescriptor,
        reason: RuntimeRestoreReason
    ) {
        guard !isStoppingRuntime, !isJoiningRuntime, recoveryIntent.allowsRestoration else { return }
        runtimeRestoreReason = reason.rawValue
        roomConnectionStateAtRestoreEntry = room.connectionState.rawValue
        joinedSessionPresentAtRestoreEntry = joinedSession != nil
        guard restoreTask == nil else {
            runtimeRestoreDecision = "SINGLE_FLIGHT_EXISTING"
            runtimeRestoreEarlyExitReason = "RESTORE_TASK_ACTIVE"
            return
        }
        let entryDecision = runtimeRestoreEntryDecision(
            reason: reason,
            hasJoinedRuntime: joinedSession != nil,
            connectionState: room.connectionState,
            runtimeDirty: runtimeLiveness.dirty
        )
        runtimeRestoreDecision = entryDecision.rawValue
        if entryDecision == .useConnectedRuntime {
            runtimeRestoreEarlyExitReason = "ALREADY_CONNECTED_WARM_RUNTIME"
            completeReconnectAttempt(result: "already_connected")
            completeForegroundRecovery(result: "ALREADY_CONNECTED")
            return
        }
        guard restoreSingleFlight.begin() else {
            runtimeRestoreDecision = "SINGLE_FLIGHT_EXISTING"
            runtimeRestoreEarlyExitReason = "RESTORE_GATE_ACTIVE"
            return
        }
        guard recoveryIntent.beginRestore(descriptor) else { return }
        runtimeRetryTask?.cancel()
        runtimeRetryTask = nil
        isRestoringRuntime = true
        operationalState = .connecting
        runtimeRestoreEarlyExitReason = "NONE"
        pttRestoreState = "restoring"
        pttRestoreStartedAt = Date()
        beginReconnectAttempt(reason: "ptt_channel_restore", startedAt: pttRestoreStartedAt ?? Date())
        pttRestoreCompletedAt = nil
        pttRestoreMilliseconds = nil
        restoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.restoreTask = nil
                self.restoreSingleFlight.finish()
                self.isRestoringRuntime = false
                self.scheduleRxDivergenceWatchdogIfNeeded()
                if self.pttRestoreState != "restored", self.isPoweredOn, !self.isStoppingRuntime {
                    self.runtimeLiveness.invalidate()
                    self.operationalState = .error
                    self.scheduleRuntimeRetry()
                }
            }
            guard self.credentialStore.read() != nil else {
                self.recoveryIntent.powerOff()
                self.pttRestoreState = "failed_missing_credential"
                self.completeReconnectAttempt(result: "failed_missing_credential")
                self.completeForegroundRecovery(result: "FAILED_MISSING_CREDENTIAL")
                await self.prepareStaleRuntimeForResume()
                await self.pushToTalk.leave()
                await self.audio.endPushToTalkManagedSession()
                await self.audio.endIntercom()
                self.enrollmentRequired = true
                self.operationalState = .unenrolled
                return
            }
            do {
                await self.ptt?.stopForSafety(reason: "Runtime restore terminal cleanup")
                guard await self.ptt?.cleanupIsConfirmed() != false else {
                    self.runtimeRestoreEarlyExitReason = "PENDING_OWN_LEASE_CLEANUP"
                    return
                }
                try Task.checkCancellation()
                let cached = self.joinedSession
                var established = false
                if reason == .incomingPushColdWake, !self.runtimeLiveness.dirty,
                   canUseFastColdReconnect(cached: cached, descriptor: descriptor),
                   let cached {
                    self.runtimeRestorePath = "FAST_COLD_RECONNECT"
                    await self.prepareStaleRuntimeForResume()
                    established = await self.establishResumedRuntime(cached)
                }
                if !established {
                    if self.runtimeRestorePath == "FAST_COLD_RECONNECT" {
                        self.runtimeRestorePath = "FAST_COLD_RECONNECT_FALLBACK_FULL"
                    } else {
                        self.runtimeRestorePath = "FULL_COLD_RESUME"
                    }
                    established = try await performFreshRuntimeRestore(
                    requestFreshSession: {
                        self.resumeRequestAt = Date()
                        if self.restorePath == .fastResume {
                            return try await self.api.resume(ResumeRequest(
                                channelId: descriptor.channelId,
                                previousSessionId: descriptor.lastBackendSessionId
                            ))
                        }
                        let me = try await self.api.me()
                        self.applyIdentity(me)
                        self.selectedChannelId = descriptor.channelId
                        guard let user = self.selectedUser else { throw APIClientError.invalidResponse }
                        if let previous = descriptor.lastBackendSessionId {
                            try? await self.api.leave(sessionId: previous)
                        }
                        return try await self.api.join(JoinRequest(
                            channelId: descriptor.channelId,
                            wantsToPublish: user.role.canPublish
                        ))
                    },
                    onFreshSessionReceived: { _ in self.resumeResponseAt = Date() },
                    teardownStaleRuntime: { await self.prepareStaleRuntimeForResume() },
                    establishFreshRuntime: { response in
                        self.applyResumeIdentity(response)
                        return await self.establishResumedRuntime(response)
                    },
                    discardFreshSession: { await self.discardResumedSession($0) }
                    )
                }
                try Task.checkCancellation()
                guard established else {
                    self.completeForegroundRecovery(result: "FAILED_RUNTIME_CONNECT")
                    return
                }
                self.pttRestoreState = "restored"
                let completedAt = Date()
                self.pttRestoreCompletedAt = completedAt
                self.pttRestoreMilliseconds = Int(
                    completedAt.timeIntervalSince(self.pttRestoreStartedAt ?? completedAt) * 1_000
                )
                self.completeReconnectAttempt(result: "restored")
                self.completeForegroundRecovery(result: "RESTORED")
                self.rxWakeFailureStage = nil
            } catch {
                if Task.isCancelled { return }
                if isTerminalRuntimeRestoreError(error) {
                    self.recoveryIntent.powerOff()
                    self.pttRestoreState = "failed_invalid_identity"
                    self.completeReconnectAttempt(result: "failed_invalid_identity")
                    self.completeForegroundRecovery(result: "FAILED_INVALID_IDENTITY")
                    await self.prepareStaleRuntimeForResume()
                    await self.pushToTalk.leave()
                    await self.audio.endPushToTalkManagedSession()
                    await self.audio.endIntercom()
                    try? self.credentialStore.clear()
                    self.fixture = nil
                    self.identity = nil
                    self.enrollmentRequired = true
                    self.operationalState = .unenrolled
                    return
                }
                self.pttRestoreState = "failed_retryable"
                self.completeReconnectAttempt(result: "failed_retryable")
                self.completeForegroundRecovery(result: "FAILED_RETRYABLE")
                self.rxWakeFailureStage = "runtime_resume"
                self.lastError = "PushToTalk runtime restore failed: \(self.safeMessage(error))"
            }
        }
    }

    private func prepareStaleRuntimeForResume() async {
        staleRuntimeTeardownStartedAt = Date()
        defer { staleRuntimeTeardownCompletedAt = Date() }
        guard joinedSession != nil || room.connectionState != .disconnected else { return }
        audioRecoveryTask?.cancel()
        audioRecoveryTask = nil
        await invalidateRuntimeCallbacks()
        floorStatusTask?.cancel()
        floorStatusTask = nil
        uptimeTask?.cancel()
        uptimeTask = nil
        resetPttRequestGate()
        await ptt?.stopForSafety(reason: "Incoming Push is replacing a stale LiveKit runtime.")
        ptt = nil
        pttSnapshot = .initial(role: selectedUser?.role ?? .staff)
        rx?.reset()
        rx = nil
        remoteReceive?.resetPreservingSystemRemoteParticipant()
        remoteReceive = nil
        resetRxConsistency()
        joinedSession = nil
        await room.disconnect()
        // Even escalated RX recovery replaces only the network runtime.
        // Leaving the Apple channel here destroys its push registration and
        // requires a foreground join; a locked/background receiver cannot
        // recreate it. Explicit POWER OFF and terminal identity failures still
        // leave through their own cleanup paths.
        // Keep Apple PushToTalk audio ownership across the stale LiveKit runtime swap.
        // incomingPushResult may already have activated this AVAudioSession.
    }

    private func applyResumeIdentity(_ response: JoinResponse) {
        let channel = Channel(id: response.channel.id, workspaceId: response.user.workspaceId, name: response.channel.name)
        let user = User(
            id: response.user.id,
            workspaceId: response.user.workspaceId,
            name: response.user.name,
            role: response.user.role,
            channelIds: [response.channel.id]
        )
        fixture = FixtureResponse(
            tenant: Tenant(id: "authenticated", name: "KOEON"),
            workspace: Workspace(id: response.user.workspaceId, tenantId: "authenticated", name: "KOEON"),
            channels: [channel], users: [user]
        )
        selectedUserId = user.id
        selectedChannelId = channel.id
    }

    private func discardResumedSession(_ response: JoinResponse) async {
        // Cleanup must run even when the restore that created the session was cancelled.
        await Task { @MainActor in
            try? await api.unregisterPttToken(sessionId: response.sessionId)
            try? await api.leave(sessionId: response.sessionId)
        }.value
    }

    /** Cold PushToTalk restoration consumes the fresh Resume response directly. */
    func establishResumedRuntime(_ response: JoinResponse) async -> Bool {
        pendingJoinResponse = response
        // The backend already bound the listening registration in Resume.
        // Persist that ownership even if the following network connect fails.
        pushToTalk.retainListeningSessionId(response.sessionId)
        runtimeLiveness.beginRuntime()
        let runtimeGeneration = runtimeLiveness.generation
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { [weak room] sessionId in room?.trustedRemoteSpeaker(sessionId: sessionId) },
            setRemoteParticipant: { _ in },
            setRemoteParticipantRequest: { [weak pushToTalk] speaker, context in
                pushToTalk?.setRemoteSpeaker(
                    sessionId: speaker?.sessionId, name: speaker?.displayName, context: context
                )
            },
            onClearCompleted: { [weak self, weak room] context in
                guard self?.runtimeLiveness.generation == runtimeGeneration else { return }
                _ = room?.completeRemoteAudioGeneration(sessionId: context.sessionId, generation: context.generation)
            }
        ) { [weak self] snapshot in
            Task { @MainActor in
                    guard let self, self.runtimeLiveness.generation == runtimeGeneration else { return }
                    self.applyRemoteReceiveSnapshot(snapshot)
                }
        }
        remoteReceive = coordinator
        room.onParticipantAvailable = { [weak self] sessionId in
            self?.handleRemoteParticipantAvailable(sessionId: sessionId)
        }
        rx = RxAudioController(
            channelId: response.channel.id,
            cuePlayer: rxCuePlayer,
            onValidatedStart: { [weak self, weak room, weak coordinator] event, generation in
                guard self?.runtimeLiveness.generation == runtimeGeneration else { return }
                self?.rxRecoveryEvent = event
                Task { [weak room] in try? await room?.activateRemoteAudioSubscription(
                    sessionId: event.sessionId, generation: generation
                ) }
                coordinator?.handleValidatedStart(event, generation: generation)
            },
            onAudioActivity: { [weak coordinator] sessionId, active in
                coordinator?.handleRemoteAudioActivity(sessionId: sessionId, active: active)
            },
            onDrainCompleted: { [weak self, weak coordinator] generation, sessionId, leaseId, reason in
                return coordinator?.completeDrain(
                    generation: generation, sessionId: sessionId, leaseId: leaseId, reason: reason
                ) ?? false
            },
            onReceiverReady: { [weak self, weak room] speakerSessionId, leaseId in
                guard let self, let room else { return }
                try await self.publishReceiverReadyWithDiagnostics(
                    room: room, speakerSessionId: speakerSessionId, leaseId: leaseId
                )
            },
            startCueEnabled: rxStartCueMode == .on
        ) { [weak self] snapshot in Task { @MainActor in
                    guard let self, self.runtimeLiveness.generation == runtimeGeneration else { return }
                    self.applyRxSnapshot(snapshot)
                } }
        let connectionAudioPublishProfile = audioPublishProfileForConnection(
            selected: selectedAudioPublishProfile,
            applied: appliedAudioPublishProfile
        )
        var restoreStage = "CHECK_CANCELLATION"
        do {
            try Task.checkCancellation()
            resumeLiveKitConnectStartedAt = Date()
            beginReconnectAttempt(reason: "livekit_resume_connect", startedAt: resumeLiveKitConnectStartedAt ?? Date())
            restoreStage = "LIVEKIT_CONNECT"
            try await room.connect(
                url: response.livekitUrl, token: response.token, canPublish: response.canPublish,
                channelId: response.channel.id, userId: response.user.id, sessionId: response.sessionId,
                deviceId: response.deviceId ?? identity?.device.id,
                audioPublishProfile: connectionAudioPublishProfile
            )
            try Task.checkCancellation()
            appliedAudioPublishProfile = connectionAudioPublishProfile
            resumeLiveKitConnectedAt = Date()
            completeReconnectAttempt(result: "connected", completedAt: resumeLiveKitConnectedAt ?? Date())
            if let incoming = pushToTalk.currentIncomingEvent(channelId: response.channel.id) {
                rx?.handleTrustedIncomingStart(incoming)
            }
            restoreStage = "AUDIO_PREPARE"
            await audio.prepareForIntercom(canPublish: response.canPublish)
            restoreStage = "AUDIO_BEGIN"
            try await audio.beginPushToTalkManagedSession()
            restoreStage = "APPLE_CHANNEL_JOIN"
            try await pushToTalk.join(channelId: response.channel.id, channelName: response.channel.name,
                canPublish: response.canPublish, knownUsers: [:])
            coordinator.reapplyAfterChannelJoin()
            if audio.pushToTalkAudioSessionActive,
               audio.liveKitEngineAvailability == "DEFAULT",
               coordinator.audioSessionDidActivate() {
                activateRemoteReceiveAudio(AVAudioSession.sharedInstance())
            }
            try Task.checkCancellation()
            joinedSession = response
            pushToTalk.updateBackendSessionId(response.sessionId)
            pendingJoinResponse = nil
            joinedAt = Date()
            restoreStage = "VALIDATE_DEVICE"
            guard let deviceId = response.deviceId, !deviceId.isEmpty else {
                throw APIClientError.invalidResponse
            }
            // LiveKit Opus is the only audio transport.
            let controller = PTTController(
                role: response.user.role,
                floor: FloorClient(sessionId: response.sessionId, api: api),
                microphone: room, cuePlayer: cuePlayer, control: room,
                rtpReleaseHangoverMilliseconds: 180
            ) { [weak self] snapshot in Task { @MainActor in
                    guard let self, self.runtimeLiveness.generation == runtimeGeneration else { return }
                    self.applyPttSnapshot(snapshot)
                } }
            ptt = controller
            pttSnapshot = .initial(role: response.user.role)
            startUptimeTimer()
            startServiceStatusPolling()
            recoveryIntent.powerOn()
            operationalState = .active
            lastError = nil
            validateCurrentRuntime()
            if let incoming = pushToTalk.currentIncomingEvent(channelId: response.channel.id) {
            }
            return true
        } catch {
            // A transient runtime failure is not POWER OFF. Unregister/leave
            // would delete the durable push destination and prevent the next
            // incoming push from retrying this background receiver. Explicit
            // leave owns that cleanup, including a cancelled restore attempt.
            AudioLifecycleBreadcrumbStore.shared.record(
                role: "APP", stage: "RUNTIME_CONNECT_FAILED", generationId: String(runtimeGeneration),
                resultClass: Task.isCancelled ? "CANCELLED" : "LISTENING_RETAINED"
            )
            AudioLifecycleBreadcrumbStore.shared.record(
                role: "APP", stage: "RUNTIME_FAILED_" + restoreStage,
                generationId: String(runtimeGeneration),
                resultClass: Task.isCancelled ? "CANCELLED" : "FAILED"
            )
            pendingJoinResponse = nil
            joinedSession = nil
            pttRestoreState = "failed_retryable_join"
            completeReconnectAttempt(result: "failed_retryable_join")
            lastError = "PushToTalk Resume runtime failed: \(safeMessage(error))"
            await room.disconnect()
            await audio.endPushToTalkManagedSession()
            await audio.endIntercom()
            return false
        }
    }

    private func recoverAudio(generation: Int) {
        guard isJoined, audio.beginRecovery(generation: generation) else { return }
        postCallRearmState = .waitingRoom
        let runtime = runtimeLiveness.generation
        audioRecoveryTask?.cancel()
        audioRecoveryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<10 {
                guard !Task.isCancelled, self.runtimeLiveness.generation == runtime else { return }
                if self.room.connectionState == .connected {
                    self.postCallRearmState = .stabilizing
                    do { try await Task.sleep(nanoseconds: UInt64(postCallStableMilliseconds) * 1_000_000) } catch { return }
                    guard !Task.isCancelled, self.runtimeLiveness.generation == runtime,
                          self.room.connectionState == .connected else { continue }
                    self.pushToTalk.setServiceConnection(.connected)
                    if let session = self.joinedSession {
                        _ = try? await withCurrentFloorStatus(
                            context: { self.floorStatusContext },
                            request: { try await self.api.floorStatus(sessionId: session.sessionId) },
                            apply: { self.rx?.reconcileFloor($0) }
                        )
                    }
                    guard !Task.isCancelled, self.runtimeLiveness.generation == runtime else { return }
                    self.resetPttRequestGate()
                    if self.audio.completeRecovery(generation: generation) {
                        await self.finishRecoveredPTTState()
                        guard !Task.isCancelled, self.runtimeLiveness.generation == runtime else { return }
                        self.lastError = nil
                        self.postCallRearmState = .rearmed
                    }
                    return
                }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            self.audio.failRecovery(generation: generation, error: "LiveKit RX did not recover within 5 seconds")
            self.postCallRearmState = .failed
            self.lastError = "音声の自動復旧に失敗しました。音声を再接続してください。"
        }
    }

    private func finishRecoveredPTTState() async {
        let runtime = runtimeLiveness.generation
        let controller = ptt
        await controller?.resetAfterReconnect()
        guard !Task.isCancelled, runtimeLiveness.generation == runtime else { return }
        pttStoppedForAudioInterruption = false
        resetPttRequestGate()
    }

    private func startServiceStatusPolling() {
        floorStatusTask?.cancel()
        floorStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pushToTalk.setServiceConnection(self.room.connectionState)
                if let session = self.joinedSession {
                    do {
                        _ = try await withCurrentFloorStatus(
                            context: { self.floorStatusContext },
                            request: { try await self.api.floorStatus(sessionId: session.sessionId) },
                            apply: { await self.applyAuthoritativeFloor($0) }
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        if shouldRestoreExpiredBackendSession(error,
                            requestedSessionId: session.sessionId,
                            currentSessionId: self.joinedSession?.sessionId,
                            poweredOn: self.isPoweredOn),
                           let descriptor = PttRestoreDescriptor.load(from: .standard) ?? self.recoveryIntent.descriptor,
                           descriptor.channelId == session.channel.id {
                            self.runtimeLiveness.invalidate()
                            self.requestRuntimeRestore(descriptor, reason: .backendSessionExpired)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private enum StatusCueKind { case busy, error }

    private func playStatusCue(_ kind: StatusCueKind) {
        guard audio.pushToTalkAudioSessionActive else {
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(kind == .busy ? .warning : .error)
            lastStatusCueResult = "haptic_only: Apple audio session inactive"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .busy: try await statusCuePlayer.playBusy()
                case .error: try await statusCuePlayer.playError()
                }
                lastStatusCueResult = kind == .busy ? "BUSY played" : "ERROR played"
            } catch {
                lastStatusCueResult = "Failed: \(safeMessage(error))"
            }
        }
    }

    private func applyPttSnapshot(_ snapshot: PTTSnapshot) {
        let previous = pttSnapshot.state
        let priorLease = pttSnapshot.leaseId
        pttSnapshot = snapshot
        if previous != snapshot.state || priorLease != snapshot.leaseId {
            journal("TX", lease: snapshot.leaseId ?? priorLease)
        }

            if snapshot.state == .requestingFloor && previous != .requestingFloor { inputGain.beginTransmission() }
            if ![.requestingFloor, .transmitting, .releasing].contains(snapshot.state) {
                inputGain.endTransmission(learn: snapshot.lastError == nil)
            }

        if pendingAppAppleStop, snapshot.microphoneMutedAt != nil {
            pendingAppAppleStop = false
            appleStopRequestedAt = Date()
            pushToTalk.stopTransmitting()
        }
        if snapshot.floorReleaseCompletedAt != nil { lastReleaseSnapshot = snapshot }
        if snapshot.state == .busy, previous != .busy { playStatusCue(.busy) }
        if snapshot.state == .error, previous != .error { playStatusCue(.error) }
        if snapshot.state == .transmitting { activationWatchdogTask?.cancel() }
        if snapshot.txTerminalCleanupComplete, snapshot.state == .error { beginRecoverableAppleAbort() }
    }

    private func handlePttGateActions(
        _ actions: [PttRequestGateAction],
        source: String
    ) {
        pttRequestGateState = pttRequestGate.state
        for action in actions {
            switch action {
            case .requestBegin:
                appleBeginRequestedAt = Date()
                pushToTalk.requestBeginTransmitting()
            case .stopSystemTransmission:
                if source == "userRequest",
                   pttSnapshot.state == .transmitting || pttSnapshot.state == .releasing {
                    // App touch UP keeps Apple's session for the bounded RTP tail only.
                    pendingAppAppleStop = true
                    startFloorCleanup(source: "developerRequest")
                } else {
                    appleStopRequestedAt = Date()
                    pushToTalk.stopTransmitting()
                }
            case .beginFloor:
                Task {
                    await ptt?.pttDown(
                        playReadyCue: false,
                        maximumReadyWaitMilliseconds: source == "developerRequest"
                            ? maximumReadyWaitMilliseconds
                            : 250
                    )
                }
            case .finishFloor:
                startFloorCleanup(source: source)
            case .busy:
                playStatusCue(.busy)
            case .pending:
                break
            case .error:
                playStatusCue(.error)
            }
        }
    }

    private func tryActivateAppTransmission() {
        guard appPrearmAwaitingApple,
              appPrearmReady,
              appAppleBeginReady,
              audio.pushToTalkAudioSessionActive,
              pttRequestGate.state == .transmitting,
              !pttRequestGate.releaseRequestedBeforeBegin,
              !appActivationCommitted else { return }
        appActivationCommitted = true
        let controller = ptt
        let runtime = runtimeLiveness.generation
        let attempt = txAttemptGeneration
        Task { [weak self] in
            guard let self, self.runtimeLiveness.generation == runtime,
                  self.txAttemptGeneration == attempt, self.appActivationCommitted else { return }
            await controller?.activatePrearmedTransmission()
        }
    }

    private func ensureReleaseGeneration() -> Int {
        if releaseCleanupTask == nil, !releaseFloorCompleted, !releaseAppleCompleted {
            releaseGeneration += 1
        }
        return releaseGeneration
    }

    private func startFloorCleanup(source: String) {
        let generation = ensureReleaseGeneration()
        guard releaseCleanupTask == nil, !releaseFloorCompleted else {
            tryFinishPttRelease(generation: generation)
            return
        }
        let controller = ptt
        let runtime = runtimeLiveness.generation
        releaseCleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.backgroundCleanup.performIfNeeded(
                name: "KOEON PTT cleanup",
                enabled: shouldUseBoundedBackgroundCleanup(
                    transmitSource: source,
                    appLifecycleState: self.appLifecycleState
                ),
                stateChanged: { [weak self] in self?.backgroundTaskState = $0 }
            ) {
                await controller?.pttUp(
                    playEndCue: source == "developerRequest" && self.audio.pushToTalkAudioSessionActive
                )
            }
            let confirmed = await controller?.cleanupIsConfirmed() != false
            guard self.runtimeLiveness.generation == runtime,
                  generation == self.releaseGeneration else { return }
            self.releaseCleanupTask = nil
            self.releaseFloorCompleted = confirmed
            if self.pendingAppAppleStop {
                self.pendingAppAppleStop = false
                self.appleStopRequestedAt = Date()
                self.pushToTalk.stopTransmitting()
            }
            self.tryFinishPttRelease(generation: generation)
        }
    }

    private func markAppleReleaseCompleted(source: String) {
        let generation = ensureReleaseGeneration()
        releaseAppleCompleted = true
        tryFinishPttRelease(generation: generation)
    }

    private func tryFinishPttRelease(generation: Int) {
        guard generation == releaseGeneration,
              releaseFloorCompleted,
              releaseAppleCompleted,
              pttRequestGate.state == .rearming else { return }
        releaseFloorCompleted = false
        releaseAppleCompleted = false
        finishPttRearming()
    }

    private func finishPttRearming() {
        actionButtonOwnsAttempt = false
        appPrearmAwaitingApple = false
        appPrearmReady = false
        appAppleBeginReady = false
        appActivationCommitted = false
        appleBeginIssuedForAttempt = false
        let actions = pttRequestGate.finishRearming()
        pttRequestGateState = pttRequestGate.state
        requestGateIdleAt = actions.contains(.requestBegin) ? nil : Date()
        audioRearmedAt = Date()
        readyAt = Date()
        txAttempts.finish()
        let controller = ptt
        let runtime = runtimeLiveness.generation
        if pttSnapshot.state == .error {
            readyAt = nil
            audioRearmedAt = nil
            Task { [weak self] in
                guard let self, self.runtimeLiveness.generation == runtime else { return }
                do {
                    try await self.audio.beginPushToTalkManagedSession()
                    guard self.runtimeLiveness.generation == runtime,
                          self.audio.interruption.state == .ready else { return }
                    self.audioRearmedAt = Date()
                    await controller?.completeRecoverableAbortAfterAppleRearm(appleSettled: true, audioRearmed: true)
                    if await controller?.currentSnapshot().state == .idle { self.readyAt = Date() }
                } catch { self.lastError = "TX_ABORT_AUDIO_REARM_FAILED" }
            }
        }
        if actions.contains(.requestBegin) {
            guard operationalState == .active,
                  isJoined,
                  joinedSession?.canPublish == true,
                  room.connectionState == .connected,
                  audio.interruption.state == .ready,
                  remoteReceiveSnapshot.remoteSpeakerSessionId == nil else {
                pttRequestGate.reset()
                pttRequestGateState = .idle
                requestGateIdleAt = Date()
                if remoteReceiveSnapshot.remoteSpeakerSessionId != nil { playStatusCue(.busy) }
                return
            }
            startParallelAppTransmissionAttempt()
        }
    }

    private func resetPttRequestGate() {
        actionButtonOwnsAttempt = false
        // Cancellation is cooperative: a pending Floor/API operation can still return.
        // Fence its completion before resetting the UI gate for a new runtime/press.
        txAttemptGeneration += 1
        pendingAppAppleStop = false
        releaseGeneration += 1
        activationWatchdogTask?.cancel()
        activationWatchdogTask = nil
        appPrearmTask?.cancel()
        appPrearmTask = nil
        appPrearmAwaitingApple = false
        appPrearmReady = false
        appAppleBeginReady = false
        appActivationCommitted = false
        appleBeginIssuedForAttempt = false
        releaseCleanupTask?.cancel()
        releaseCleanupTask = nil
        releaseFloorCompleted = false
        releaseAppleCompleted = false
        appPttTouchEdgeGate.reset()
        pttRequestGate.reset()
        pttRequestGateState = pttRequestGate.state
    }

    private func activateRemoteReceiveAudio(_ audioSession: AVAudioSession) {
        rx?.audioSessionDidActivate(
            engineEnabledAt: Date(),
            outputLatency: audioSession.outputLatency,
            ioBufferDuration: audioSession.ioBufferDuration,
            route: audio.route.rawValue
        )
    }

    private func handleRemoteMediaActivity(sessionId: String?, active: Bool) {
        rx?.handleRemoteAudioActivity(senderSessionId: sessionId, active: active)
        rxConsistencyGuard.handleMediaActivity(sessionId: sessionId, active: active, at: rxMonotonicDate)
        rxConsistencySnapshot = rxConsistencyGuard.snapshot
        scheduleRxDivergenceWatchdogIfNeeded()
    }

    private func applyRxSnapshot(_ snapshot: RxSnapshot) {
        let previous = rxSnapshot
        rxSnapshot = snapshot
        if previous.state != snapshot.state || previous.generation != snapshot.generation || previous.rxFirstPcmAt != snapshot.rxFirstPcmAt {
            var fields: [String: Any] = ["firstPcm": snapshot.rxFirstPcmAt != nil]
            if let at = snapshot.rxFirstPcmAt { fields["pcmAtMs"] = Int64(at.timeIntervalSince1970 * 1_000) }
            if let at = snapshot.rxStartedAt { fields["rxStartedAtMs"] = Int64(at.timeIntervalSince1970 * 1_000) }
            let firstPcm = snapshot.rxFirstPcmAt != nil && journalRxPcmGate.accept(
                runtime: runtimeLiveness.generation, generation: snapshot.generation)
            journal(firstPcm ? "RX_PCM" : "RX", fields: fields,
                lease: snapshot.leaseId ?? previous.leaseId, speaker: snapshot.sessionId ?? previous.sessionId)
        }
        if snapshot.generation > 0, snapshot.state != .idle,
           previous.generation != snapshot.generation || previous.state == .idle {
            rxAttempts.begin(generation: snapshot.generation, channelId: joinedSession?.channel.id ?? pendingJoinResponse?.channel.id ?? "",
                sessionGeneration: runtimeLiveness.generation)
        }
        if snapshot.state == .idle, previous.state != .idle {
            rxAttempts.finish()
            rxRecoveryEvent = nil
            scheduleTerminalFloorReconcile()
        }
        let validated = snapshot.state != .idle && snapshot.sessionId != nil && snapshot.generation > 0
        let resolved = snapshot.sessionId.map {
            remoteReceiveSnapshot.remoteSpeakerSessionId == $0 || room.trustedRemoteSpeaker(sessionId: $0) != nil
        } ?? false
        let subscribed = snapshot.sessionId.map {
            room.isRemoteAudioSubscriptionActive(sessionId: $0, generation: snapshot.generation)
        } ?? false
        rxConsistencyGuard.updateValidatedRx(
            active: validated,
            sessionId: snapshot.sessionId,
            generation: snapshot.generation,
            participantResolved: resolved,
            trackSubscribed: subscribed,
            at: rxMonotonicDate
        )
        if let pcmAt = snapshot.rxFirstPcmAt {
            _ = rxConsistencyGuard.handleRemotePcm(sessionId: snapshot.sessionId, generation: snapshot.generation, at: pcmAt)
            wakeAttempts.finish(at: pcmAt)
        }
        rxConsistencySnapshot = rxConsistencyGuard.snapshot
        scheduleRxDivergenceWatchdogIfNeeded()
    }

    private func applyRemoteReceiveSnapshot(_ snapshot: RemoteReceiveActivationSnapshot) {
        remoteReceiveSnapshot = snapshot
        applyRxSnapshot(rx?.currentSnapshot() ?? rxSnapshot)
    }

    private func handleRemoteParticipantAvailable(sessionId: String) {
        let resolved = remoteReceive?.handleParticipantAvailable(sessionId: sessionId) ?? false
        guard let current = rx?.currentSnapshot(),
              current.state != .idle,
              current.sessionId == sessionId,
              current.generation > 0 else { return }
        if resolved { applyRemoteReceiveSnapshot(remoteReceive?.currentSnapshot() ?? remoteReceiveSnapshot) }
        Task { [weak self, weak room] in
            _ = try? await room?.activateRemoteAudioSubscription(
                sessionId: sessionId,
                generation: current.generation
            )
            guard let self else { return }
            self.applyRxSnapshot(self.rx?.currentSnapshot() ?? self.rxSnapshot)
        }
    }

    private func scheduleRxDivergenceWatchdogIfNeeded() {
        guard !isStoppingRuntime, rxDivergenceWatchdogTask == nil, rxRecoveryTask == nil else { return }
        guard let deadline = rxConsistencyGuard.nextDeadline() else { return }
        let wait = max(1, Int(deadline.timeIntervalSince(rxMonotonicDate) * 1_000))
        rxDivergenceWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(wait)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.rxDivergenceWatchdogTask = nil
            self.evaluateRxDivergenceWatchdog()
        }
    }

    private func evaluateRxDivergenceWatchdog() {
        // Runtime replacement and incoming wake own recovery exclusively.
        guard rxRecoveryTask == nil, !shouldDeferRxRecovery(
            runtimeRestoring: isRestoringRuntime,
            incomingWakePending: incomingWakeRecoveryTask != nil
        ) else { return }
        let mediaSessionId = rxConsistencyGuard.snapshot.remoteMediaSpeakerSessionId
        let currentSpeaking = mediaSessionId.flatMap {
            room.remoteParticipantIsSpeaking(sessionId: $0)
        }
        let evaluation = rxConsistencyGuard.evaluate(
            at: rxMonotonicDate,
            remoteParticipantIsSpeaking: currentSpeaking
        )
        rxConsistencySnapshot = rxConsistencyGuard.snapshot
        for signal in evaluation.signals {
            appendRxDivergenceDiagnostic(
                event: signal.event,
                elapsedMilliseconds: signal.elapsedMilliseconds,
                state: signal.snapshot
            )
        }
        if let sessionId = evaluation.verifiedInactiveMediaSessionId {
            room.clearVerifiedInactiveRemoteMediaActivity(sessionId: sessionId)
        }
        if let sessionId = evaluation.recoverySessionId, evaluation.recoveryGeneration > 0 {
            performRxRecovery(level: evaluation.recoveryLevel, sessionId: sessionId, generation: evaluation.recoveryGeneration)
        }
        scheduleRxDivergenceWatchdogIfNeeded()
    }

    private func appendRxDivergenceDiagnostic(
        event: String,
        elapsedMilliseconds: Int,
        state: RxConsistencySnapshot
    ) {
        journal("RESTORE", fields: ["recoveryLevel": state.recoveryLevel,
            "reason": event.uppercased(), "trackSubscribed": state.trackSubscribed,
            "firstPcm": state.remotePcmObserved])
        let baseEligible = isPoweredOn && !isStoppingRuntime && operationalState == .active && isJoined && joinedSession?.canPublish == true &&
            room.connectionState == .connected && audio.interruption.state == .ready
        let sessionId = state.validatedRxSessionId ?? state.remoteMediaSpeakerSessionId
        let diagnostic = RxDivergenceDiagnostic(
            observedAt: Date(),
            runtimeGeneration: runtimeLiveness.generation,
            receiveGeneration: state.validatedRxGeneration,
            appLifecycleState: appLifecycleState,
            event: event,
            elapsedMs: elapsedMilliseconds,
            roomConnectionState: room.connectionState.rawValue,
            participantResolved: state.participantResolved,
            trackSubscribed: sessionId.map {
                room.isRemoteAudioSubscriptionActive(
                    sessionId: $0,
                    generation: state.validatedRxGeneration
                )
            } ?? false,
            rxGenerationActive: state.validatedRemoteRxActive,
            audioSessionState: audio.interruption.state.rawValue,
            pcmObserved: state.remotePcmObserved,
            mediaSpeakerActive: state.remoteMediaSpeakerActive,
            pttEligible: baseEligible && !state.remoteBusyBlocksLocalPtt
        )
        rxDivergenceDiagnostics.append(diagnostic)
        if rxDivergenceDiagnostics.count > 20 {
            rxDivergenceDiagnostics.removeFirst(rxDivergenceDiagnostics.count - 20)
        }
    }

    private func resetRxConsistency() {
        rxDivergenceWatchdogTask?.cancel()
        rxDivergenceWatchdogTask = nil
        rxConsistencyGuard.reset()
        rxConsistencySnapshot = rxConsistencyGuard.snapshot
    }

    private func invalidateRuntimeCallbacks() async {
        runtimeLiveness.beginRuntime()
        txAttempts.finish()
        rxAttempts.finish()
        activationWatchdogTask?.cancel()
        let watchdog = rxDivergenceWatchdogTask
        watchdog?.cancel()
        rxDivergenceWatchdogTask = nil
        await watchdog?.value
        let floorPoll = rxTerminalFloorTask
        floorPoll?.cancel()
        rxTerminalFloorTask = nil
        await floorPoll?.value
        await rx?.resetAndAwait()
    }

    private var rxMonotonicDate: Date { Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime) }


    private func validateCurrentRuntime() {
        runtimeLiveness.validate(bindingsReady: joinedSession != nil && room.connectionState == .connected &&
            rx != nil && remoteReceive != nil && ptt != nil)
    }

    private func performRxRecovery(level: Int, sessionId: String, generation: Int) {
        guard rxRecoveryTask == nil else { return }
        let runtime = runtimeLiveness.generation
        rxRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.runtimeLiveness.generation == runtime {
                    self.rxConsistencyGuard.recoveryDidComplete(
                        sessionId: sessionId, generation: generation, at: self.rxMonotonicDate)
                }
                self.rxRecoveryTask = nil
                self.scheduleRxDivergenceWatchdogIfNeeded()
            }
            guard !Task.isCancelled, self.runtimeLiveness.generation == runtime,
                  self.rxSnapshot.sessionId == sessionId, self.rxSnapshot.generation == generation,
                  self.rxSnapshot.rxFirstPcmAt == nil else { return }
            self.remoteReceive?.markNoPcmRecoveryAttempt()
            switch level {
            case 1:
                _ = self.remoteReceive?.handleParticipantAvailable(sessionId: sessionId)
            case 2, 3:
                if level == 3 {
                    self.runtimeLiveness.invalidate()
                    _ = try? await self.room.discardRemoteAudioSubscription(sessionId: sessionId, generation: generation)
                    self.remoteReceive?.resetPreservingSystemRemoteParticipant()
                }
                guard let event = self.rxRecoveryEvent, event.sessionId == sessionId else { return }
                _ = try? await self.room.activateRemoteAudioSubscription(sessionId: sessionId, generation: generation)
                self.remoteReceive?.handleValidatedStart(event, generation: generation)
            case 4:
                self.runtimeLiveness.invalidate()
                guard let event = self.rxRecoveryEvent,
                      self.rxRecoveryRebuiltLease != event.leaseId,
                      self.pttSnapshot.state != .transmitting, self.pttSnapshot.state != .releasing,
                      let descriptor = PttRestoreDescriptor.load(from: .standard) else {
                    await self.terminateUnviableRx()
                    return
                }
                self.rxRecoveryRebuiltLease = event.leaseId
                self.requestRuntimeRestore(descriptor, reason: .rxSelfHeal)
                await self.restoreTask?.value
                guard !Task.isCancelled, let joined = self.joinedSession,
                      joined.channel.id == event.channelId,
                      let floor = try? await self.api.floorStatus(sessionId: joined.sessionId),
                      floor.outcome == .busy, !floor.isOwner, floor.owner?.id == event.speakerUserId,
                      self.room.trustedRemoteSpeaker(sessionId: event.sessionId) != nil else {
                    await self.terminateUnviableRx()
                    return
                }
                // Replay only previously validated control, fenced again by current Floor
                // and current Room identity. Speaking hints never authorize a generation.
                self.rx?.handleControl(event, senderSessionId: event.sessionId)
                if self.audio.pushToTalkAudioSessionActive { self.activateRemoteReceiveAudio(AVAudioSession.sharedInstance()) }
            default:
                await self.terminateUnviableRx()
            }
            self.applyRxSnapshot(self.rx?.currentSnapshot() ?? self.rxSnapshot)
        }
    }

    private func terminateUnviableRx() async {
        rx?.reset()
        remoteReceive?.reset()
        resetRxConsistency()
        runtimeLiveness.invalidate()
        lastError = "RX_PATH_UNAVAILABLE_AFTER_BOUNDED_RECOVERY"
        scheduleTerminalFloorReconcile()
    }

    private func scheduleTerminalFloorReconcile() {
        rxTerminalFloorTask?.cancel()
        let runtime = runtimeLiveness.generation
        rxTerminalFloorTask = Task { [weak self] in
            for delay in [250, 500, 1_000, 2_000, 4_000] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, self.runtimeLiveness.generation == runtime,
                      let session = self.joinedSession else { return }
                var floorIsFree = false
                _ = try? await withCurrentFloorStatus(
                    context: { self.floorStatusContext },
                    request: { try await self.api.floorStatus(sessionId: session.sessionId) },
                    apply: { floor in
                        await self.applyAuthoritativeFloor(floor)
                        floorIsFree = floor.outcome == .available || floor.outcome == .released
                    }
                )
                if floorIsFree { return }
            }
        }
    }

    private var floorStatusContext: FloorStatusContext {
        FloorStatusContext(sessionId: joinedSession?.sessionId, runtime: runtimeLiveness.generation,
            txAttempt: txAttemptGeneration, rxGeneration: rx?.currentSnapshot().generation ?? 0)
    }

    private func applyAuthoritativeFloor(_ floor: FloorResponse) async {
        let context = floorStatusContext
        let controller = ptt
        remoteFloorBusy = floor.outcome == .busy && !floor.isOwner
        rx?.reconcileFloor(floor)
        await controller?.reconcileOwnFloor(floor)
        guard !Task.isCancelled, floorStatusContext == context else { return }
        if floor.outcome == .available || floor.outcome == .released, rxSnapshot.state == .idle {
            remoteReceive?.reset()
            resetRxConsistency()
        }
        if let snapshot = await controller?.currentSnapshot() {
            guard !Task.isCancelled, floorStatusContext == context else { return }
            applyPttSnapshot(snapshot)
            if snapshot.txTerminalCleanupComplete && snapshot.txErrorRecoverable == true {
                beginRecoverableAppleAbort()
            }
        }
    }

    private func beginRecoverableAppleAbort() {
        guard pttSnapshot.state == .error, pttSnapshot.txTerminalCleanupComplete,
              pttSnapshot.txErrorRecoverable == true else { return }
        activationWatchdogTask?.cancel()
        releaseFloorCompleted = true
        if pttRequestGate.state != .rearming {
            _ = pttRequestGate.didFail(recoverable: true)
            pttRequestGateState = pttRequestGate.state
            if appleBeginIssuedForAttempt || appleDidBeginAt != nil {
                appleStopRequestedAt = Date()
                pushToTalk.stopTransmitting()
            } else { releaseAppleCompleted = true }
        }
        tryFinishPttRelease(generation: releaseGeneration)
    }

    private func resetCurrentTxDiagnostics() {
        activationWatchdogTask?.cancel()
        pttSnapshot = .initial(role: joinedSession?.user.role ?? .staff)
        pendingAppAppleStop = false
        releaseGeneration += 1
        releaseFloorCompleted = false
        releaseAppleCompleted = false
        appleStopRequestedAt = nil
        appleLastEndAt = nil
        appleLastDeactivateAt = nil
        audioRearmedAt = nil
        requestGateIdleAt = nil
        readyAt = nil
    }

    private func resetCurrentWakeDiagnostics() {
        rxReadyStartReceivedAt = nil
        rxReadyAppleAudioReadyAt = nil
        rxReadyPublishAttemptedAt = nil
        rxReadyPublishedAt = nil
        resumeRequestAt = nil
        resumeResponseAt = nil
        resumeLiveKitConnectStartedAt = nil
        resumeLiveKitConnectedAt = nil
        firstPcmLifecycleState = nil
        firstPcmRxGeneration = nil
    }

    private func startUptimeTimer() {
        uptimeTask?.cancel()
        uptimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let joinedAt = self.joinedAt else { return }
                self.sessionUptimeSeconds = max(0, Int(Date().timeIntervalSince(joinedAt)))
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.journalHeartbeatAt >= 30 {
                    self.journalHeartbeatAt = now
                    let gain = self.inputGain.snapshot()
                    self.journal("HEARTBEAT", fields: ["gainDb": gain.effectiveGainDb, "mode": gain.mode.rawValue.uppercased()])
                }
            }
        }
    }

    var maximumReadyWaitMilliseconds: Int? {
        switch rxReadyPolicy {
        case .off: 0
        case .fast250: 250
        case .adaptive: 500
        }
    }

    func setInputGainMode(_ mode: InputGainMode) { inputGain.setMode(mode); objectWillChange.send() }
    func setManualInputGain(_ gain: Float) { inputGain.setManualGainDb(gain); objectWillChange.send() }
    func startInputGainCalibration() { inputGain.startCalibration(); objectWillChange.send() }
    func resetInputGainProfile() { inputGain.resetProfile(); objectWillChange.send() }

    private func publishReceiverReadyWithDiagnostics(
        room: LiveKitRoomController,
        speakerSessionId: String,
        leaseId: String
    ) async throws {
        let runtime = runtimeLiveness.generation
        rxReadyPublishAttemptedAt = Date()
        rxReadyPublishSessionIdGeneration = rxWakeGeneration
        rxReadyPublishDeviceIdPresent = (joinedSession?.deviceId ?? identity?.device.id) != nil
        do {
            try await room.publishRxReady(speakerSessionId: speakerSessionId, leaseId: leaseId)
            guard runtimeLiveness.generation == runtime else { return }
            rxReadyPublishedAt = Date()
            rxReadyPublishResult = "SUCCESS"
        } catch {
            // Only the error type is retained; tokens, endpoint details and payloads are excluded.
            if runtimeLiveness.generation == runtime {
                rxReadyPublishResult = "FAILED_\(type(of: error))"
            }
            throw error
        }
    }

    func copyFieldDiagnosticJSON() {
        let gain = inputGain.snapshot()
        let liveKitIngress = room.ingressDiagnosticSnapshot()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unavailable"
        func number(_ value: Int?) -> Any { value.map { $0 as Any } ?? NSNull() }
        func decimal(_ value: Float?) -> Any { value.map { Double($0) as Any } ?? NSNull() }
        func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        func optional(_ value: Bool?) -> Any { value.map { $0 as Any } ?? NSNull() }
        func timestamp(_ value: Date?) -> Any {
            optional(value.map { ISO8601DateFormatter().string(from: $0) })
        }

        func duration(_ start: Date?, _ end: Date?) -> Any {
            guard let start, let end else { return NSNull() }
            return max(0, Int(end.timeIntervalSince(start) * 1_000))
        }
        let diagnosticPttBlockReason: String? = pttEligible ? nil : pttBlockReason
        let releaseSnapshot = pttSnapshot
        func attempt(_ value: LifecycleAttemptRecord?) -> Any {
            guard let value else { return NSNull() }
            return ["attemptId": value.attemptId, "generation": value.generation,
                    "channelHash": value.channelHash, "sessionGeneration": value.sessionGeneration,
                    "startedAt": timestamp(value.startedAt), "completedAt": timestamp(value.completedAt)] as [String: Any]
        }
        let divergenceEvents: [[String: Any]] = rxDivergenceDiagnostics.map { event in
            [
                "observedAt": timestamp(event.observedAt),
                "runtimeGeneration": event.runtimeGeneration,
                "receiveGeneration": event.receiveGeneration,
                "appLifecycleState": event.appLifecycleState,
                "event": event.event,
                "elapsedMs": event.elapsedMs,
                "roomConnectionState": event.roomConnectionState,
                "participantResolved": event.participantResolved,
                "trackSubscribed": event.trackSubscribed,
                "rxGenerationActive": event.rxGenerationActive,
                "audioSessionState": event.audioSessionState,
                "pcmObserved": event.pcmObserved,
                "mediaSpeakerActive": event.mediaSpeakerActive,
                "pttEligible": event.pttEligible,
            ]
        }
        let payload: [String: Any] = [
            "currentTxAttempt": attempt(txAttempts.current),
            "lastCompletedTxAttempt": attempt(txAttempts.lastCompleted),
            "currentRxGeneration": attempt(rxAttempts.current),
            "lastCompletedRxGeneration": attempt(rxAttempts.lastCompleted),
            "currentWake": attempt(wakeAttempts.current),
            "lastCompletedWake": attempt(wakeAttempts.lastCompleted),
            "runtimeLiveness": [
                "powerOnRequested": isPoweredOn,
                "isRestoringRuntime": isRestoringRuntime,
                "automaticRetryAttempt": recoveryIntent.retryAttempt,
                "runtimeDirtySinceBackground": runtimeLiveness.dirty,
                "runtimeGeneration": runtimeLiveness.generation,
                "runtimeValidatedGeneration": runtimeLiveness.validatedGeneration,
                "lastValidatedRuntimeAt": timestamp(runtimeLiveness.lastValidatedAt),
                "rxPathState": rxConsistencySnapshot.pathState,
                "rxRecoveryLevel": rxConsistencySnapshot.recoveryLevel,
                "remoteFloorBusy": remoteFloorBusy,
            ],
            "lastCompletedRelease": [
                "attemptGeneration": lastReleaseSnapshot.attemptGeneration,
                "controlEndPublishedAt": timestamp(lastReleaseSnapshot.controlEndPublishedAt),
                "floorReleaseRequestedAt": timestamp(lastReleaseSnapshot.floorReleaseRequestedAt),
                "floorReleaseCompletedAt": timestamp(lastReleaseSnapshot.floorReleaseCompletedAt),
            ],
            "schema": fieldDiagnosticSchema,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "platform": "ios",
            "standardAudioTransport": "LIVEKIT_OPUS_RTP",
            "settings": [
                "appTxPath": appTxPath.rawValue,
                "rxReadyPolicy": rxReadyPolicy.rawValue,
                "restorePath": restorePath.rawValue,
                "rxStartCue": rxStartCueMode.rawValue,
                "volumeProbe": volumeProbeMode.rawValue,
            ],
            "audioPublish": [
                "selectedProfile": selectedAudioPublishProfile.rawValue,
                "appliedProfile": optional(appliedAudioPublishProfile?.rawValue),
                "maxBitrate": number(appliedAudioPublishProfile?.maxBitrate),
                "maxBitrateMeaning": "codec_upper_bound_not_wire_bitrate",
                "dtx": true,
                "red": true,
            ],
            "state": [
                "connection": room.connectionState.rawValue,
                "ptt": pttSnapshot.state.rawValue,
                "pttSemanticState": pttSemanticState.rawValue,
                "pttEligible": pttEligible,
                "pttBlockReason": optional(diagnosticPttBlockReason),
                "rx": rxSnapshot.state.rawValue,
                "audioAvailability": audio.interruption.state.rawValue,
                "audioRoute": audio.route.rawValue,
                "restoreState": pttRestoreState,
            ],
            "timingMs": [
                "floor": number(pttSnapshot.floorLatencyMilliseconds),
                "rxReadyWait": number(pttSnapshot.rxReadyWaitMilliseconds),
                "controlPublishFast": number(pttSnapshot.controlPublishFastMilliseconds),
                "controlPublishReliable": number(pttSnapshot.controlPublishReliableMilliseconds),
                "controlToAppleActivate": number(rxSnapshot.controlToAppleActivateMilliseconds),
                "appleActivateToFirstPcm": number(rxSnapshot.appleActivateToFirstPcmMilliseconds),
                "controlToFirstPcm": number(rxSnapshot.controlToFirstPcmMilliseconds),
                "estimatedOutputPipeline": number(rxSnapshot.estimatedOutputPipelineMilliseconds),
                "playoutDrainTarget": rxSnapshot.rxPlayoutDrainTargetMilliseconds,
                "pttDownToLocalUiFeedback": duration(pttSnapshot.pttDownAt, pttSnapshot.localUiFeedbackAt),
                "pttDownToTalking": duration(pttSnapshot.pttDownAt, pttSnapshot.talkingAt),
                "floorRequestToGrant": duration(pttSnapshot.floorRequestAt, pttSnapshot.floorGrantedAt),
                "floorGrantToReadyBarrierComplete": duration(
                    pttSnapshot.floorGrantedAt,
                    pttSnapshot.readyBarrierCompletedAt
                ),
                "floorGrantToAppleBeginRequest": duration(pttSnapshot.floorGrantedAt, appleBeginRequestedAt),
                "appleBeginRequestToDidBegin": duration(appleBeginRequestedAt, appleDidBeginAt),
                "appleDidBeginToActivate": number(pairedDurationMilliseconds(
                    start: appleDidBeginAt,
                    end: appleDidActivateAt,
                    startGeneration: appleDidBeginAttemptGeneration,
                    endGeneration: appleDidActivateAttemptGeneration
                )),
                "pttUpToReady": duration(releaseSnapshot.pttUpAt, readyAt),
            ],
            "txLifecycle": [
                "attemptGeneration": pttSnapshot.attemptGeneration,
                "pttDownAt": timestamp(pttSnapshot.pttDownAt),
                "localUiFeedbackAt": timestamp(pttSnapshot.localUiFeedbackAt),
                "floorRequestAt": timestamp(pttSnapshot.floorRequestAt),
                "floorGrantedAt": timestamp(pttSnapshot.floorGrantedAt),
                "readyBarrierStartedAt": timestamp(pttSnapshot.readyBarrierStartedAt),
                "readyBarrierCompletedAt": timestamp(pttSnapshot.readyBarrierCompletedAt),
                "coldWakeBarrierRequired": pttSnapshot.coldWakeBarrierRequired,
                "readyBarrierResult": pttSnapshot.readyBarrierResult,
                "readyBarrierWaitMs": number(pttSnapshot.rxReadyWaitMilliseconds),
                "readyParticipantCount": pttSnapshot.rxReadyReceivedCount,
                "readyMissingCount": max(0, pttSnapshot.rxReadyExpectedCount - pttSnapshot.rxReadyReceivedCount),
                "wakeRecipientCount": pttSnapshot.wakeRecipientCount,
                "firstRxReadyAt": timestamp(pttSnapshot.rxReadyFirstAt),
                "txStartCueAt": timestamp(pttSnapshot.cueStartAt ?? appleDidBeginAt),
                "controlStartPublishedAt": timestamp(pttSnapshot.controlStartSentAt),
                "appleBeginRequestedAt": timestamp(appleBeginRequestedAt),
                "appleDidBeginAt": timestamp(appleDidBeginAt),
                "appleDidBeginAttemptGeneration": number(appleDidBeginAttemptGeneration),
                "appleDidActivateAt": timestamp(appleDidActivateAt),
                "appleDidActivateAttemptGeneration": number(appleDidActivateAttemptGeneration),
                "liveKitEngineReadyAt": timestamp(liveKitEngineReadyAt),
                "micUnmutedAt": timestamp(pttSnapshot.trackEnabledAt),
                "talkingAt": timestamp(pttSnapshot.talkingAt),
            ],
            "backgroundRxReady": [
                "rxReadyStartReceivedAt": timestamp(rxReadyStartReceivedAt),
                "rxReadyAppleAudioReadyAt": timestamp(rxReadyAppleAudioReadyAt),
                "rxReadyPublishAttemptedAt": timestamp(rxReadyPublishAttemptedAt),
                "rxReadyPublishedAt": timestamp(rxReadyPublishedAt),
                "rxReadyPublishResult": rxReadyPublishResult,
                "rxReadyPublishSessionIdGeneration": number(rxReadyPublishSessionIdGeneration),
                "rxReadyPublishDeviceIdPresent": optional(rxReadyPublishDeviceIdPresent),
            ],
            "releaseLifecycle": [
                "generation": releaseGeneration,
                "pttUpAt": timestamp(releaseSnapshot.pttUpAt),
                "micMutedAt": timestamp(releaseSnapshot.microphoneMutedAt),
                "controlEndPublishedAt": timestamp(releaseSnapshot.controlEndPublishedAt),
                "floorReleaseRequestedAt": timestamp(releaseSnapshot.floorReleaseRequestedAt),
                "floorReleaseCompletedAt": timestamp(releaseSnapshot.floorReleaseCompletedAt),
                "appleStopRequestedAt": timestamp(appleStopRequestedAt),
                "appleDidEndAt": timestamp(appleLastEndAt),
                "appleDidDeactivateAt": timestamp(appleLastDeactivateAt),
                "requestGateIdleAt": timestamp(requestGateIdleAt),
                "audioRearmedAt": timestamp(audioRearmedAt),
                "readyAt": timestamp(readyAt),
                "nextPttDownAt": timestamp(nextPttDownAt),
                "txReleasePhase": releaseSnapshot.txReleasePhase,
                "txReleaseAttemptGeneration": number(releaseSnapshot.txReleaseAttemptGeneration),
                "txReleaseEnteredSequence": number(releaseSnapshot.txReleaseEnteredSequence),
                "txFloorRenewDuringReleaseCount": releaseSnapshot.txFloorRenewDuringReleaseCount,
                "txControlEndPublishedSequence": number(releaseSnapshot.txControlEndPublishedSequence),
                "txFloorReleaseRequestedSequence": number(releaseSnapshot.txFloorReleaseRequestedSequence),
                "txFloorReleaseCompletedSequence": number(releaseSnapshot.txFloorReleaseCompletedSequence),
                "txReleaseCompletedSequence": number(releaseSnapshot.txReleaseCompletedSequence),
                "txReleaseResult": releaseSnapshot.txReleaseResult,
                "txTerminalCleanupComplete": releaseSnapshot.txTerminalCleanupComplete,
                "txErrorRecoverable": optional(releaseSnapshot.txErrorRecoverable),
            ],
            "backgroundWake": [
                "appLifecycleState": appLifecycleState,
                "lastBackgroundAt": timestamp(lastBackgroundAt),
                "lastForegroundAt": timestamp(lastForegroundAt),
                "lastPttIncomingPushAt": timestamp(lastPttIncomingPushAt),
                "pttChannelRestoredAt": timestamp(pttChannelRestoredAt),
                "liveKitReconnectStartedAt": timestamp(liveKitReconnectStartedAt),
                "liveKitReconnectCompletedAt": timestamp(liveKitReconnectCompletedAt),
                "reconnectAttemptId": number(reconnectAttempt?.id),
                "reconnectStartedAt": timestamp(reconnectAttempt?.startedAt),
                "reconnectCompletedAt": timestamp(reconnectAttempt?.completedAt),
                "reconnectDurationMs": number(reconnectAttempt?.durationMilliseconds),
                "reconnectReason": optional(reconnectAttempt?.reason),
                "reconnectResult": optional(reconnectAttempt?.result),
                "rxWakeGeneration": rxWakeGeneration,
                "rxWakeSource": rxWakeSource,
                "rxWakeFailureStage": optional(rxWakeFailureStage),
                "incomingPushLifecycleState": optional(incomingPushLifecycleState),
                "roomConnectionStateAtIncomingPush": roomConnectionStateAtIncomingPush,
                "runtimeRestoreReason": runtimeRestoreReason,
                "runtimeRestoreDecision": runtimeRestoreDecision,
                "runtimeRestorePath": runtimeRestorePath,
                "runtimeRestoreEarlyExitReason": runtimeRestoreEarlyExitReason,
                "roomConnectionStateAtRestoreEntry": roomConnectionStateAtRestoreEntry,
                "joinedSessionPresentAtRestoreEntry": joinedSessionPresentAtRestoreEntry,
                "resumeRequestAt": timestamp(resumeRequestAt),
                "resumeResponseAt": timestamp(resumeResponseAt),
                "staleRuntimeTeardownStartedAt": timestamp(staleRuntimeTeardownStartedAt),
                "staleRuntimeTeardownCompletedAt": timestamp(staleRuntimeTeardownCompletedAt),
                "resumeLiveKitConnectStartedAt": timestamp(resumeLiveKitConnectStartedAt),
                "resumeLiveKitConnectedAt": timestamp(resumeLiveKitConnectedAt),
                "appleDidActivateAt": timestamp(appleDidActivateAt),
                "firstPcmAt": timestamp(rxSnapshot.rxFirstPcmAt),
                "wakeId": optional(remoteReceiveSnapshot.wakeId),
                "participantPresentBeforeWake": optional(remoteReceiveSnapshot.participantPresentBeforeWake),
                "participantRebindStartedAt": timestamp(remoteReceiveSnapshot.participantRebindStartedAt),
                "participantRebindAttemptCount": remoteReceiveSnapshot.participantRebindAttemptCount,
                "participantRebindResolvedAt": timestamp(remoteReceiveSnapshot.participantRebindResolvedAt),
                "participantRebindResult": remoteReceiveSnapshot.participantRebindResult,
                "rxPathViableAt": timestamp(remoteReceiveSnapshot.rxPathViableAt),
                "noPcmRecoveryStartedAt": timestamp(remoteReceiveSnapshot.noPcmRecoveryStartedAt),
                "noPcmRecoveryResult": remoteReceiveSnapshot.noPcmRecoveryResult,
            ],
            "foregroundRecovery": [
                "lastBackgroundAt": timestamp(lastBackgroundAt),
                "lastForegroundAt": timestamp(lastForegroundAt),
                "lastForegroundRecoveryRequestedAt": timestamp(lastForegroundRecoveryRequestedAt),
                "lastForegroundRecoveryCompletedAt": timestamp(lastForegroundRecoveryCompletedAt),
                "lastForegroundRecoveryResult": optional(lastForegroundRecoveryResult),
            ],
            "liveKitIngress": [
                "lastDelegateEvent": optional(liveKitIngress.lastDelegateEvent),
                "lastDelegateIngressAt": timestamp(liveKitIngress.lastDelegateIngressAt),
                "lastDelegateMainApplyAt": timestamp(liveKitIngress.lastDelegateMainApplyAt),
            ],
            "network": [
                "rtt": NSNull(),
                "jitter": NSNull(),
                "packetLoss": NSNull(),
                "statsUnavailableReason": "not_exposed_by_current_livekit_integration",
            ],
            "txSafety": [
                "currentError": optional(pttSnapshot.state == .error ? pttSnapshot.lastError : nil),
                "lastError": optional(pttSnapshot.lastError),
                "lastStopReason": optional(pttSnapshot.lastStopReason),
                "floorRenewAttemptCount": pttSnapshot.floorRenewAttemptCount,
                "floorRenewSuccessCount": pttSnapshot.floorRenewSuccessCount,
                "floorLastRenewResult": optional(pttSnapshot.floorLastRenewResult),
                "floorLastRenewError": optional(pttSnapshot.floorLastRenewError),
                "appleLastEndSource": optional(appleLastEndSource),
                "appleLastTransmitFailureOperation": optional(appleLastTransmitFailureOperation),
                "appleLastTransmitFailureCode": optional(appleLastTransmitFailureCode),
                "appleLastTransmitFailureRecoverable": optional(appleLastTransmitFailureRecoverable),
                "appleLastIncomingPushAt": optional(pushToTalk.lastIncomingPushAt.map { ISO8601DateFormatter().string(from: $0) }),
                "appleLastIncomingPushLeasePrefix": optional(pushToTalk.lastIncomingPushLeaseId),
            ],
            "rxGeneration": [
                "generation": rxSnapshot.generation,
                "leasePrefix": optional(rxSnapshot.leaseId.map { String($0.prefix(8)) }),
                "rxEndReason": optional(rxSnapshot.rxEndReason),
                "lastFloorStatusOutcome": optional(rxSnapshot.lastFloorStatusOutcome),
                "lastFloorStatusOwnerUserId": optional(rxSnapshot.lastFloorStatusOwnerUserId),
                "lastFloorStatusIsOwner": optional(rxSnapshot.lastFloorStatusIsOwner),
                "lastFloorStatusLeaseVisible": optional(rxSnapshot.lastFloorStatusLeaseVisible),
                "lastFloorReconcileDecision": optional(rxSnapshot.lastFloorReconcileDecision),
                "lastFloorReconcileAt": optional(rxSnapshot.lastFloorReconcileAt.map { ISO8601DateFormatter().string(from: $0) }),
                "controlClockDeltaMs": number(rxSnapshot.rxControlNetworkMilliseconds),
                "controlClockDeltaKind": "cross_clock_estimate_not_network_latency",
                "floorToPushClockDeltaMs": number(rxSnapshot.rxFloorToPushMilliseconds),
                "duplicate": rxSnapshot.duplicateIgnored,
                "stale": rxSnapshot.staleIgnored,
                "preempted": rxSnapshot.preempted,
                "remoteClearRequestedAt": optional(remoteReceiveSnapshot.remoteClearRequestedAt.map { ISO8601DateFormatter().string(from: $0) }),
                "remoteParticipantClearedAt": optional(remoteReceiveSnapshot.remoteParticipantClearedAt.map { ISO8601DateFormatter().string(from: $0) }),
                "ghostActivityIgnored": remoteReceiveSnapshot.ghostActivityIgnored,
                "remoteParticipantSetState": remoteReceiveSnapshot.remoteParticipantState,
                "remoteParticipantSetRequestedAt": optional(remoteReceiveSnapshot.remoteParticipantSetRequestedAt.map { ISO8601DateFormatter().string(from: $0) }),
                "remoteParticipantSetCompletedAt": optional(remoteReceiveSnapshot.remoteParticipantSetCompletedAt.map { ISO8601DateFormatter().string(from: $0) }),
                "remoteParticipantSetErrorCode": optional(remoteReceiveSnapshot.remoteParticipantSetErrorCode),
                "remoteParticipantSetGeneration": remoteReceiveSnapshot.remoteParticipantSetGeneration,
                "appleAudioActivationGeneration": remoteReceiveSnapshot.appleAudioActivationGeneration,
                "rxFirstPcmGeneration": remoteReceiveSnapshot.rxFirstPcmGeneration,
                "incomingPushGeneration": number(incomingPushRxGeneration),
                "incomingPushAppLifecycleState": optional(incomingPushLifecycleState),
                "appleActivateGeneration": number(appleActivateRxGeneration),
                "appleActivateAppLifecycleState": optional(appleActivateLifecycleState),
                "firstPcmGeneration": number(firstPcmRxGeneration),
                "firstPcmAppLifecycleState": optional(firstPcmLifecycleState),
                "rxStaleMediaDropped": remoteReceiveSnapshot.rxStaleMediaDropped,
                "rxLateCompletionIgnored": remoteReceiveSnapshot.rxLateCompletionIgnored,
            ],
            "rxDivergence": [
                "watchdogThresholdMs": rxDivergenceWatchdogMilliseconds,
                "episode": rxConsistencySnapshot.episode,
                "remoteMediaSpeakerActive": rxConsistencySnapshot.remoteMediaSpeakerActive,
                "validatedRemoteRxActive": rxConsistencySnapshot.validatedRemoteRxActive,
                "rxPathReconciliationActive": rxConsistencySnapshot.rxPathReconciliationActive,
                "remotePcmObserved": rxConsistencySnapshot.remotePcmObserved,
                "trackSubscribed": rxConsistencySnapshot.trackSubscribed,
                "localPttEligible": pttEligible,
                "recoveryAttempts": rxConsistencySnapshot.recoveryAttempts,
                "events": divergenceEvents,
            ],
            "liveKit": [
                "deployment": room.deployment,
                "endpointHost": optional(room.endpointHost),
                "serverVersion": optional(room.serverVersion),
                "connectionState": room.connectionState.rawValue,
            ],
            "audio": [
                "route": audio.route.rawValue,
                "availability": audio.interruption.state.rawValue,
                "sessionCategory": audio.diagnosticCategory,
                "sessionMode": audio.diagnosticMode,
                "sessionSampleRate": audio.diagnosticSampleRate,
                "sessionIoBufferDuration": audio.diagnosticIoBufferDuration,
                "inputPortTypes": audio.diagnosticInputPortTypes,
                "outputPortTypes": audio.diagnosticOutputPortTypes,
                "availableInputPortTypes": audio.diagnosticAvailableInputPortTypes,
                "liveKitEngineAvailability": audio.liveKitEngineAvailability,
                "processing": [
                    "echoCancellation": true,
                    "echoCancellationOwner": "APPLE_VPIO_PLATFORM_PRIMARY",
                    "noiseSuppression": true,
                    "noiseSuppressionOwner": "APPLE_VPIO_PLATFORM_PRIMARY",
                    "autoGainControl": true,
                    "autoGainControlOwner": "APPLE_VPIO_PLATFORM_PRIMARY",
                    "highPassFilter": true,
                    "highPassFilterOwner": "LIVEKIT_WEBRTC_AUTOMATIC",
                    "enhancedNoiseCancellation": NSNull(),
                    "capturePostProcessor": "KOEON_INPUT_GAIN_ONLY",
                ],
            ],
            "audioGain": [
                "mode": gain.mode.rawValue,
                "route": gain.route,
                "captureActive": pttSnapshot.state == .transmitting,
                "meterStatus": pttSnapshot.state == .transmitting ? "CAPTURING" : "NOT_CAPTURING",
                "effectiveDb": gain.effectiveGainDb,
                "rmsDbfs": decimal(gain.rmsDbfs),
                "peakDbfs": decimal(gain.peakDbfs),
                "limiterHits": gain.limiterHits,
                "lastLearningDecision": gain.lastLearningDecision,
                "lastCompletedSampleCount": gain.lastCompletedSampleCount,
            ],
            "crashBreadcrumbs": [
                "previousRunTermination": AudioLifecycleBreadcrumbStore.shared.previousRunTermination,
                "previousRunLastLifecycleState": AudioLifecycleBreadcrumbStore.shared.previousRunLastLifecycleState,
                "events": AudioLifecycleBreadcrumbStore.shared.snapshot().map { event in
                    [
                        "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
                        "platform": event.platform,
                        "build": event.build,
                        "generation": optional(event.generationToken),
                        "role": event.role,
                        "stage": event.stage,
                        "actorClass": event.actorClass,
                        "resultClass": event.resultClass,
                    ] as [String: Any]
                },
            ],
            "platformSpecific": [
                "build": "\(version) (\(build))",
                "applePttRequestGate": pttRequestGateState.rawValue,
                "liveKitEngineAvailability": audio.liveKitEngineAvailability,
                "remoteParticipantState": remoteReceiveSnapshot.remoteParticipantState,
                "reconnectCount": room.reconnectCount,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            fieldDiagnosticCopyResult = "Failed"
            return
        }
        UIPasteboard.general.string = string
        do {
            _ = try FieldDiagnosticSnapshotFile.write(data)
            fieldDiagnosticCopyResult = "Copied · diagnostic file saved"
        } catch {
            // Preserve the clipboard result even if local export is unavailable.
            fieldDiagnosticCopyResult = "Copied · diagnostic file unavailable"
        }
    }

    private func persistFieldLab() {
        let defaults = UserDefaults.standard
        defaults.set(appTxPath.rawValue, forKey: "field.appTxPath")
        defaults.set(rxReadyPolicy.rawValue, forKey: "field.rxReadyPolicy")
        defaults.set(restorePath.rawValue, forKey: "field.restorePath")
        defaults.set(rxStartCueMode.rawValue, forKey: "field.rxStartCue")
        defaults.set(volumeProbeMode.rawValue, forKey: "field.volumeProbe")
    }

    private func safeMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }
}

@MainActor
private final class BoundedBackgroundCleanup {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func performIfNeeded(
        name: String,
        enabled: Bool,
        stateChanged: @escaping @MainActor (String) -> Void,
        operation: @escaping @MainActor () async -> Void
    ) async {
        guard enabled else {
            await operation()
            return
        }
        end(stateChanged: stateChanged)
        stateChanged("active")
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                stateChanged("expired_tx_already_off")
                self?.end(stateChanged: stateChanged)
            }
        }
        await operation()
        stateChanged("completed")
        end(stateChanged: stateChanged)
    }

    private func end(stateChanged: @escaping @MainActor (String) -> Void) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
