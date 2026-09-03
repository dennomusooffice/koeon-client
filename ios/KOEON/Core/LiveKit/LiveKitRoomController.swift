import Combine
import AVFoundation
import Foundation
import LiveKit

private struct RxReadyCapabilityMetadata: Decodable {
    let deviceId: String
    let rxReadyProtocolVersion: Int
}

func rxReadyCapableDeviceId(metadata: String?) -> String? {
    guard let metadata,
          let data = metadata.data(using: .utf8),
          let value = try? JSONDecoder().decode(RxReadyCapabilityMetadata.self, from: data),
          value.rxReadyProtocolVersion == pttRxReadyVersion,
          !value.deviceId.isEmpty else { return nil }
    return value.deviceId
}

struct LiveKitIngressDiagnosticSnapshot: Sendable {
    var lastDelegateEvent: String?
    var lastDelegateIngressAt: Date?
    var lastDelegateMainApplyAt: Date?
}

enum ControlSenderIdentityResolution: String, Equatable, Sendable {
    case sdkEvent = "SDK_EVENT"
    case roomSessionMatch = "ROOM_SESSION_MATCH"
    case rejected = "REJECTED"
}

struct ResolvedControlSenderIdentity: Equatable, Sendable {
    let identity: String?
    let resolution: ControlSenderIdentityResolution
}

func resolveControlSenderIdentity(
    eventParticipantIdentity: String?,
    controlSessionId: String,
    currentRemoteParticipantIdentities: [String]
) -> ResolvedControlSenderIdentity {
    if let eventIdentity = eventParticipantIdentity?.trimmingCharacters(in: .whitespacesAndNewlines),
       !eventIdentity.isEmpty {
        return eventIdentity == controlSessionId
            ? ResolvedControlSenderIdentity(identity: eventIdentity, resolution: .sdkEvent)
            : ResolvedControlSenderIdentity(identity: nil, resolution: .rejected)
    }
    let matches = currentRemoteParticipantIdentities.filter { $0 == controlSessionId }
    return matches.count == 1
        ? ResolvedControlSenderIdentity(identity: controlSessionId, resolution: .roomSessionMatch)
        : ResolvedControlSenderIdentity(identity: nil, resolution: .rejected)
}

private struct LiveKitDelegateEnvelope: Sendable {
    let name: String
    let ingressAt: Date
    let event: LiveKitDelegateEvent
}

private enum LiveKitDelegateEvent: Sendable {
    case connectionState(KOEONConnectionState, disconnectedFromActiveState: Bool)
    case reconnectStarted(String)
    case reconnectCompleted([String])
    case disconnected(String?)
    case participantDisconnected(sessionId: String?, names: [String])
    case participantConnected(sessionId: String?, names: [String])
    case speakingParticipant(name: String?, sessionId: String?)
    case pttControl(PttControlEvent, senderSessionId: String?, resolution: ControlSenderIdentityResolution)
    case rxReady(PttRxReadyEvent, participantIdentity: String?, participantDeviceId: String?)
}

@MainActor
final class LiveKitRoomController: NSObject, ObservableObject, MicrophoneControlling, PttControlPublishing, RoomDelegate, @unchecked Sendable {
    @Published private(set) var connectionState: KOEONConnectionState = .disconnected
    @Published private(set) var participantNames: [String] = []
    @Published private(set) var currentSpeaker: String?
    @Published private(set) var currentSpeakerSessionId: String?
    @Published private(set) var remoteMediaSpeakerActive = false
    @Published private(set) var reconnectCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var deployment = "UNKNOWN"
    @Published private(set) var endpointHost: String?

    var onUnsafeDisconnect: (@MainActor @Sendable (String) -> Void)?
    var onReconnected: (@MainActor @Sendable () -> Void)?
    var onConnectionStateChanged: (@MainActor @Sendable (KOEONConnectionState) -> Void)?
    var onPttControl: (@MainActor @Sendable (PttControlEvent, String?) -> Void)?
    var onRemoteAudioActivity: (@MainActor @Sendable (String?, Bool) -> Void)?
    var onRemotePcm: (@MainActor @Sendable (Date) -> Void)?
    var onRxReadyPublished: (@MainActor @Sendable (Date) -> Void)?
    var onParticipantAvailable: (@MainActor @Sendable (String) -> Void)?

