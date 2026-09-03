import Foundation

let rxDrainMinimumMilliseconds = 120
let rxSilenceConfirmationMilliseconds = 60
let rxDrainHardCapMilliseconds = 350
let rxFirstAudioGraceAfterActivateMilliseconds = 500
let rxStartupAbsoluteMaxMilliseconds = 1_500
let rxDivergenceWatchdogMilliseconds = 250

enum RxFloorReconcileDecision: String, Sendable {
    case keepRemoteOwnerMatch = "KEEP_REMOTE_OWNER_MATCH"
    case keepAuthoritativeLease = "KEEP_AUTHORITATIVE_LEASE"
    case keepRedactedLease = "KEEP_REDACTED_LEASE"
    case endAvailable = "END_FLOOR_AVAILABLE"
    case endOwnerChanged = "END_FLOOR_OWNER_CHANGED"
    case endAuthoritativeLeaseChanged = "END_AUTHORITATIVE_LEASE_CHANGED"

    static func evaluate(
        rxSpeakerUserId: String?,
        rxLeaseId: String,
        floor: FloorResponse
    ) -> Self {
        if floor.outcome == .available { return .endAvailable }

        if floor.outcome == .busy {
            if floor.owner?.id == rxSpeakerUserId, rxSpeakerUserId != nil {
                // A receiver is not the Floor owner, so its status response
                // intentionally redacts leaseId. Matching the trusted remote
                // owner is sufficient to keep this RX generation alive.
                return .keepRemoteOwnerMatch
            }
            if floor.owner?.id != nil { return .endOwnerChanged }
        }

        if floor.isOwner, let visibleLeaseId = floor.leaseId {
            return visibleLeaseId == rxLeaseId
                ? .keepAuthoritativeLease
                : .endAuthoritativeLeaseChanged
        }

        // A missing lease for a non-owner is unknown/redacted, never proof of
        // a lease change. Explicit END remains the primary termination path.
        return .keepRedactedLease
    }
}

struct RxPlayoutDrainPolicy: Sendable {
    static func estimatedOutputPipelineMilliseconds(
        outputLatency: TimeInterval?,
        ioBufferDuration: TimeInterval?,
        route: String?
    ) -> Int? {
        guard outputLatency != nil || ioBufferDuration != nil else { return nil }
        let output = max(0, outputLatency ?? 0)
        let buffer = max(0, ioBufferDuration ?? 0)
        // Bluetooth communication routes commonly stage one additional I/O
        // buffer between decoded PCM and the headset. This is measured-session
        // accounting, not an application media buffer or a fixed playout delay.
        let bufferCount = route == AudioRouteKind.bluetooth.rawValue ? 2.0 : 1.0
        return min(rxDrainHardCapMilliseconds, max(0, Int((output + buffer * bufferCount) * 1_000)))
    }

    static func drainTargetMilliseconds(
        outputLatency: TimeInterval?,
        ioBufferDuration: TimeInterval?,
        route: String?
    ) -> Int {
        max(
            rxDrainMinimumMilliseconds,
            estimatedOutputPipelineMilliseconds(
                outputLatency: outputLatency,
                ioBufferDuration: ioBufferDuration,
                route: route
            ) ?? 0
        )
    }
}

struct RxDivergenceSignal: Equatable, Sendable {
    let event: String
    let elapsedMilliseconds: Int
    let snapshot: RxConsistencySnapshot
}

struct RxDivergenceEvaluation: Equatable, Sendable {
    var signals: [RxDivergenceSignal] = []
    var verifiedInactiveMediaSessionId: String?
    var recoverySessionId: String?
    var recoveryGeneration = 0
    var recoveryLevel = 0
}

enum RxRemotePcmObservation: Equatable, Sendable {
    case rejected
    case observed
    case recovered
}

/// Keeps LiveKit media hints, validated RX authorization, and observed PCM as
/// separate dimensions. Speaking activity is only a conservative PTT busy
/// signal; it can never create or authorize a receive generation.
struct RxConsistencyGuard: Sendable {
    private(set) var snapshot = RxConsistencySnapshot()
    private var mediaEvidenceAt: Date?
    private var validatedRxStartedAt: Date?
    private var pcmTimeoutEmitted = false
    private var mediaDivergenceEmitted = false
    // Absolute episode deadlines; never restart the ladder on a reconcile callback.
    private let recoveryDeadlines = [250, 750, 1_500, 2_500, 4_000]

    mutating func handleMediaActivity(sessionId: String?, active: Bool, at: Date) {
        guard active, let sessionId else {
            if sessionId == nil || snapshot.remoteMediaSpeakerSessionId == sessionId {
                snapshot.remoteMediaSpeakerActive = false
                snapshot.remoteMediaSpeakerSessionId = nil
                mediaEvidenceAt = nil
            }
            return
        }
        beginEpisodeIfNeeded()
        if snapshot.remoteMediaSpeakerSessionId != sessionId {
            snapshot.remoteMediaSpeakerSessionId = sessionId
            if snapshot.validatedRxSessionId != sessionId {
                snapshot.remotePcmObserved = false
            }
        }
        snapshot.remoteMediaSpeakerActive = true
        mediaEvidenceAt = at
    }

    mutating func updateValidatedRx(
        active: Bool,
        sessionId: String?,
        generation: Int,
        participantResolved: Bool,
        trackSubscribed: Bool,
        batv1TimelineActive: Bool = false,
        at: Date
    ) {
        guard active, let sessionId, generation > 0 else {
            snapshot.validatedRemoteRxActive = false
            snapshot.validatedRxSessionId = nil
            snapshot.validatedRxGeneration = 0
            snapshot.remotePcmObserved = false
            snapshot.participantResolved = false
            snapshot.trackSubscribed = false
            snapshot.batv1TimelineActive = false
            snapshot.rxPathReconciliationActive = false
            validatedRxStartedAt = nil
            pcmTimeoutEmitted = false
            snapshot.pathState = "IDLE"
            snapshot.recoveryLevel = 0
            return
        }
        beginEpisodeIfNeeded()
        if snapshot.validatedRxGeneration != generation || snapshot.validatedRxSessionId != sessionId {
            snapshot.remotePcmObserved = false
            validatedRxStartedAt = at
            pcmTimeoutEmitted = false
            snapshot.recoveryLevel = 0
            snapshot.recoveryAttempts = 0
        }
        let pathViable = batv1TimelineActive || (participantResolved && trackSubscribed)
        snapshot.validatedRemoteRxActive = pathViable
        snapshot.rxPathReconciliationActive = !pathViable
        snapshot.validatedRxSessionId = sessionId
        snapshot.validatedRxGeneration = generation
        snapshot.participantResolved = participantResolved
        snapshot.trackSubscribed = trackSubscribed
        snapshot.batv1TimelineActive = batv1TimelineActive
        if snapshot.recoveryLevel == 0 {
            snapshot.pathState = pathViable ? "PATH_VIABLE" : "PATH_BINDING"
        }
    }

