import Foundation

let fieldDiagnosticSchema = "koeon.field-diagnostic.v2"

enum KOEONRole: String, Codable, Sendable {
    case admin = "ADMIN"
    case staff = "STAFF"
    case listener = "LISTENER"

    var canPublish: Bool { self != .listener }
}

struct Tenant: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct Workspace: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let tenantId: String
    let name: String
}

struct Channel: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let workspaceId: String?
    let name: String
}

struct User: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let workspaceId: String
    let name: String
    let role: KOEONRole
    let channelIds: [String]?
}

struct FixtureResponse: Codable, Sendable {
    let tenant: Tenant
    let workspace: Workspace
    let channels: [Channel]
    let users: [User]
}

struct JoinRequest: Codable, Equatable, Sendable {
    let channelId: String
    let wantsToPublish: Bool
    let rxReadyProtocolVersion: Int? = 1
}

struct ResumeRequest: Codable, Equatable, Sendable {
    let channelId: String
    let previousSessionId: String?
    let rxReadyProtocolVersion: Int? = 1
}

struct IdentityUser: Codable, Sendable { let id: String; let displayName: String; let role: KOEONRole }
struct IdentityWorkspace: Codable, Sendable { let id: String; let name: String }
struct IdentityDevice: Codable, Sendable { let id: String; let name: String?; let platform: String }
struct IdentityChannel: Codable, Identifiable, Sendable { let id: String; let name: String; let type: String }
struct MeResponse: Codable, Sendable {
    let user: IdentityUser
    let workspace: IdentityWorkspace
    let device: IdentityDevice
    let channels: [IdentityChannel]
}
struct EnrollmentRequest: Codable, Sendable {
    let token: String?
    let code: String?
    let platform: String
    let deviceName: String
    let osVersion: String
    let appVersion: String

    init(
        token: String? = nil,
        code: String? = nil,
        platform: String = "ios",
        deviceName: String,
        osVersion: String,
        appVersion: String
    ) {
        self.token = token
        self.code = code
        self.platform = platform
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.appVersion = appVersion
    }
}
struct EnrollmentResponse: Codable, Sendable {
    let identity: MeResponse
    let credentialExpiresAt: String
    let deviceCredential: String
}

struct JoinResponse: Codable, Sendable {
    let sessionId: String
    let livekitUrl: String
    let token: String
    let roomName: String
    let user: User
    let channel: Channel
    let canPublish: Bool
    let tokenExpiresInSeconds: Int
    var tokenExpiresAt: Date? = nil
    var deviceId: String? = nil
}

struct SessionRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct PttTokenRegistrationRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let channelId: String
    let platform = "ios"
    let token: String
}

struct PttTokenUnregisterRequest: Codable, Equatable, Sendable {
    let sessionId: String
}

struct LeaseRequest: Codable, Equatable, Sendable {
    let sessionId: String
    let leaseId: String
}

enum FloorOutcome: String, Codable, Sendable {
    case granted
    case busy
    case released
    case renewed
    case available
    case notOwner = "not_owner"
}

struct FloorOwner: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct FloorResponse: Codable, Sendable {
    let outcome: FloorOutcome
    let owner: FloorOwner?
    let leaseId: String?
    let acquiredAt: Date?
    let leaseExpiresAt: Date?
    let maxTxExpiresAt: Date?
    let lastRenewedAt: Date?
    let isOwner: Bool
    let rxReadyExpectedSessionIds: [String]?
    let rxReadyExpectedDeviceIds: [String]?
    let wakeRecipientCount: Int?

    init(
        outcome: FloorOutcome, owner: FloorOwner?, leaseId: String?, acquiredAt: Date?,
        leaseExpiresAt: Date?, maxTxExpiresAt: Date?, lastRenewedAt: Date?, isOwner: Bool,
        rxReadyExpectedSessionIds: [String]? = nil,
        rxReadyExpectedDeviceIds: [String]? = nil,
        wakeRecipientCount: Int? = nil
    ) {
        self.outcome = outcome; self.owner = owner; self.leaseId = leaseId; self.acquiredAt = acquiredAt
        self.leaseExpiresAt = leaseExpiresAt; self.maxTxExpiresAt = maxTxExpiresAt
        self.lastRenewedAt = lastRenewedAt; self.isOwner = isOwner
        self.rxReadyExpectedSessionIds = rxReadyExpectedSessionIds
        self.rxReadyExpectedDeviceIds = rxReadyExpectedDeviceIds
        self.wakeRecipientCount = wakeRecipientCount
    }
}