    private var room: Room?
    private var canPublish = false
    private var reconnectInProgress = false
    private var channelId: String?
    private var userId: String?
    private var sessionId: String?
    private var deviceId: String?
    private var controlSequence: Int64 = 0
    private lazy var remotePcmObserver = RemotePcmTimestampObserver { [weak self] timestamp in
        Task { @MainActor in self?.onRemotePcm?(timestamp) }
    }
    private var remotePcmObserverInstalled = false
    private var remoteAudioSubscriptionGate = RemoteAudioSubscriptionGenerationGate()
    private let rxReadyBarrier = PttRxReadyBarrier()
    private var ingressDiagnostics = LiveKitIngressDiagnosticSnapshot()
    private(set) var controlSenderIdentityResolution = ControlSenderIdentityResolution.rejected

    static func expectedRxReadySessions(
        serverExpected: [String],
        remoteIdentities: [String],
        localSessionId: String?
    ) -> [String] {
        Array(Set((serverExpected + remoteIdentities).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != localSessionId })).sorted()
    }

    func connect(
        url: String,
        token: String,
        canPublish: Bool,
        channelId: String,
        userId: String,
        sessionId: String,
        deviceId: String? = nil,
        audioPublishProfile: AudioPublishProfile
    ) async throws {
        guard room == nil else { return }
        self.canPublish = canPublish
        self.channelId = channelId
        self.userId = userId
        self.sessionId = sessionId
        self.deviceId = deviceId
        connectionState = .connecting
        let captureOptions = AudioCaptureOptions(
            echoCancellation: true,
            autoGainControl: true,
            noiseSuppression: true,
            highpassFilter: true,
            typingNoiseDetection: true
        )
        let publishOptions = AudioPublishOptions(
            encoding: audioPublishProfile.liveKitEncoding,
            dtx: true,
            red: true
        )
        let room = Room(
            delegate: self,
            roomOptions: RoomOptions(
                defaultAudioCaptureOptions: captureOptions,
                defaultAudioPublishOptions: publishOptions
            )
        )
        self.room = room
        let endpoint = Self.endpointDiagnostic(url)
        deployment = endpoint.deployment
        endpointHost = endpoint.host
        do {
            try await room.connect(url: url, token: token)
            installRemotePcmObserverIfNeeded()
            connectionState = .connected
            refreshParticipants(room)
        } catch {
            self.room = nil
            connectionState = .disconnected
            lastError = safeMessage(error)
            throw error
        }
    }

    func disconnect() async {
        if canPublish { try? await setMicrophoneEnabled(false) }
        let departingRoom = room
        room = nil
        await departingRoom?.disconnect()
        removeRemotePcmObserverIfNeeded()
        room = nil
        connectionState = .disconnected
        participantNames = []
        clearRemoteMediaActivity(notify: true)
        canPublish = false
        reconnectInProgress = false
        channelId = nil
        userId = nil
        sessionId = nil
        deviceId = nil
        deployment = "UNKNOWN"
        endpointHost = nil
        controlSequence = 0
        controlSenderIdentityResolution = .rejected
        remoteAudioSubscriptionGate.reset()
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let room, room.connectionState == .connected else {
            throw LiveKitRoomError.notConnected
        }
        if enabled, !canPublish { throw LiveKitRoomError.publishForbidden }
        _ = try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics {
        try await publishStartControl(leaseId: leaseId, bufferedGenerationId: nil)
    }

    func publishBufferedStart(leaseId: String, generationId: String) async throws -> PttStartPublishDiagnostics {
        try await publishStartControl(leaseId: leaseId, bufferedGenerationId: generationId)
    }

    func publishEnd(leaseId: String) async throws {
        try await publishControl(type: "end", leaseId: leaseId)
    }

    func prepareRxReady(leaseId: String, expectedSessionIds: [String]) async {
        await prepareRxReady(leaseId: leaseId, expectedSessionIds: expectedSessionIds, expectedDeviceIds: [])
    }

    func prepareRxReady(leaseId: String, expectedSessionIds: [String], expectedDeviceIds: [String]) async {
        let expected = Self.expectedRxReadySessions(
            serverExpected: expectedSessionIds,
            remoteIdentities: [],
            localSessionId: sessionId
        )
        let warmCapableDevices = room?.remoteParticipants.values.compactMap(Self.rxReadyCapableDeviceIdentity) ?? []
        let devices = Array(Set((expectedDeviceIds + warmCapableDevices).filter { !$0.isEmpty && $0 != deviceId }))
        await rxReadyBarrier.prepare(leaseId: leaseId, expectedSessionIds: expected, expectedDeviceIds: devices)
    }

    func awaitRxReady(leaseId: String, maximumWaitMilliseconds: Int? = nil) async -> PttRxReadyWaitResult {
        await rxReadyBarrier.wait(leaseId: leaseId, maximumWaitMilliseconds: maximumWaitMilliseconds)
    }

    func cancelRxReady(leaseId: String) async {
        await rxReadyBarrier.cancel(leaseId: leaseId)
    }

    func publishRxReady(speakerSessionId: String, leaseId: String) async throws {
        guard let room, room.connectionState == .connected,
              let channelId, let receiverSessionId = sessionId else {
            throw LiveKitRoomError.notConnected
        }
        let event = PttRxReadyEvent(
            version: pttRxReadyVersion,
            type: "rx_ready",
            channelId: channelId,
            speakerSessionId: speakerSessionId,
            receiverSessionId: receiverSessionId,
            receiverDeviceId: deviceId,
            leaseId: leaseId,
            readyAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try await room.localParticipant.publish(
            data: try JSONEncoder().encode(event),
            options: DataPublishOptions(topic: pttRxReadyTopic, reliable: true)
        )
        onRxReadyPublished?(Date())
    }

    func trustedRemoteSpeaker(sessionId: String) -> TrustedRemoteSpeaker? {
        guard let participant = room?.remoteParticipants.values.first(where: {
            $0.identity?.stringValue == sessionId
        }), let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty else {
            return nil
        }
        return TrustedRemoteSpeaker(sessionId: sessionId, displayName: name)
    }

    /// Uses LiveKit's supported subscription API to keep the current generation
    /// subscribed while Apple owns audible playout.
    @discardableResult
    func activateRemoteAudioSubscription(sessionId: String, generation: Int) async throws -> Bool {
        let subscribed = try await setRemoteAudioSubscribed(sessionId: sessionId, subscribed: true)
        if subscribed {
            remoteAudioSubscriptionGate.activate(sessionId: sessionId, generation: generation)
        }
        return subscribed
    }

    /// Flushes a completed generation only after Apple confirms that the active
    /// remote participant was cleared. The false -> true transition discards old
    /// decoder media, then leaves the publication warm for the next RX. Returns
    /// false when a newer generation replaces this operation while suspended.
    func discardRemoteAudioSubscription(sessionId: String, generation: Int) async throws -> Bool {
        guard remoteAudioSubscriptionGate.acceptsDiscard(sessionId: sessionId, generation: generation) else {
            return false
        }
        try await setRemoteAudioSubscribed(sessionId: sessionId, subscribed: false)
        guard remoteAudioSubscriptionGate.completeDiscard(sessionId: sessionId, generation: generation) else {
            try await setRemoteAudioSubscribed(sessionId: sessionId, subscribed: true)
            return false
        }
        try await setRemoteAudioSubscribed(sessionId: sessionId, subscribed: true)
        return true
    }

    func isRemoteAudioSubscriptionActive(sessionId: String, generation: Int) -> Bool {
        guard remoteAudioSubscriptionGate.isActive(sessionId: sessionId, generation: generation),
              let participant = room?.remoteParticipants.values.first(where: { $0.identity?.stringValue == sessionId }) else { return false }
        return participant.audioTracks.contains { $0.isSubscribed && $0.track != nil }
    }

    func remoteParticipantIsSpeaking(sessionId: String) -> Bool? {
        room?.remoteParticipants.values.first(where: {
            $0.identity?.stringValue == sessionId
        })?.isSpeaking
    }

    /// Clears only the currently-matching media hint after the caller has
    /// verified authoritative SDK state is inactive. It does not touch the
    /// validated RX coordinator or create/replace a receive generation.
    func clearVerifiedInactiveRemoteMediaActivity(sessionId: String?) {
        guard remoteMediaSpeakerActive,
              sessionId == nil || currentSpeakerSessionId == sessionId else { return }
        clearRemoteMediaActivity(notify: true)
    }

    @discardableResult
    private func setRemoteAudioSubscribed(sessionId: String, subscribed: Bool) async throws -> Bool {
        guard let participant = room?.remoteParticipants.values.first(where: {
            $0.identity?.stringValue == sessionId
        }) else { return false }
        let publications = participant.audioTracks.compactMap { $0 as? RemoteTrackPublication }
        guard !publications.isEmpty else { return false }
        for publication in publications {
            try await publication.set(subscribed: subscribed)
        }
        return true
    }

    private func publishControl(type: String, leaseId: String, bufferedGenerationId: String? = nil) async throws {
        guard let room, room.connectionState == .connected,
              let channelId, let userId, let sessionId else {
            throw LiveKitRoomError.notConnected
        }
        controlSequence += 1
        let event = PttControlEvent(
            version: pttControlVersion,
            type: type,
            channelId: channelId,
            speakerUserId: userId,
            sessionId: sessionId,
            leaseId: leaseId,
            sequence: controlSequence,
            sentAt: Int64(Date().timeIntervalSince1970 * 1_000),
            bufferedGenerationId: bufferedGenerationId
        )
        let data = try JSONEncoder().encode(event)
        try await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: pttControlTopic, reliable: true)
        )
    }

    private func publishStartControl(leaseId: String, bufferedGenerationId: String?) async throws -> PttStartPublishDiagnostics {
        guard let room, room.connectionState == .connected,
              let channelId, let userId, let sessionId else { throw LiveKitRoomError.notConnected }
        controlSequence += 1
        let event = PttControlEvent(
            version: pttControlVersion, type: "start", channelId: channelId,
            speakerUserId: userId, sessionId: sessionId, leaseId: leaseId,
            sequence: controlSequence, sentAt: Int64(Date().timeIntervalSince1970 * 1_000),
            bufferedGenerationId: bufferedGenerationId
        )
        let data = try JSONEncoder().encode(event)
        var result = PttStartPublishDiagnostics()
        result.fastStartedAt = Date()
        do {
            try await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: pttControlFastStartTopic, reliable: false)
            )
        } catch {
            // Reliable fallback below remains authoritative for delivery.
        }
        result.fastCompletedAt = Date()
        result.fastMilliseconds = Self.milliseconds(result.fastStartedAt, result.fastCompletedAt)
        result.reliableStartedAt = Date()
        try await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: pttControlTopic, reliable: true)
        )
        result.reliableCompletedAt = Date()
        result.reliableMilliseconds = Self.milliseconds(result.reliableStartedAt, result.reliableCompletedAt)
        return result
    }

    private static func milliseconds(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "didUpdateConnectionState",
            event: .connectionState(
                Self.mapConnection(connectionState),
                disconnectedFromActiveState: connectionState == .disconnected && oldConnectionState != .disconnected
            )
        )
    }

    nonisolated func roomIsReconnecting(_ room: Room) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "roomIsReconnecting",
            event: .reconnectStarted("LiveKit Room is reconnecting; TX was stopped.")
        )
    }

    nonisolated func roomDidReconnect(_ room: Room) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "roomDidReconnect",
            event: .reconnectCompleted(Self.participantNameSnapshot(room))
        )
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "didStartReconnectWithMode",
            event: .reconnectStarted("LiveKit reconnect started; TX was stopped.")
        )
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "didCompleteReconnectWithMode",
            event: .reconnectCompleted(Self.participantNameSnapshot(room))
        )
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let message = error.map { issue in Self.safeMessageSnapshot(issue) }
        enqueueDelegateEvent(sourceRoom: room, name: "didDisconnectWithError", event: .disconnected(message))
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "participantDidConnect",
            event: .participantConnected(
                sessionId: participant.identity?.stringValue,
                names: Self.participantNameSnapshot(room)
            )
        )
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        enqueueDelegateEvent(sourceRoom: room,
            name: "participantDidDisconnect",
            event: .participantDisconnected(
                sessionId: participant.identity?.stringValue,
                names: Self.participantNameSnapshot(room)
            )
        )
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let remote = participants.compactMap { $0 as? RemoteParticipant }.first
        enqueueDelegateEvent(sourceRoom: room,
            name: "didUpdateSpeakingParticipants",
            event: .speakingParticipant(
                name: remote.flatMap(Self.displayName),
                sessionId: remote?.identity?.stringValue
            )
        )
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        if (topic == pttControlTopic || topic == pttControlFastStartTopic),
           let event = PttControlCodec.decode(data),
           topic != pttControlFastStartTopic || event.type == "start" {
            let resolved = resolveControlSenderIdentity(
                eventParticipantIdentity: participant?.identity?.stringValue,
                controlSessionId: event.sessionId,
                currentRemoteParticipantIdentities: room.remoteParticipants.values.compactMap {
                    $0.identity?.stringValue
                }
            )
            enqueueDelegateEvent(sourceRoom: room,
                name: "didReceiveData.pttControl",
                event: .pttControl(
                    event,
                    senderSessionId: resolved.identity,
                    resolution: resolved.resolution
                )
            )
            return
        }
        if topic == pttRxReadyTopic, let event = PttRxReadyCodec.decode(data) {
            enqueueDelegateEvent(sourceRoom: room,
                name: "didReceiveData.rxReady",
                event: .rxReady(
                    event,
                    participantIdentity: participant?.identity?.stringValue,
                    participantDeviceId: participant.flatMap(Self.deviceIdentity)
                )
            )
        }
    }

    func ingressDiagnosticSnapshot() -> LiveKitIngressDiagnosticSnapshot {
        ingressDiagnostics
    }

    nonisolated private func enqueueDelegateEvent(sourceRoom: Room, name: String, event: LiveKitDelegateEvent) {
        let sourceIdentity = ObjectIdentifier(sourceRoom)
        let envelope = LiveKitDelegateEnvelope(name: name, ingressAt: Date(), event: event)
        Task { @MainActor [weak self] in
            guard let self, self.room.map({ ObjectIdentifier($0) }) == sourceIdentity else { return }
            self.applyDelegateEvent(envelope)
        }
    }

    private func applyDelegateEvent(_ envelope: LiveKitDelegateEnvelope) {
        ingressDiagnostics.lastDelegateEvent = envelope.name
        ingressDiagnostics.lastDelegateIngressAt = envelope.ingressAt
        ingressDiagnostics.lastDelegateMainApplyAt = Date()
        switch envelope.event {
        case let .connectionState(state, disconnectedFromActiveState):
            applyConnectionState(state, disconnectedFromActiveState: disconnectedFromActiveState)
        case let .reconnectStarted(reason):
            markReconnecting(reason)
        case let .reconnectCompleted(names):
            applyReconnectCompleted(participantNames: names)
        case let .disconnected(message):
            applyDisconnected(errorMessage: message)
        case let .participantDisconnected(sessionId, names):
            participantNames = names
            if currentSpeakerSessionId == sessionId { clearRemoteMediaActivity(notify: true) }
        case let .participantConnected(sessionId, names):
            participantNames = names
            if let sessionId { onParticipantAvailable?(sessionId) }
        case let .speakingParticipant(name, sessionId):
            if let sessionId {
                currentSpeaker = name
                currentSpeakerSessionId = sessionId
                remoteMediaSpeakerActive = true
                onRemoteAudioActivity?(sessionId, true)
            } else {
                clearRemoteMediaActivity(notify: true)
            }
        case let .pttControl(event, senderSessionId, resolution):
            controlSenderIdentityResolution = resolution
            guard let senderSessionId else { return }
            onPttControl?(event, senderSessionId)
        case let .rxReady(event, participantIdentity, participantDeviceId):
            guard event.channelId == channelId, event.speakerSessionId == sessionId else { return }
            Task { await rxReadyBarrier.accept(
                event,
                participantIdentity: participantIdentity,
                participantDeviceId: participantDeviceId
            ) }
        }
    }

    nonisolated private static func deviceIdentity(_ participant: RemoteParticipant) -> String? {
        guard let metadata = participant.metadata,
              let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = object["deviceId"] as? String,
              !deviceId.isEmpty else { return nil }
        return deviceId
    }

    nonisolated private static func rxReadyCapableDeviceIdentity(_ participant: RemoteParticipant) -> String? {
        rxReadyCapableDeviceId(metadata: participant.metadata)
    }

    private func applyConnectionState(
        _ state: KOEONConnectionState,
        disconnectedFromActiveState: Bool
    ) {
        let previousState = connectionState
        connectionState = state
        if state == .disconnected { clearRemoteMediaActivity(notify: true) }
        onConnectionStateChanged?(state)
        if state == .disconnected,
           disconnectedFromActiveState,
           previousState != .disconnected {
            onUnsafeDisconnect?("LiveKit Room disconnected.")
        }
    }

    private func applyReconnectCompleted(participantNames names: [String]) {
        let shouldNotifyReconnect = reconnectInProgress || connectionState == .reconnecting
        reconnectInProgress = false
        connectionState = .connected
        onConnectionStateChanged?(.connected)
        participantNames = names
        if shouldNotifyReconnect { onReconnected?() }
    }

    private func applyDisconnected(errorMessage: String?) {
        let shouldNotifyDisconnect = connectionState != .disconnected
        reconnectInProgress = false
        connectionState = .disconnected
        onConnectionStateChanged?(.disconnected)
        lastError = errorMessage
        clearRemoteMediaActivity(notify: true)
        if shouldNotifyDisconnect { onUnsafeDisconnect?("LiveKit Room disconnected.") }
    }

    private func refreshParticipants(_ room: Room) {
        var names = room.remoteParticipants.values.compactMap(Self.displayName)
        if let local = Self.displayName(room.localParticipant) { names.append(local) }
        participantNames = names.sorted()
    }

    private func installRemotePcmObserverIfNeeded() {
        guard !remotePcmObserverInstalled else { return }
        AudioManager.shared.add(remoteAudioRenderer: remotePcmObserver)
        remotePcmObserverInstalled = true
    }

    private func removeRemotePcmObserverIfNeeded() {
        guard remotePcmObserverInstalled else { return }
        AudioManager.shared.remove(remoteAudioRenderer: remotePcmObserver)
        remotePcmObserverInstalled = false
    }

    private func markReconnecting(_ reason: String) {
        guard !reconnectInProgress else { return }
        reconnectCount += 1
        reconnectInProgress = true
        connectionState = .reconnecting
        clearRemoteMediaActivity(notify: true)
        onConnectionStateChanged?(.reconnecting)
        onUnsafeDisconnect?(reason)
    }

    private func clearRemoteMediaActivity(notify: Bool) {
        let previousSessionId = currentSpeakerSessionId
        currentSpeaker = nil
        currentSpeakerSessionId = nil
        remoteMediaSpeakerActive = false
        if notify { onRemoteAudioActivity?(previousSessionId, false) }
    }

    nonisolated private static func participantNameSnapshot(_ room: Room) -> [String] {
        var names = room.remoteParticipants.values.compactMap(displayName)
        if let local = displayName(room.localParticipant) { names.append(local) }
        return names.sorted()
    }

    nonisolated private static func displayName(_ participant: Participant) -> String? {
        if let name = participant.name, !name.isEmpty { return name }
        return participant.identity?.stringValue
    }

    nonisolated private static func mapConnection(_ state: ConnectionState) -> KOEONConnectionState {
        switch state {
        case .disconnected, .disconnecting: .disconnected
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .connected: .connected
        }
    }

    nonisolated private static func safeMessageSnapshot(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }

    static func endpointDiagnostic(_ value: String) -> (deployment: String, host: String?) {
        guard let host = URL(string: value)?.host?.lowercased() else {
            return ("UNKNOWN", nil)
        }
        if host == "livekit.example.invalid" { return ("SELF_HOST", host) }
        if host.hasSuffix(".livekit.cloud") { return ("CLOUD", host) }
        return ("UNKNOWN", host)
    }

    private func safeMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }
}

/// Timestamp-only observer. It never copies, queues, modifies, or replays PCM.
private final class RemotePcmTimestampObserver: AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var lastDispatch = Date.distantPast
    private let onPcm: @Sendable (Date) -> Void

    init(onPcm: @escaping @Sendable (Date) -> Void) { self.onPcm = onPcm }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0 else { return }
        let now = Date()
        let shouldDispatch = lock.withLock {
            guard now.timeIntervalSince(lastDispatch) >= 0.02 else { return false }
            lastDispatch = now
            return true
        }
        if shouldDispatch { onPcm(now) }
    }
}

private enum LiveKitRoomError: LocalizedError {
    case notConnected
    case publishForbidden

    var errorDescription: String? {
        switch self {
        case .notConnected: "LiveKit Room is not connected."
        case .publishForbidden: "This session is RX-only."
        }
    }
}