    @discardableResult
    mutating func handleRemotePcm(sessionId: String?, generation: Int, at: Date) -> RxRemotePcmObservation {
        guard snapshot.validatedRemoteRxActive,
              generation == snapshot.validatedRxGeneration,
              sessionId == snapshot.validatedRxSessionId else { return .rejected }
        let recovered = pcmTimeoutEmitted && snapshot.recoveryAttempts > 0
        snapshot.remotePcmObserved = true
        snapshot.pathState = "PCM_FLOWING"
        if snapshot.remoteMediaSpeakerSessionId == sessionId {
            mediaEvidenceAt = at
        }
        return recovered ? .recovered : .observed
    }

    mutating func evaluate(
        at: Date,
        thresholdMilliseconds: Int = rxDivergenceWatchdogMilliseconds,
        remoteParticipantIsSpeaking: Bool? = nil
    ) -> RxDivergenceEvaluation {
        var evaluation = RxDivergenceEvaluation()

        if (snapshot.validatedRemoteRxActive || snapshot.rxPathReconciliationActive),
           !snapshot.remotePcmObserved,
           let startedAt = validatedRxStartedAt {
            let elapsed = milliseconds(from: startedAt, to: at)
            let level = snapshot.recoveryLevel
            if level < recoveryDeadlines.count, elapsed >= recoveryDeadlines[level] {
                pcmTimeoutEmitted = true
                snapshot.recoveryAttempts += 1
                snapshot.recoveryLevel += 1
                snapshot.pathState = ["RECOVERING_SOFT", "PATH_BINDING", "RECOVERING_RUNTIME",
                                      "RECOVERING_FRESH_JOIN", "TERMINAL"][level]
                evaluation.recoverySessionId = snapshot.validatedRxSessionId
                evaluation.recoveryGeneration = snapshot.validatedRxGeneration
                evaluation.recoveryLevel = snapshot.recoveryLevel
                evaluation.signals.append(RxDivergenceSignal(
                    event: "rx_pcm_timeout",
                    elapsedMilliseconds: elapsed,
                    snapshot: snapshot
                ))
            }
        }

        if snapshot.remoteMediaSpeakerActive, let evidenceAt = mediaEvidenceAt {
            let elapsed = milliseconds(from: evidenceAt, to: at)
            if elapsed >= thresholdMilliseconds {
                if !snapshot.validatedRemoteRxActive, !mediaDivergenceEmitted {
                    mediaDivergenceEmitted = true
                    evaluation.signals.append(RxDivergenceSignal(
                        event: "rx_divergence_detected",
                        elapsedMilliseconds: elapsed,
                        snapshot: snapshot
                    ))
                }
                if remoteParticipantIsSpeaking == false {
                    evaluation.verifiedInactiveMediaSessionId = snapshot.remoteMediaSpeakerSessionId
                    snapshot.remoteMediaSpeakerActive = false
                    snapshot.remoteMediaSpeakerSessionId = nil
                    mediaEvidenceAt = nil
                    evaluation.signals.append(RxDivergenceSignal(
                        event: "rx_divergence_cleared",
                        elapsedMilliseconds: elapsed,
                        snapshot: snapshot
                    ))
                } else {
                    // The 250 ms threshold detects divergence; it is not a
                    // speaker TTL. Re-check SDK state later while keeping PTT
                    // blocked whenever LiveKit still reports speaking (or the
                    // participant state is temporarily unavailable).
                    mediaEvidenceAt = at
                }
            }
        }
        return evaluation
    }

    func nextDeadline(thresholdMilliseconds: Int = rxDivergenceWatchdogMilliseconds) -> Date? {
        var deadlines: [Date] = []
        if snapshot.remoteMediaSpeakerActive, let mediaEvidenceAt {
            deadlines.append(mediaEvidenceAt.addingTimeInterval(Double(thresholdMilliseconds) / 1_000))
        }
        if (snapshot.validatedRemoteRxActive || snapshot.rxPathReconciliationActive),
           !snapshot.remotePcmObserved,
           snapshot.recoveryLevel < recoveryDeadlines.count,
           let validatedRxStartedAt {
            deadlines.append(validatedRxStartedAt.addingTimeInterval(Double(recoveryDeadlines[snapshot.recoveryLevel]) / 1_000))
        }
        return deadlines.min()
    }

    mutating func reset() {
        snapshot = RxConsistencySnapshot()
        mediaEvidenceAt = nil
        validatedRxStartedAt = nil
        pcmTimeoutEmitted = false
        mediaDivergenceEmitted = false
    }

    private mutating func beginEpisodeIfNeeded() {
        guard !snapshot.remoteMediaSpeakerActive,
              !snapshot.validatedRemoteRxActive,
              !snapshot.rxPathReconciliationActive else { return }
        snapshot.episode += 1
        snapshot.recoveryAttempts = 0
        pcmTimeoutEmitted = false
        mediaDivergenceEmitted = false
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }
}

@MainActor
final class RemoteReceiveActivationCoordinator {
    typealias SpeakerResolver = @MainActor (String) -> TrustedRemoteSpeaker?
    typealias ParticipantSetter = @MainActor (TrustedRemoteSpeaker?) -> Void
    typealias ParticipantRequestSetter = @MainActor (TrustedRemoteSpeaker?, RemoteParticipantRequestContext) -> Int?
    typealias ClearCompleted = @MainActor (RemoteParticipantRequestContext) -> Void