struct FloorReleaseResponse: Codable, Sendable {
    let outcome: FloorOutcome
}

enum KOEONConnectionState: String, Sendable {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case connected = "CONNECTED"
    case reconnecting = "RECONNECTING"
}

enum PTTState: String, Sendable {
    case idle = "IDLE"
    case requestingFloor = "REQUESTING_FLOOR"
    case transmitting = "TRANSMITTING"
    case busy = "BUSY"
    case rxOnly = "RX_ONLY"
    case error = "ERROR"
}

enum PTTSemanticState: String, Sendable {
    case ready = "READY"
    case talking = "TALKING"
    case busyRemote = "BUSY_REMOTE"
    case preparing = "PREPARING"
    case error = "ERROR"
    case recovering = "RECOVERING"
    case offline = "OFFLINE"
    case rxOnly = "RX_ONLY"
}

enum OperationalState: String, Sendable {
    case unenrolled = "UNENROLLED"
    case enrolledPoweredOff = "ENROLLED_POWERED_OFF"
    case connecting = "CONNECTING"
    case active = "ACTIVE"
    case switchingChannel = "SWITCHING_CHANNEL"
    case audioInterrupted = "AUDIO_INTERRUPTED"
    case recoveringAudio = "RECOVERING_AUDIO"
    case error = "ERROR"
}

enum PostCallRearmState: String, Sendable {
    case ready = "READY"
    case interrupted = "INTERRUPTED"
    case waitingRoom = "WAITING_ROOM"
    case stabilizing = "STABILIZING"
    case rearmed = "REARMED"
    case failed = "FAILED"
}

enum ChannelSwitchPolicy {
    static func ordered(_ channels: [Channel]) -> [Channel] {
        channels.sorted { left, right in
            let comparison = left.name.localizedStandardCompare(right.name)
            return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
        }
    }

    static func adjacent(_ channels: [Channel], currentId: String, direction: Int) -> String? {
        let values = ordered(channels)
        guard !values.isEmpty else { return nil }
        let current = values.firstIndex { $0.id == currentId } ?? 0
        return values[(current + direction + values.count) % values.count].id
    }
}

enum RxState: String, Sendable {
    case idle = "RX_IDLE"
    case arming = "RX_ARMING"
    case waitingFirstAudio = "RX_WAITING_FIRST_AUDIO"
    case active = "RX_ACTIVE"
    case endPending = "RX_END_PENDING"
    case draining = "RX_DRAINING"
}

struct RxSnapshot: Sendable {
    var generation = 0
    var state: RxState = .idle
    var speakerUserId: String?
    var sessionId: String?
    var leaseId: String?
    var rxStartedAt: Date?
    var rxEndSignalAt: Date?
    var rxDrainStartedAt: Date?
    var rxDrainCompletedAt: Date?
    var rxDrainDurationMilliseconds: Int?
    var rxEndReason: String?
    var controlEventType: String?
    var controlSequence: Int64?
    var controlEventLate = false
    var controlEventFallback = false
    var duplicateIgnored = 0
    var staleIgnored = 0
    var preempted = 0
    var startCueResult: CueResult = .notPlayed
    var endCueResult: CueResult = .notPlayed
    var rxControlStartReceivedAt: Date?
    var rxRemoteParticipantRequestedAt: Date?
    var rxAppleAudioActivatedAt: Date?
    var rxLiveKitEngineEnabledAt: Date?
    var rxFirstPcmAt: Date?
    var rxControlEndReceivedAt: Date?
    var rxFloorEndObservedAt: Date?
    var rxLastAudioAt: Date?
    var rxPlaybackCompletedAt: Date?
    var rxRemoteParticipantClearedAt: Date?
    var endBeforeAppleActivate = false
    var endBeforeFirstPcm = false
    var shortBurstProtectionUsed = false
    var shortBurstProtectionMilliseconds: Int?
    var rxControlEventSentAt: Date?
    /// Cross-device wall-clock delta. This is not a one-way network latency.
    var rxControlNetworkMilliseconds: Int?
    var rxFloorAcquiredAtFromPush: Date?
    var rxIncomingPushAt: Date?
    var rxFloorToPushMilliseconds: Int?
    var rxReadySentAt: Date?
    var rxStartCueStartedAt: Date?
    var rxStartCueCompletedAt: Date?
    var rxAppleOutputLatencyMilliseconds: Int?
    var rxAppleIoBufferDurationMilliseconds: Int?
    var rxAudioRoute: String?
    var estimatedOutputPipelineMilliseconds: Int?
    var rxPlayoutDrainTargetMilliseconds = rxDrainMinimumMilliseconds
    var lastFloorStatusOutcome: String?
    var lastFloorStatusOwnerUserId: String?
    var lastFloorStatusIsOwner: Bool?
    var lastFloorStatusLeaseVisible: Bool?
    var lastFloorReconcileDecision: String?
    var lastFloorReconcileAt: Date?