    private let resolveSpeaker: SpeakerResolver
    private let setRemoteParticipant: ParticipantSetter
    private let setRemoteParticipantRequest: ParticipantRequestSetter?
    private let clock: any PTTClock
    private let onClearCompleted: ClearCompleted
    private let onUpdate: @Sendable (RemoteReceiveActivationSnapshot) -> Void
    private var snapshot = RemoteReceiveActivationSnapshot()
    private var activeLeaseId: String?
    private var activeGeneration = 0
    private var pendingSessionId: String?
    private var pendingLeaseId: String?
    private var pendingGeneration = 0
    private var activeSetRequestId: Int?
    private var clearRequestId: Int?
    private var appleActivationPending = false

    init(
        resolveSpeaker: @escaping SpeakerResolver,
        setRemoteParticipant: @escaping ParticipantSetter,
        setRemoteParticipantRequest: ParticipantRequestSetter? = nil,
        clock: any PTTClock = SystemPTTClock(),
        onClearCompleted: @escaping ClearCompleted = { _ in },
        onUpdate: @escaping @Sendable (RemoteReceiveActivationSnapshot) -> Void
    ) {
        self.resolveSpeaker = resolveSpeaker
        self.setRemoteParticipant = setRemoteParticipant
        self.setRemoteParticipantRequest = setRemoteParticipantRequest
        self.clock = clock
        self.onClearCompleted = onClearCompleted
        self.onUpdate = onUpdate
    }

    func currentSnapshot() -> RemoteReceiveActivationSnapshot { snapshot }

    @discardableResult
    func handleValidatedStart(_ event: PttControlEvent, generation: Int = 0) -> Bool {
        snapshot.wakeId = "rx-\(generation)-\(String(event.leaseId.prefix(8)))"
        guard let speaker = resolveSpeaker(event.sessionId), speaker.sessionId == event.sessionId else {
            pendingSessionId = event.sessionId
            pendingLeaseId = event.leaseId
            pendingGeneration = generation
            snapshot.remoteParticipantState = "RESOLUTION_FAILED"
            snapshot.resolutionFailures += 1
            snapshot.participantPresentBeforeWake = false
            snapshot.participantRebindStartedAt = snapshot.participantRebindStartedAt ?? clock.now
            snapshot.participantRebindAttemptCount += 1
            snapshot.participantRebindResult = "RECONCILING"
            publish()
            return false
        }

        let isSameParticipant = snapshot.remoteSpeakerSessionId == speaker.sessionId &&
            snapshot.remoteSpeakerName == speaker.displayName &&
            snapshot.remoteParticipantState != "INACTIVE"
        activeLeaseId = event.leaseId
        activeGeneration = generation
        pendingSessionId = nil
        pendingLeaseId = nil
        snapshot.remoteSpeakerSessionId = speaker.sessionId
        snapshot.remoteSpeakerName = speaker.displayName
        snapshot.remoteGeneration = generation
        snapshot.remoteLeasePrefix = String(event.leaseId.prefix(8))
        snapshot.participantPresentBeforeWake = true
        snapshot.participantRebindResolvedAt = clock.now
        snapshot.participantRebindResult = "RESOLVED"
        if !isSameParticipant {
            snapshot.remoteParticipantState = "ACTIVATION_REQUESTED"
            snapshot.activationRequestedAt = clock.now
            snapshot.audioSessionActivatedAt = nil
            snapshot.firstAudioAt = nil
            snapshot.activationMilliseconds = nil
            snapshot.remoteParticipantClearedAt = nil
            // Replacing A with B is one non-nil operation. Never clear A first.
            requestRemoteParticipant(
                speaker, generation: generation, sessionId: event.sessionId, leaseId: event.leaseId
            )
        }
        publish()
        return true
    }

    func handleRemoteAudioActivity(sessionId: String?, active: Bool) {
        guard let sessionId else {
            if !active {
                snapshot.rxAudioActivity = "SILENT"
                publish()
            }
            return
        }

        if active, snapshot.remoteSpeakerSessionId != sessionId {
            // ActiveSpeakers callbacks can arrive after a completed drain. They are
            // media hints, not authorization to recreate an RX generation. Only a
            // previously validated START that is waiting for participant resolution
            // may use this fallback path.
            guard pendingSessionId == sessionId,
                  let validatedPendingLeaseId = pendingLeaseId,
                  pendingGeneration > 0 else {
                snapshot.ghostActivityIgnored += 1
                publish()
                return
            }
            guard let speaker = resolveSpeaker(sessionId), speaker.sessionId == sessionId else {
                snapshot.remoteParticipantState = "FALLBACK_RESOLUTION_FAILED"
                snapshot.resolutionFailures += 1
                publish()
                return
            }
            activeLeaseId = validatedPendingLeaseId
            activeGeneration = pendingGeneration
            snapshot.remoteGeneration = activeGeneration
            snapshot.remoteLeasePrefix = activeLeaseId.map { String($0.prefix(8)) }
            pendingSessionId = nil
            pendingLeaseId = nil
            pendingGeneration = 0
            snapshot.remoteSpeakerSessionId = speaker.sessionId
            snapshot.remoteSpeakerName = speaker.displayName
            snapshot.remoteParticipantState = "FALLBACK_ACTIVATION_REQUESTED"
            snapshot.activationRequestedAt = clock.now
            snapshot.audioSessionActivatedAt = nil
            snapshot.activationMilliseconds = nil
            snapshot.remoteParticipantClearedAt = nil
            requestRemoteParticipant(
                speaker, generation: activeGeneration, sessionId: sessionId, leaseId: validatedPendingLeaseId
            )
        }

        guard snapshot.remoteSpeakerSessionId == sessionId else { return }
        snapshot.rxAudioActivity = active ? "ACTIVE" : "SILENT"
        if active, snapshot.firstAudioAt == nil {
            snapshot.firstAudioAt = clock.now
        }
        publish()
    }

    /// A validated START may arrive before LiveKit exposes the remote participant
    /// on a freshly-created Room. Retry immediately when participantDidConnect
    /// arrives instead of waiting for an audio-activity callback that a short TX
    /// might never produce.
    @discardableResult
    func handleParticipantAvailable(sessionId: String) -> Bool {
        if pendingSessionId == sessionId { snapshot.participantRebindAttemptCount += 1 }
        guard pendingSessionId == sessionId,
              let leaseId = pendingLeaseId,
              pendingGeneration > 0,
              let speaker = resolveSpeaker(sessionId),
              speaker.sessionId == sessionId else { return false }
        activeLeaseId = leaseId
        activeGeneration = pendingGeneration
        pendingSessionId = nil
        pendingLeaseId = nil
        pendingGeneration = 0
        snapshot.remoteSpeakerSessionId = speaker.sessionId
        snapshot.remoteSpeakerName = speaker.displayName
        snapshot.remoteGeneration = activeGeneration
        snapshot.remoteLeasePrefix = String(leaseId.prefix(8))
        snapshot.remoteParticipantState = "PARTICIPANT_APPEARED_ACTIVATION_REQUESTED"
        snapshot.activationRequestedAt = clock.now
        snapshot.audioSessionActivatedAt = nil
        snapshot.firstAudioAt = nil
        snapshot.activationMilliseconds = nil
        snapshot.remoteParticipantClearedAt = nil
        snapshot.participantRebindResolvedAt = clock.now
        snapshot.participantRebindResult = "RESOLVED"
        requestRemoteParticipant(
            speaker, generation: activeGeneration, sessionId: sessionId, leaseId: leaseId
        )
        publish()
        return true
    }

    func markNoPcmRecoveryAttempt() {
        snapshot.noPcmRecoveryStartedAt = snapshot.noPcmRecoveryStartedAt ?? clock.now
        snapshot.noPcmRecoveryResult = "RECONCILING"
        publish()
    }

    func handleRemotePcm() {
        guard activeGeneration > 0,
              snapshot.remoteSpeakerSessionId != nil,
              snapshot.remoteParticipantState == "ACTIVE" || snapshot.remoteParticipantState == "PLAYING" else {
            return
        }
        snapshot.rxFirstPcmGeneration = activeGeneration
        snapshot.remoteParticipantState = "PLAYING"
        snapshot.rxPathViableAt = snapshot.rxPathViableAt ?? clock.now
        snapshot.noPcmRecoveryResult = snapshot.noPcmRecoveryStartedAt == nil ? "NOT_REQUIRED" : "RECOVERED"
        publish()
    }

    @discardableResult
    func audioSessionDidActivate() -> Bool {
        guard snapshot.remoteSpeakerSessionId != nil else { return false }
        appleActivationPending = true
        let legacyRequestAccepted = setRemoteParticipantRequest == nil
            && snapshot.remoteParticipantState == "ACTIVATION_REQUESTED"
        guard snapshot.remoteParticipantState == "ACCEPTED"
                || snapshot.remoteParticipantState == "PLAYING"
                || legacyRequestAccepted else {
            publish()
            return false
        }
        let now = clock.now
        snapshot.audioSessionActivatedAt = now
        snapshot.activationMilliseconds = snapshot.activationRequestedAt.map {
            max(0, Int(now.timeIntervalSince($0) * 1_000))
        }
        snapshot.appleAudioActivationGeneration = activeGeneration
        snapshot.remoteParticipantState = "ACTIVE"
        publish()
        return true
    }

    func reapplyAfterChannelJoin() {
        guard let sessionId = snapshot.remoteSpeakerSessionId,
              let speaker = resolveSpeaker(sessionId),
              speaker.sessionId == sessionId else {
            return
        }
        snapshot.activationRequestedAt = clock.now
        snapshot.remoteParticipantState = "ACTIVATION_REQUESTED"
        requestRemoteParticipant(
            speaker, generation: activeGeneration, sessionId: sessionId, leaseId: activeLeaseId ?? ""
        )
        publish()
    }

    @discardableResult
    func completeDrain(generation: Int, sessionId: String, leaseId: String, reason: String) -> Bool {
        guard snapshot.remoteSpeakerSessionId == sessionId,
              activeLeaseId == leaseId,
              activeGeneration == generation else {
            return false
        }
        snapshot.remoteClearRequestedAt = clock.now
        snapshot.remoteClearReason = reason
        if let setRemoteParticipantRequest {
            snapshot.remoteParticipantState = "CLEAR_REQUESTED"
            snapshot.remoteParticipantSetRequestedAt = clock.now
            clearRequestId = setRemoteParticipantRequest(nil, RemoteParticipantRequestContext(
                generation: generation, sessionId: sessionId, leaseId: leaseId, clearing: true
            ))
            publish()
            return true
        }
        let context = RemoteParticipantRequestContext(
            generation: generation, sessionId: sessionId, leaseId: leaseId, clearing: true
        )
        setRemoteParticipant(nil)
        finalizeClear()
        onClearCompleted(context)
        return true
    }

    @discardableResult
    func handleParticipantSetResult(_ result: RemoteParticipantSetResult) -> Bool {
        if result.context.clearing {
            guard result.requestId == clearRequestId,
                  result.context.generation == activeGeneration,
                  result.context.sessionId == snapshot.remoteSpeakerSessionId,
                  result.context.leaseId == activeLeaseId else {
                snapshot.rxLateCompletionIgnored += 1
                publish()
                return false
            }
            snapshot.remoteParticipantSetCompletedAt = clock.now
            if let errorCode = result.errorCode {
                snapshot.remoteParticipantState = "FAILED"
                snapshot.remoteParticipantSetErrorCode = errorCode
                publish()
                return false
            }
            let context = result.context
            finalizeClear()
            onClearCompleted(context)
            return false
        }
        guard result.requestId == activeSetRequestId,
              result.context.generation == activeGeneration,
              result.context.sessionId == snapshot.remoteSpeakerSessionId,
              result.context.leaseId == activeLeaseId else {
            snapshot.rxLateCompletionIgnored += 1
            publish()
            return false
        }
        snapshot.remoteParticipantSetCompletedAt = clock.now
        if let errorCode = result.errorCode {
            snapshot.remoteParticipantSetErrorCode = errorCode
            snapshot.rxStaleMediaDropped += 1
            finalizeClear()
            snapshot.remoteParticipantState = "FAILED"
            snapshot.remoteParticipantSetErrorCode = errorCode
            publish()
            return false
        }
        snapshot.remoteParticipantState = "ACCEPTED"
        snapshot.remoteParticipantSetErrorCode = nil
        if appleActivationPending { return audioSessionDidActivate() }
        publish()
        return false
    }