    var controlToAppleActivateMilliseconds: Int? {
        Self.delta(rxControlStartReceivedAt, rxAppleAudioActivatedAt)
    }

    var appleActivateToFirstPcmMilliseconds: Int? {
        Self.delta(rxAppleAudioActivatedAt, rxFirstPcmAt)
    }

    var controlToFirstPcmMilliseconds: Int? {
        Self.delta(rxControlStartReceivedAt, rxFirstPcmAt)
    }

    private static func delta(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }
}

struct TrustedRemoteSpeaker: Equatable, Sendable {
    let sessionId: String
    let displayName: String
}

struct RemoteParticipantRequestContext: Equatable, Sendable {
    let generation: Int
    let sessionId: String
    let leaseId: String
    let clearing: Bool
}

struct RemoteParticipantSetResult: Equatable, Sendable {
    let requestId: Int
    let context: RemoteParticipantRequestContext
    let errorCode: String?
}

struct RemoteAudioSubscriptionGenerationGate: Sendable {
    private var activeBySession: [String: Int] = [:]

    mutating func activate(sessionId: String, generation: Int) {
        activeBySession[sessionId] = generation
    }

    func acceptsDiscard(sessionId: String, generation: Int) -> Bool {
        activeBySession[sessionId] == generation
    }

    mutating func completeDiscard(sessionId: String, generation: Int) -> Bool {
        guard activeBySession[sessionId] == generation else { return false }
        activeBySession.removeValue(forKey: sessionId)
        return true
    }

    mutating func reset() { activeBySession.removeAll() }
}

struct RemoteReceiveActivationSnapshot: Equatable, Sendable {
    var remoteSpeakerSessionId: String?
    var remoteSpeakerName: String?
    var remoteParticipantState = "INACTIVE"
    var rxAudioActivity = "INACTIVE"
    var activationRequestedAt: Date?
    var audioSessionActivatedAt: Date?
    var firstAudioAt: Date?
    var activationMilliseconds: Int?
    var remoteParticipantClearedAt: Date?
    var remoteClearRequestedAt: Date?
    var remoteClearReason: String?
    var remoteGeneration = 0
    var remoteLeasePrefix: String?
    var resolutionFailures = 0
    var ghostActivityIgnored = 0
    var remoteParticipantSetRequestedAt: Date?
    var remoteParticipantSetCompletedAt: Date?
    var remoteParticipantSetErrorCode: String?
    var remoteParticipantSetGeneration = 0
    var appleAudioActivationGeneration = 0
    var rxFirstPcmGeneration = 0
    var rxStaleMediaDropped = 0
    var rxLateCompletionIgnored = 0
}

enum CueResult: Equatable, Sendable {
    case notPlayed
    case success
    case skipped(String)
    case failure(String)

    var displayValue: String {
        switch self {
        case .notPlayed: "Not played"
        case .success: "PASS"
        case let .skipped(message): "SKIPPED: \(message)"
        case let .failure(message): "FAILED: \(message)"
        }
    }
}