    func markMediaDiscardFailure(
        generation: Int,
        sessionId: String,
        leaseId: String,
        errorCode: String
    ) {
        guard generation == activeGeneration,
              sessionId == snapshot.remoteSpeakerSessionId,
              leaseId == activeLeaseId else {
            snapshot.rxLateCompletionIgnored += 1
            publish()
            return
        }
        snapshot.remoteParticipantState = "FAILED"
        snapshot.remoteParticipantSetErrorCode = errorCode
        publish()
    }

    private func requestRemoteParticipant(
        _ speaker: TrustedRemoteSpeaker,
        generation: Int,
        sessionId: String,
        leaseId: String
    ) {
        snapshot.remoteParticipantSetRequestedAt = clock.now
        snapshot.remoteParticipantSetCompletedAt = nil
        snapshot.remoteParticipantSetErrorCode = nil
        snapshot.remoteParticipantSetGeneration = generation
        if let setRemoteParticipantRequest {
            activeSetRequestId = setRemoteParticipantRequest(speaker, RemoteParticipantRequestContext(
                generation: generation, sessionId: sessionId, leaseId: leaseId, clearing: false
            ))
        } else {
            setRemoteParticipant(speaker)
            snapshot.remoteParticipantSetCompletedAt = clock.now
        }
    }

    private func finalizeClear() {
        activeLeaseId = nil
        activeGeneration = 0
        pendingSessionId = nil
        pendingLeaseId = nil
        pendingGeneration = 0
        snapshot.remoteSpeakerSessionId = nil
        snapshot.remoteSpeakerName = nil
        snapshot.remoteParticipantState = "INACTIVE"
        snapshot.rxAudioActivity = "INACTIVE"
        snapshot.remoteParticipantClearedAt = clock.now
        activeSetRequestId = nil
        clearRequestId = nil
        appleActivationPending = false
        publish()
    }

    @discardableResult
    func completeDrain(sessionId: String, leaseId: String) -> Bool {
        completeDrain(
            generation: activeGeneration,
            sessionId: sessionId,
            leaseId: leaseId,
            reason: "drain_complete"
        )
    }

    func reset() {
        if let sessionId = snapshot.remoteSpeakerSessionId {
            if let setRemoteParticipantRequest {
                _ = setRemoteParticipantRequest(nil, RemoteParticipantRequestContext(
                    generation: activeGeneration, sessionId: sessionId, leaseId: activeLeaseId ?? "", clearing: true))
            } else { setRemoteParticipant(nil) }
        }
        resetLocalState()
    }

    /// A PushToTalk wake may replace only the stale LiveKit runtime while Apple
    /// already owns the active remote participant. Do not create a nil gap.
    func resetPreservingSystemRemoteParticipant() {
        resetLocalState()
    }

    private func resetLocalState() {
        activeLeaseId = nil
        activeGeneration = 0
        pendingSessionId = nil
        pendingLeaseId = nil
        pendingGeneration = 0
        snapshot = RemoteReceiveActivationSnapshot()
        activeSetRequestId = nil
        clearRequestId = nil
        appleActivationPending = false
        publish()
    }

    private func publish() { onUpdate(snapshot) }
}

@MainActor
final class RxAudioController {
    private let channelId: String
    private let cuePlayer: any PttCuePlaying
    private let clock: any PTTClock
    private let onUpdate: @Sendable (RxSnapshot) -> Void
    private let onValidatedStart: @MainActor (PttControlEvent, Int) -> Void
    private let onAudioActivity: @MainActor (String?, Bool) -> Void
    private let onDrainCompleted: @MainActor (Int, String, String, String) -> Bool
    private let onReceiverReady: @MainActor (String, String) async -> Void
    private var startCueEnabled: Bool

    private var snapshot = RxSnapshot()
    private var lastSequenceBySession: [String: Int64] = [:]
    private var generation = 0
    private var audioActive = false
    private var appleAudioActive = false
    private var firstPcmObserved = false
    private var pendingEndReason: String?
    private var pendingActiveSessionId: String?
    private var silenceStartedAt: Date?
    private var playoutDrainTargetMilliseconds = rxDrainMinimumMilliseconds
    private var drainTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var readySentLeaseId: String?
    private var pendingPushTiming: (incoming: Date, acquired: Date)?

    init(
        channelId: String,
        cuePlayer: any PttCuePlaying,
        clock: any PTTClock = SystemPTTClock(),
        onValidatedStart: @escaping @MainActor (PttControlEvent, Int) -> Void = { _, _ in },
        onAudioActivity: @escaping @MainActor (String?, Bool) -> Void = { _, _ in },
        onDrainCompleted: @escaping @MainActor (Int, String, String, String) -> Bool = { _, _, _, _ in true },
        onReceiverReady: @escaping @MainActor (String, String) async -> Void = { _, _ in },
        startCueEnabled: Bool = true,
        onUpdate: @escaping @Sendable (RxSnapshot) -> Void
    ) {
        self.channelId = channelId
        self.cuePlayer = cuePlayer
        self.clock = clock
        self.onValidatedStart = onValidatedStart
        self.onAudioActivity = onAudioActivity
        self.onDrainCompleted = onDrainCompleted
        self.onReceiverReady = onReceiverReady
        self.startCueEnabled = startCueEnabled
        self.onUpdate = onUpdate
    }

    func setStartCueEnabled(_ enabled: Bool) { startCueEnabled = enabled }

    func currentSnapshot() -> RxSnapshot { snapshot }

    func handleControl(_ event: PttControlEvent, senderSessionId: String?) {
        guard event.channelId == channelId,
              senderSessionId == nil || senderSessionId == event.sessionId else {
            snapshot.staleIgnored += 1
            publish()
            return
        }
        if let last = lastSequenceBySession[event.sessionId], event.sequence <= last {
            if event.sequence == last { snapshot.duplicateIgnored += 1 }
            else { snapshot.staleIgnored += 1 }
            publish()
            return
        }
        lastSequenceBySession[event.sessionId] = event.sequence
        if event.type == "start" { start(event) }
        else { markEnded(event: event, source: "control_end") }
    }

    func handleTrustedIncomingStart(_ incoming: PttIncomingEvent) {
        pendingPushTiming = (clock.now, incoming.acquiredAt)
        start(PttControlEvent(
            version: pttControlVersion,
            type: "start",
            channelId: incoming.channelId,
            speakerUserId: incoming.speakerUserId,
            sessionId: incoming.speakerSessionId,
            leaseId: incoming.leaseId,
            sequence: 0,
            sentAt: Int64(incoming.acquiredAt.timeIntervalSince1970 * 1_000)
        ))
    }

    func handleRemoteAudioActivity(senderSessionId: String?, active: Bool) {
        onAudioActivity(senderSessionId, active)
        guard let current = snapshot.sessionId else {
            audioActive = active
            pendingActiveSessionId = active ? senderSessionId : nil
            if active {
                snapshot.controlEventFallback = true
                publish()
            }
            return
        }
        guard senderSessionId == nil || senderSessionId == current else {
            if active { pendingActiveSessionId = senderSessionId }
            return
        }
        audioActive = active
        if active {
            silenceStartedAt = nil
            snapshot.rxLastAudioAt = clock.now
            publish()
        } else {
            silenceStartedAt = clock.now
            if snapshot.state == .draining { scheduleDrainCheck() }
        }
    }

    /// BATv1 finalSequence is media truth; PCM playout has already drained.
    func completeBufferedTimelineDrain() async {
        guard snapshot.state != .idle,
              snapshot.sessionId != nil,
              snapshot.leaseId != nil else { return }
        if snapshot.state != .draining { beginDrain(reason: "batv1_final_sequence") }
        await completeDrain(reason: "batv1_final_sequence")
    }

    func handleRemotePcm(at timestamp: Date) {
        guard snapshot.state != .idle, snapshot.sessionId != nil else { return }
        snapshot.rxLastAudioAt = timestamp
        if !firstPcmObserved {
            firstPcmObserved = true
            snapshot.rxFirstPcmAt = timestamp
            if snapshot.state == .endPending {
                beginDrain(reason: pendingEndReason ?? "end_after_first_pcm")
                return
            }
            snapshot.state = .active
        }
        publish()
    }

    func audioSessionDidActivate(
        engineEnabledAt: Date? = nil,
        outputLatency: TimeInterval? = nil,
        ioBufferDuration: TimeInterval? = nil,
        route: String? = nil
    ) {
        appleAudioActive = true
        let now = clock.now
        snapshot.rxAppleAudioActivatedAt = snapshot.rxAppleAudioActivatedAt ?? now
        snapshot.rxLiveKitEngineEnabledAt = engineEnabledAt ?? now
        snapshot.rxAppleOutputLatencyMilliseconds = outputLatency.map { max(0, Int($0 * 1_000)) }
        snapshot.rxAppleIoBufferDurationMilliseconds = ioBufferDuration.map { max(0, Int($0 * 1_000)) }
        snapshot.rxAudioRoute = route
        snapshot.estimatedOutputPipelineMilliseconds = RxPlayoutDrainPolicy.estimatedOutputPipelineMilliseconds(
            outputLatency: outputLatency,
            ioBufferDuration: ioBufferDuration,
            route: route
        )
        playoutDrainTargetMilliseconds = RxPlayoutDrainPolicy.drainTargetMilliseconds(
            outputLatency: outputLatency,
            ioBufferDuration: ioBufferDuration,
            route: route
        )
        snapshot.rxPlayoutDrainTargetMilliseconds = playoutDrainTargetMilliseconds
        if snapshot.state == .arming { snapshot.state = .waitingFirstAudio }
        publish()
        // Readiness means Apple activated and LiveKit playback is enabled. The
        // best-effort cue runs concurrently and must never gate the sender.
        let operation = generation
        Task { [weak self] in
            guard let self else { return }
            await self.publishReadyIfNeeded(operation: operation)
            self.playStartCueIfSafe()
        }
        if snapshot.state == .endPending { scheduleStartupTimeout() }
    }

    func audioSessionDidDeactivate() { appleAudioActive = false }

    func reconcileFloor(_ floor: FloorResponse) {
        guard let sessionId = snapshot.sessionId,
              let leaseId = snapshot.leaseId,
              snapshot.state != .idle else { return }
        let decision = RxFloorReconcileDecision.evaluate(
            rxSpeakerUserId: snapshot.speakerUserId,
            rxLeaseId: leaseId,
            floor: floor
        )
        snapshot.lastFloorStatusOutcome = floor.outcome.rawValue
        snapshot.lastFloorStatusOwnerUserId = floor.owner?.id
        snapshot.lastFloorStatusIsOwner = floor.isOwner
        snapshot.lastFloorStatusLeaseVisible = floor.leaseId != nil
        snapshot.lastFloorReconcileDecision = decision.rawValue
        snapshot.lastFloorReconcileAt = clock.now
        publish()

        switch decision {
        case .endAvailable:
            markEnded(sessionId: sessionId, leaseId: leaseId, source: "floor_available")
        case .endOwnerChanged:
            markEnded(sessionId: sessionId, leaseId: leaseId, source: "floor_owner_changed")
        case .endAuthoritativeLeaseChanged:
            markEnded(sessionId: sessionId, leaseId: leaseId, source: "floor_lease_changed")
        case .keepRemoteOwnerMatch, .keepAuthoritativeLease, .keepRedactedLease:
            break
        }
    }

    func reset() {
        generation += 1
        cancelTimers()
        audioActive = false
        appleAudioActive = false
        firstPcmObserved = false
        pendingEndReason = nil
        pendingActiveSessionId = nil
        readySentLeaseId = nil
        pendingPushTiming = nil
        silenceStartedAt = nil
        lastSequenceBySession.removeAll()
        snapshot = RxSnapshot()
        publish()
    }

    func resetAndAwait() async {
        let pending = [drainTask, capTask, startupTimeoutTask]
        reset()
        for task in pending { await task?.value }
    }