struct PTTSnapshot: Sendable {
    var attemptGeneration: Int
    var state: PTTState
    var leaseId: String?
    var ownerName: String?
    var leaseExpiresAt: Date?
    var maxTxExpiresAt: Date?
    var pttDownAt: Date?
    var floorRequestAt: Date?
    var floorGrantedAt: Date?
    var readyBarrierStartedAt: Date?
    var readyBarrierCompletedAt: Date?
    var controlStartSentAt: Date?
    var cueStartAt: Date?
    var cueEndAt: Date?
    var trackEnabledAt: Date?
    var talkingAt: Date?
    var pttUpAt: Date?
    var microphoneMutedAt: Date?
    var controlEndPublishedAt: Date?
    var floorReleaseRequestedAt: Date?
    var floorReleaseCompletedAt: Date?
    var startCueResult: CueResult
    var endCueResult: CueResult
    var controlStartResult: String
    var controlEndResult: String
    var lastError: String?
    var rxReadyWaitStartedAt: Date?
    var rxReadyFirstAt: Date?
    var rxReadyAllAt: Date?
    var rxReadyWaitMilliseconds: Int?
    var rxReadyExpectedCount: Int
    var rxReadyReceivedCount: Int
    var rxReadyLateCount: Int
    var rxReadyTimedOut: Bool
    var coldWakeBarrierRequired: Bool
    var wakeRecipientCount: Int
    var readyBarrierResult: String
    var lastStopReason: String?
    var floorRenewAttemptCount: Int
    var floorRenewSuccessCount: Int
    var floorLastRenewStartedAt: Date?
    var floorLastRenewCompletedAt: Date?
    var floorLastRenewResult: String?
    var floorLastRenewError: String?
    var controlPublishFastStartedAt: Date?
    var controlPublishFastCompletedAt: Date?
    var controlPublishFastMilliseconds: Int?
    var controlPublishReliableStartedAt: Date?
    var controlPublishReliableCompletedAt: Date?
    var controlPublishReliableMilliseconds: Int?

    static func initial(role: KOEONRole) -> PTTSnapshot {
        PTTSnapshot(
            attemptGeneration: 0,
            state: role.canPublish ? .idle : .rxOnly,
            leaseId: nil,
            ownerName: nil,
            leaseExpiresAt: nil,
            maxTxExpiresAt: nil,
            pttDownAt: nil,
            floorRequestAt: nil,
            floorGrantedAt: nil,
            readyBarrierStartedAt: nil,
            readyBarrierCompletedAt: nil,
            controlStartSentAt: nil,
            cueStartAt: nil,
            cueEndAt: nil,
            trackEnabledAt: nil,
            talkingAt: nil,
            pttUpAt: nil,
            microphoneMutedAt: nil,
            controlEndPublishedAt: nil,
            floorReleaseRequestedAt: nil,
            floorReleaseCompletedAt: nil,
            startCueResult: .notPlayed,
            endCueResult: .notPlayed,
            controlStartResult: "Not published",
            controlEndResult: "Not published",
            lastError: nil,
            rxReadyWaitStartedAt: nil,
            rxReadyFirstAt: nil,
            rxReadyAllAt: nil,
            rxReadyWaitMilliseconds: nil,
            rxReadyExpectedCount: 0,
            rxReadyReceivedCount: 0,
            rxReadyLateCount: 0,
            rxReadyTimedOut: false,
            coldWakeBarrierRequired: false,
            wakeRecipientCount: 0,
            readyBarrierResult: "NOT_STARTED",
            lastStopReason: nil,
            floorRenewAttemptCount: 0,
            floorRenewSuccessCount: 0,
            floorLastRenewStartedAt: nil,
            floorLastRenewCompletedAt: nil,
            floorLastRenewResult: nil,
            floorLastRenewError: nil,
            controlPublishFastStartedAt: nil,
            controlPublishFastCompletedAt: nil,
            controlPublishFastMilliseconds: nil,
            controlPublishReliableStartedAt: nil,
            controlPublishReliableCompletedAt: nil,
            controlPublishReliableMilliseconds: nil
        )
    }

    var floorLatencyMilliseconds: Int? {
        guard let pttDownAt, let floorGrantedAt else { return nil }
        return max(0, Int(floorGrantedAt.timeIntervalSince(pttDownAt) * 1_000))
    }

    var localEnableLatencyMilliseconds: Int? {
        guard let pttDownAt, let trackEnabledAt else { return nil }
        return max(0, Int(trackEnabledAt.timeIntervalSince(pttDownAt) * 1_000))
    }
}