    private func start(_ event: PttControlEvent) {
        if snapshot.sessionId == event.sessionId,
           snapshot.leaseId == event.leaseId,
           snapshot.state != .idle {
            onValidatedStart(event, snapshot.generation)
            snapshot.duplicateIgnored += 1
            publish()
            return
        }
        let old = snapshot
        let preempted = old.state != .idle
        let voiceAlreadyActive = pendingActiveSessionId == event.sessionId ||
            (audioActive && pendingActiveSessionId == nil)
        generation += 1
        let rxGeneration = generation
        onValidatedStart(event, rxGeneration)
        cancelTimers()
        audioActive = voiceAlreadyActive
        // LiveKit speaking is a media hint, not proof that decoded PCM reached
        // this generation. Only handleRemotePcm may cross the first-PCM fence.
        firstPcmObserved = false
        pendingEndReason = nil
        pendingActiveSessionId = nil
        silenceStartedAt = nil
        snapshot = RxSnapshot()
        snapshot.generation = rxGeneration
        snapshot.state = appleAudioActive ? .waitingFirstAudio : .arming
        snapshot.speakerUserId = event.speakerUserId
        snapshot.sessionId = event.sessionId
        snapshot.leaseId = event.leaseId
        snapshot.rxStartedAt = clock.now
        snapshot.rxControlStartReceivedAt = clock.now
        snapshot.rxControlEventSentAt = Date(timeIntervalSince1970: Double(event.sentAt) / 1_000)
        snapshot.rxControlNetworkMilliseconds = max(
            0,
            Int(Int64(clock.now.timeIntervalSince1970 * 1_000) - event.sentAt)
        )
        if let pendingPushTiming {
            snapshot.rxIncomingPushAt = pendingPushTiming.incoming
            snapshot.rxFloorAcquiredAtFromPush = pendingPushTiming.acquired
            snapshot.rxFloorToPushMilliseconds = max(
                0,
                Int(pendingPushTiming.incoming.timeIntervalSince(pendingPushTiming.acquired) * 1_000)
            )
            self.pendingPushTiming = nil
        }
        snapshot.rxRemoteParticipantRequestedAt = clock.now
        snapshot.rxAppleAudioActivatedAt = appleAudioActive ? clock.now : nil
        snapshot.rxLiveKitEngineEnabledAt = appleAudioActive ? clock.now : nil
        snapshot.rxFirstPcmAt = nil
        snapshot.rxControlEndReceivedAt = nil
        snapshot.rxFloorEndObservedAt = nil
        snapshot.rxLastAudioAt = nil
        snapshot.rxPlayoutDrainTargetMilliseconds = playoutDrainTargetMilliseconds
        snapshot.rxPlaybackCompletedAt = nil
        snapshot.rxRemoteParticipantClearedAt = nil
        snapshot.endBeforeAppleActivate = false
        snapshot.endBeforeFirstPcm = false
        snapshot.shortBurstProtectionUsed = false
        snapshot.shortBurstProtectionMilliseconds = nil
        snapshot.rxEndSignalAt = nil
        snapshot.rxDrainStartedAt = nil
        snapshot.rxDrainCompletedAt = preempted ? clock.now : nil
        snapshot.rxDrainDurationMilliseconds = preempted ? max(0, Int(clock.now.timeIntervalSince(old.rxDrainStartedAt ?? clock.now) * 1_000)) : nil
        snapshot.rxEndReason = preempted ? "preempted" : nil
        snapshot.controlEventType = "start"
        snapshot.controlSequence = event.sequence
        snapshot.controlEventLate = Int64(clock.now.timeIntervalSince1970 * 1_000) - event.sentAt > Int64(rxDrainHardCapMilliseconds)
        snapshot.controlEventFallback = snapshot.controlEventFallback || voiceAlreadyActive
        snapshot.preempted += preempted ? 1 : 0
        snapshot.startCueResult = voiceAlreadyActive ? .skipped("voice already active") : .notPlayed
        snapshot.endCueResult = .notPlayed
        publish()
        readySentLeaseId = nil
        if appleAudioActive {
            if voiceAlreadyActive {
                snapshot.startCueResult = .notPlayed
            }
            let operation = generation
            Task { [weak self] in
                guard let self else { return }
                await self.publishReadyIfNeeded(operation: operation)
                self.playStartCueIfSafe()
            }
        }
    }

    private func markEnded(event: PttControlEvent, source: String) {
        guard snapshot.sessionId == event.sessionId,
              snapshot.leaseId == event.leaseId,
              snapshot.speakerUserId == event.speakerUserId,
              snapshot.state != .idle else {
            snapshot.staleIgnored += 1
            publish()
            return
        }
        guard snapshot.state != .draining, snapshot.state != .endPending else {
            snapshot.duplicateIgnored += 1
            publish()
            return
        }
        snapshot.controlEventType = "end"
        snapshot.controlSequence = event.sequence
        snapshot.controlEventLate = Int64(clock.now.timeIntervalSince1970 * 1_000) - event.sentAt > Int64(rxDrainHardCapMilliseconds)
        markEnded(sessionId: event.sessionId, leaseId: event.leaseId, source: source)
    }

    private func markEnded(sessionId: String, leaseId: String, source: String) {
        guard snapshot.sessionId == sessionId,
              snapshot.leaseId == leaseId,
              snapshot.state != .idle else { return }
        if snapshot.state == .draining || snapshot.state == .endPending { return }
        let now = clock.now
        snapshot.rxEndSignalAt = now
        if source == "control_end" { snapshot.rxControlEndReceivedAt = now }
        else { snapshot.rxFloorEndObservedAt = now }
        if !firstPcmObserved {
            pendingEndReason = source
            snapshot.state = .endPending
            snapshot.endBeforeAppleActivate = !appleAudioActive
            snapshot.endBeforeFirstPcm = true
            snapshot.shortBurstProtectionUsed = true
            publish()
            scheduleStartupTimeout()
            return
        }
        beginDrain(reason: source)
    }

    private func beginDrain(reason: String) {
        guard snapshot.state != .idle, snapshot.state != .draining else { return }
        generation += 1
        cancelTimers()
        let now = clock.now
        if !audioActive { silenceStartedAt = now }
        if snapshot.shortBurstProtectionUsed,
           let endedAt = snapshot.rxControlEndReceivedAt ?? snapshot.rxFloorEndObservedAt {
            snapshot.shortBurstProtectionMilliseconds = max(0, Int(now.timeIntervalSince(endedAt) * 1_000))
        }
        snapshot.state = .draining
        snapshot.rxDrainStartedAt = now
        snapshot.rxEndReason = reason
        publish()
        capTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(milliseconds: rxDrainHardCapMilliseconds)
            guard !Task.isCancelled else { return }
            Task { @MainActor [weak self] in await self?.completeDrain(reason: "hard_cap") }
        }
        scheduleDrainCheck()
    }

    private func scheduleStartupTimeout() {
        guard snapshot.state == .endPending,
              let startedAt = snapshot.rxControlStartReceivedAt else { return }
        startupTimeoutTask?.cancel()
        let absoluteDeadline = startedAt.addingTimeInterval(Double(rxStartupAbsoluteMaxMilliseconds) / 1_000)
        let graceDeadline = snapshot.rxAppleAudioActivatedAt.map {
            $0.addingTimeInterval(Double(rxFirstAudioGraceAfterActivateMilliseconds) / 1_000)
        }
        let deadline = min(absoluteDeadline, graceDeadline ?? absoluteDeadline)
        let wait = max(0, Int(deadline.timeIntervalSince(clock.now) * 1_000))
        let operation = generation
        startupTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(milliseconds: wait)
            guard !Task.isCancelled, operation == generation, snapshot.state == .endPending else { return }
            beginDrain(reason: "startup_timeout")
        }
    }

    private func playStartCueIfSafe() {
        guard startCueEnabled else {
            if snapshot.startCueResult == .notPlayed {
                snapshot.startCueResult = .skipped("Field Lab RX_START_CUE=OFF")
                publish()
            }
            return
        }
        guard appleAudioActive,
              snapshot.state != .idle,
              snapshot.startCueResult == .notPlayed else { return }
        let operation = generation
        snapshot.rxStartCueStartedAt = clock.now
        publish()
        Task { [weak self] in
            guard let self else { return }
            let result: CueResult
            do { try await cuePlayer.playStart(); result = .success }
            catch { result = .failure(String(error.localizedDescription.prefix(240))) }
            guard operation == generation else { return }
            snapshot.startCueResult = result
            snapshot.rxStartCueCompletedAt = clock.now
            publish()
        }
    }

    private func publishReadyIfNeeded(operation: Int) async {
        guard operation == generation,
              appleAudioActive,
              let speakerSessionId = snapshot.sessionId,
              let leaseId = snapshot.leaseId,
              readySentLeaseId != leaseId else { return }
        readySentLeaseId = leaseId
        await onReceiverReady(speakerSessionId, leaseId)
        guard operation == generation else { return }
        snapshot.rxReadySentAt = clock.now
        publish()
    }

    private func scheduleDrainCheck() {
        guard snapshot.state == .draining else { return }
        drainTask?.cancel()
        let now = clock.now
        let elapsed = Int(now.timeIntervalSince(snapshot.rxDrainStartedAt ?? now) * 1_000)
        let minimumRemaining = max(0, rxDrainMinimumMilliseconds - elapsed)
        let playoutRemaining = max(0, playoutDrainTargetMilliseconds - elapsed)
        let silenceElapsed = silenceStartedAt.map { Int(now.timeIntervalSince($0) * 1_000) } ?? 0
        let silenceRemaining = audioActive || silenceStartedAt == nil
            ? rxDrainHardCapMilliseconds
            : max(0, rxSilenceConfirmationMilliseconds - silenceElapsed)
        drainTask = Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(milliseconds: max(minimumRemaining, silenceRemaining, playoutRemaining))
            guard !Task.isCancelled else { return }
            let checkedAt = clock.now
            let drainElapsed = Int(checkedAt.timeIntervalSince(snapshot.rxDrainStartedAt ?? checkedAt) * 1_000)
            let silentFor = silenceStartedAt.map { Int(checkedAt.timeIntervalSince($0) * 1_000) } ?? 0
            if !audioActive,
               drainElapsed >= playoutDrainTargetMilliseconds,
               silentFor >= rxSilenceConfirmationMilliseconds {
                Task { @MainActor [weak self] in await self?.completeDrain(reason: "silence") }
            }
        }
    }

    private func completeDrain(reason: String) async {
        guard snapshot.state == .draining else { return }
        guard let completedSessionId = snapshot.sessionId,
              let completedLeaseId = snapshot.leaseId else { return }
        let completedGeneration = snapshot.generation
        generation += 1
        let operation = generation
        cancelTimers()
        let now = clock.now
        snapshot.rxDrainCompletedAt = now
        snapshot.rxPlaybackCompletedAt = now
        snapshot.rxDrainDurationMilliseconds = min(rxDrainHardCapMilliseconds, max(0, Int(now.timeIntervalSince(snapshot.rxDrainStartedAt ?? now) * 1_000)))
        snapshot.rxEndReason = reason
        publish()
        let result: CueResult
        if appleAudioActive {
            do { try await cuePlayer.playEnd(); result = .success }
            catch { result = .failure(String(error.localizedDescription.prefix(240))) }
        } else {
            result = .skipped("Apple audio session inactive")
        }
        guard operation == generation else { return }
        // Keep Apple's active remote participant until the END cue is complete.
        guard onDrainCompleted(completedGeneration, completedSessionId, completedLeaseId, reason) else {
            snapshot.rxEndReason = "remote_clear_rejected_\(reason)"
            publish()
            return
        }
        snapshot.rxRemoteParticipantClearedAt = clock.now
        snapshot.state = .idle
        snapshot.speakerUserId = nil
        snapshot.sessionId = nil
        snapshot.leaseId = nil
        snapshot.endCueResult = result
        publish()
    }

    private func cancelTimers() {
        drainTask?.cancel()
        capTask?.cancel()
        startupTimeoutTask?.cancel()
        drainTask = nil
        capTask = nil
        startupTimeoutTask = nil
    }

    private func publish() { onUpdate(snapshot) }
}
