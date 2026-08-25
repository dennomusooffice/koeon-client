import XCTest
import PushToTalk
@testable import KOEON

@MainActor
final class RxAudioControllerTests: XCTestCase {
    func testWarmReadyExpectedIncludesRemoteSessionsAndExcludesLocalDuplicates() {
        let expected = LiveKitRoomController.expectedRxReadySessions(
            serverExpected: ["wake-a", "remote-b", "remote-b"],
            remoteIdentities: ["remote-b", "listener-c", "", "local"],
            localSessionId: "local"
        )
        XCTAssertEqual(expected, ["listener-c", "remote-b", "wake-a"])
    }
    func testControlCodecRejectsUnsupportedVersion() {
        let invalid = Data(#"{"version":2,"type":"start","channelId":"stage","speakerUserId":"staff-a","sessionId":"session-a","leaseId":"lease-a","sequence":1,"sentAt":1}"#.utf8)
        XCTAssertNil(PttControlCodec.decode(invalid))
    }

    func testRxReadyCodecRequiresStrictVersionAndIdentityFields() throws {
        let event = PttRxReadyEvent(
            version: 1, type: "rx_ready", channelId: "stage",
            speakerSessionId: "session-a", receiverSessionId: "session-b",
            leaseId: "lease-a", readyAt: 1
        )
        XCTAssertEqual(PttRxReadyCodec.decode(try JSONEncoder().encode(event)), event)
        let invalid = Data(#"{"version":2,"type":"rx_ready","channelId":"stage","speakerSessionId":"session-a","receiverSessionId":"session-b","leaseId":"lease-a","readyAt":1}"#.utf8)
        XCTAssertNil(PttRxReadyCodec.decode(invalid))
    }

    func testRxReadyBarrierUnlocksOnlyExpectedTrustedParticipant() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(leaseId: "lease-a", expectedSessionIds: ["session-b"])
        let event = PttRxReadyEvent(
            version: 1, type: "rx_ready", channelId: "stage",
            speakerSessionId: "session-a", receiverSessionId: "session-b",
            leaseId: "lease-a", readyAt: 1
        )
        await barrier.accept(event, participantIdentity: "attacker")
        await barrier.accept(event, participantIdentity: "session-b")
        let result = await barrier.wait(leaseId: "lease-a")
        XCTAssertEqual(result.expectedCount, 1)
        XCTAssertEqual(result.receivedCount, 1)
        XCTAssertFalse(result.timedOut)
    }

    func testDidActivateSendsReadyBeforeBestEffortStartCueCompletes() async {
        let ready = expectation(description: "RX Ready sent")
        let cue = expectation(description: "RX start cue played")
        let order = EventOrderRecorder { value in
            if value == "ready:session-a:lease-a" { ready.fulfill() }
            if value == "start-cue" { cue.fulfill() }
        }
        let controller = RxAudioController(
            channelId: "stage",
            cuePlayer: RecordingCue(order: order),
            onReceiverReady: { session, lease in order.append("ready:\(session):\(lease)") },
            onUpdate: { _ in }
        )
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.audioSessionDidActivate()
        await fulfillment(of: [ready, cue], timeout: 1)
        controller.audioSessionDidActivate()
        XCTAssertEqual(order.values.filter { $0 == "start-cue" }.count, 1)
        XCTAssertEqual(order.values.filter { $0 == "ready:session-a:lease-a" }.count, 1)
        guard let readyIndex = order.values.firstIndex(of: "ready:session-a:lease-a"),
              let cueIndex = order.values.firstIndex(of: "start-cue") else {
            return XCTFail("Expected RX Ready and start cue events")
        }
        XCTAssertLessThan(readyIndex, cueIndex)
    }

    func testFieldLabCueOffStillSendsReceiverReadyWithoutPlayingStartCue() async {
        let ready = expectation(description: "RX Ready sent with cue disabled")
        let order = EventOrderRecorder { value in
            if value == "ready:session-a:lease-a" { ready.fulfill() }
        }
        let controller = RxAudioController(
            channelId: "stage",
            cuePlayer: RecordingCue(order: order),
            onReceiverReady: { session, lease in order.append("ready:\(session):\(lease)") },
            startCueEnabled: false,
            onUpdate: { _ in }
        )
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.audioSessionDidActivate()
        await fulfillment(of: [ready], timeout: 1)
        XCTAssertEqual(order.values.filter { $0 == "ready:session-a:lease-a" }.count, 1)
        XCTAssertEqual(order.values.filter { $0 == "start-cue" }.count, 0)
        guard case .skipped = controller.currentSnapshot().startCueResult else {
            return XCTFail("Expected Field Lab cue skip")
        }
    }

    func testStartAndEndEnterBoundedDrainWithoutStoppingAudioTrack() {
        let recorder = RxRecorder()
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue()) {
            recorder.value = $0
        }
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        XCTAssertEqual(controller.currentSnapshot().state, .arming)
        controller.audioSessionDidActivate()
        XCTAssertEqual(controller.currentSnapshot().state, .waitingFirstAudio)
        controller.handleRemotePcm(at: Date())
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: true)
        XCTAssertEqual(controller.currentSnapshot().state, .active)

        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        let draining = controller.currentSnapshot()
        XCTAssertEqual(draining.state, .draining)
        XCTAssertNotNil(draining.rxDrainStartedAt)
        XCTAssertEqual(rxDrainMinimumMilliseconds, 120)
        XCTAssertEqual(rxDrainHardCapMilliseconds, 350)
    }

    func testBluetoothOutputPipelineExtendsDrainTargetWithoutExceedingHardCap() {
        XCTAssertEqual(
            RxPlayoutDrainPolicy.estimatedOutputPipelineMilliseconds(
                outputLatency: 0.18,
                ioBufferDuration: 0.02,
                route: AudioRouteKind.bluetooth.rawValue
            ),
            220
        )
        XCTAssertEqual(
            RxPlayoutDrainPolicy.drainTargetMilliseconds(
                outputLatency: 0.18,
                ioBufferDuration: 0.02,
                route: AudioRouteKind.bluetooth.rawValue
            ),
            220
        )
        XCTAssertEqual(
            RxPlayoutDrainPolicy.drainTargetMilliseconds(
                outputLatency: 2,
                ioBufferDuration: 1,
                route: AudioRouteKind.bluetooth.rawValue
            ),
            rxDrainHardCapMilliseconds
        )
    }

    func testAudioActivationRecordsPlayoutAwareDrainTargetForCurrentRoute() {
        let clock = SuspendingClock()
        let controller = RxAudioController(
            channelId: "stage", cuePlayer: ImmediateCue(), clock: clock, onUpdate: { _ in }
        )
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.audioSessionDidActivate(
            outputLatency: 0.18,
            ioBufferDuration: 0.02,
            route: AudioRouteKind.bluetooth.rawValue
        )
        controller.handleRemotePcm(at: clock.now)
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: false)
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")

        let snapshot = controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .draining)
        XCTAssertEqual(snapshot.estimatedOutputPipelineMilliseconds, 220)
        XCTAssertEqual(snapshot.rxPlayoutDrainTargetMilliseconds, 220)
    }

    func testNewSpeakerPreemptsDrainAndStaleEndCannotStopIt() {
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue()) { _ in }
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        controller.handleControl(event(type: "start", session: "session-b", lease: "lease-b", sequence: 1), senderSessionId: "session-b")
        controller.handleControl(event(type: "end", sequence: 3), senderSessionId: "session-a")

        let snapshot = controller.currentSnapshot()
        XCTAssertEqual(snapshot.sessionId, "session-b")
        XCTAssertEqual(snapshot.preempted, 1)
        XCTAssertEqual(snapshot.staleIgnored, 1)
    }

    func testSpeakingBeforeControlDoesNotFabricateFirstPcm() {
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue()) { _ in }
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: true)
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        let snapshot = controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .arming)
        XCTAssertNil(snapshot.rxFirstPcmAt)
        XCTAssertNil(snapshot.rxLastAudioAt)
        guard case .skipped = snapshot.startCueResult else {
            return XCTFail("Expected voice-priority cue skip")
        }
    }

    func testHealthyRemoteRxKeepsMediaAuthorizationAndPcmDistinct() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)
        guardState.updateValidatedRx(
            active: true,
            sessionId: "session-a",
            generation: 7,
            participantResolved: true,
            trackSubscribed: true,
            at: started
        )
        XCTAssertEqual(
            guardState.handleRemotePcm(
                sessionId: "session-a",
                generation: 7,
                at: started.addingTimeInterval(0.02)
            ),
            .observed
        )
        XCTAssertTrue(guardState.snapshot.remoteMediaSpeakerActive)
        XCTAssertTrue(guardState.snapshot.validatedRemoteRxActive)
        XCTAssertTrue(guardState.snapshot.remotePcmObserved)
        XCTAssertTrue(guardState.snapshot.remoteBusyBlocksLocalPtt)

        guardState.handleMediaActivity(sessionId: "session-a", active: false, at: started.addingTimeInterval(0.1))
        guardState.updateValidatedRx(
            active: false, sessionId: nil, generation: 0, participantResolved: false, trackSubscribed: false,
            at: started.addingTimeInterval(0.1)
        )
        XCTAssertFalse(guardState.snapshot.remoteBusyBlocksLocalPtt)
    }

    func testMediaOnlyFieldDivergencePast250msKeepsPttBlockedWhileSdkStillSpeaking() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)
        XCTAssertTrue(guardState.snapshot.remoteBusyBlocksLocalPtt)
        XCTAssertFalse(guardState.snapshot.validatedRemoteRxActive)

        let evaluation = guardState.evaluate(
            at: started.addingTimeInterval(0.25),
            thresholdMilliseconds: 250,
            remoteParticipantIsSpeaking: true
        )
        XCTAssertEqual(evaluation.signals.map(\.event), ["rx_divergence_detected"])
        XCTAssertNil(evaluation.verifiedInactiveMediaSessionId)
        XCTAssertTrue(guardState.snapshot.remoteMediaSpeakerActive)
        XCTAssertTrue(guardState.snapshot.remoteBusyBlocksLocalPtt)
    }

    func testFiveHundredMillisecondSpeakerCadenceNeverPrematurelyClearsBusy() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)

        let firstWatchdog = guardState.evaluate(
            at: started.addingTimeInterval(0.25),
            remoteParticipantIsSpeaking: true
        )
        XCTAssertEqual(firstWatchdog.signals.map(\.event), ["rx_divergence_detected"])
        XCTAssertTrue(guardState.snapshot.remoteBusyBlocksLocalPtt)

        guardState.handleMediaActivity(
            sessionId: "session-a",
            active: true,
            at: started.addingTimeInterval(0.5)
        )
        let secondWatchdog = guardState.evaluate(
            at: started.addingTimeInterval(0.75),
            remoteParticipantIsSpeaking: true
        )
        XCTAssertTrue(secondWatchdog.signals.isEmpty)
        XCTAssertNil(secondWatchdog.verifiedInactiveMediaSessionId)
        XCTAssertTrue(guardState.snapshot.remoteBusyBlocksLocalPtt)
    }

    func testWatchdogClearsOnlyAfterSdkConfirmsParticipantNotSpeaking() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)

        let evaluation = guardState.evaluate(
            at: started.addingTimeInterval(0.25),
            remoteParticipantIsSpeaking: false
        )
        XCTAssertEqual(evaluation.signals.map(\.event), ["rx_divergence_detected", "rx_divergence_cleared"])
        XCTAssertEqual(evaluation.verifiedInactiveMediaSessionId, "session-a")
        XCTAssertFalse(guardState.snapshot.remoteBusyBlocksLocalPtt)
    }

    func testSpeakingInactiveDeterministicallyClearsMediaBusyBeforeWatchdog() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)
        guardState.handleMediaActivity(sessionId: "session-a", active: false, at: started.addingTimeInterval(0.04))

        XCTAssertFalse(guardState.snapshot.remoteMediaSpeakerActive)
        XCTAssertFalse(guardState.snapshot.remoteBusyBlocksLocalPtt)
        XCTAssertTrue(guardState.evaluate(at: started.addingTimeInterval(1)).signals.isEmpty)
    }

    func testMatchingParticipantDisconnectCallbackClearsMediaBusy() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)

        // LiveKitRoomController maps a matching participantDidDisconnect to
        // this explicit inactive media transition.
        guardState.handleMediaActivity(
            sessionId: "session-a",
            active: false,
            at: started.addingTimeInterval(0.05)
        )
        XCTAssertFalse(guardState.snapshot.remoteMediaSpeakerActive)
        XCTAssertFalse(guardState.snapshot.remoteBusyBlocksLocalPtt)
    }

    func testValidatedRxStillBlocksPttAfterExplicitMediaHintClear() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.handleMediaActivity(sessionId: "session-a", active: true, at: started)
        guardState.updateValidatedRx(
            active: true,
            sessionId: "session-a",
            generation: 8,
            participantResolved: true,
            trackSubscribed: true,
            at: started
        )
        guardState.handleMediaActivity(
            sessionId: "session-a",
            active: false,
            at: started.addingTimeInterval(0.05)
        )

        XCTAssertFalse(guardState.snapshot.remoteMediaSpeakerActive)
        XCTAssertTrue(guardState.snapshot.validatedRemoteRxActive)
        XCTAssertTrue(guardState.snapshot.remoteBusyBlocksLocalPtt)
    }

    func testSpeakingCallbackAloneLeavesRxGenerationIdle() {
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue()) { _ in }
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: true)

        let snapshot = controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.generation, 0)
        XCTAssertNil(snapshot.sessionId)
        XCTAssertNil(snapshot.rxFirstPcmAt)
    }

    func testValidatedRxWithoutPcmDiagnosesAndAttemptsRecoveryOnlyOnce() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.updateValidatedRx(
            active: true,
            sessionId: "session-a",
            generation: 9,
            participantResolved: true,
            trackSubscribed: false,
            at: started
        )

        let first = guardState.evaluate(at: started.addingTimeInterval(0.25), thresholdMilliseconds: 250)
        XCTAssertEqual(first.signals.map(\.event), ["rx_pcm_timeout"])
        XCTAssertEqual(first.recoverySessionId, "session-a")
        XCTAssertEqual(first.recoveryGeneration, 9)
        XCTAssertEqual(guardState.snapshot.recoveryAttempts, 1)

        let second = guardState.evaluate(at: started.addingTimeInterval(1), thresholdMilliseconds: 250)
        XCTAssertTrue(second.signals.isEmpty)
        XCTAssertNil(second.recoverySessionId)
        XCTAssertEqual(guardState.snapshot.recoveryAttempts, 1)
    }

    func testOldGenerationPcmCannotSatisfyCurrentRxFence() {
        let started = Date(timeIntervalSince1970: 1_000)
        var guardState = RxConsistencyGuard()
        guardState.updateValidatedRx(
            active: true,
            sessionId: "session-b",
            generation: 12,
            participantResolved: true,
            trackSubscribed: true,
            at: started
        )
        XCTAssertEqual(
            guardState.handleRemotePcm(sessionId: "session-a", generation: 11, at: started),
            .rejected
        )
        XCTAssertFalse(guardState.snapshot.remotePcmObserved)
        XCTAssertEqual(
            guardState.handleRemotePcm(sessionId: "session-b", generation: 12, at: started),
            .observed
        )
        XCTAssertTrue(guardState.snapshot.remotePcmObserved)
    }

    func testValidatedRemoteStartRequestsAppleParticipantAndDidActivateIsRecorded() {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { sessionId in
                sessionId == "session-a"
                    ? TrustedRemoteSpeaker(sessionId: sessionId, displayName: "Staff A")
                    : nil
            },
            setRemoteParticipant: { applied.append($0) },
            clock: clock,
            onUpdate: { _ in }
        )

        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1)))
        XCTAssertEqual(applied.compactMap { $0 }, [TrustedRemoteSpeaker(sessionId: "session-a", displayName: "Staff A")])
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "ACTIVATION_REQUESTED")

        clock.advance(milliseconds: 24)
        coordinator.audioSessionDidActivate()
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "ACTIVE")
        XCTAssertEqual(coordinator.currentSnapshot().activationMilliseconds, 24)
    }

    func testStaleRuntimeReplacementPreservesAppleRemoteParticipantWithoutNilGap() {
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { sessionId in
                TrustedRemoteSpeaker(sessionId: sessionId, displayName: "Staff A")
            },
            setRemoteParticipant: { applied.append($0) },
            onUpdate: { _ in }
        )
        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1)))
        coordinator.resetPreservingSystemRemoteParticipant()

        XCTAssertEqual(applied.count, 1)
        XCTAssertNotNil(applied.first ?? nil)
        XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
    }

    func testEndDoesNotClearParticipantUntilBoundedDrainCompletes() async {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let cleared = expectation(description: "Remote participant cleared after drain")
        let coordinator = coordinator(clock: clock, applied: {
            applied.append($0)
            if $0 == nil { cleared.fulfill() }
        })
        let controller = RxAudioController(
            channelId: "stage",
            cuePlayer: ImmediateCue(),
            clock: clock,
            onValidatedStart: { coordinator.handleValidatedStart($0, generation: $1) },
            onAudioActivity: { coordinator.handleRemoteAudioActivity(sessionId: $0, active: $1) },
            onDrainCompleted: {
                coordinator.completeDrain(generation: $0, sessionId: $1, leaseId: $2, reason: $3)
            },
            onUpdate: { _ in }
        )

        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: true)
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        XCTAssertNotNil(applied.last ?? nil, "END must not immediately clear the Apple remote participant")

        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: false)
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
        guard let lastApplied = applied.last else { return XCTFail("Expected a remote participant clear") }
        XCTAssertNil(lastApplied)
        XCTAssertNotNil(coordinator.currentSnapshot().remoteParticipantClearedAt)
    }

    func testSpeakerPreemptionHasNoNilGapAndStaleDrainCannotClearNewSpeaker() {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = coordinator(clock: clock, applied: { applied.append($0) })

        coordinator.handleValidatedStart(event(type: "start", sequence: 1))
        coordinator.handleValidatedStart(event(type: "start", session: "session-b", lease: "lease-b", sequence: 1))
        coordinator.completeDrain(sessionId: "session-a", leaseId: "lease-a")

        XCTAssertEqual(applied.count, 2)
        XCTAssertTrue(applied.allSatisfy { $0 != nil })
        XCTAssertEqual(coordinator.currentSnapshot().remoteSpeakerSessionId, "session-b")
    }

    func testLateOldGenerationDrainCannotClearNewSpeaker() {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = coordinator(clock: clock, applied: { applied.append($0) })

        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1), generation: 10))
        XCTAssertTrue(coordinator.handleValidatedStart(
            event(type: "start", session: "session-b", lease: "lease-b", sequence: 1), generation: 11
        ))
        XCTAssertFalse(coordinator.completeDrain(
            generation: 10, sessionId: "session-a", leaseId: "lease-a", reason: "late_old_drain"
        ))
        XCTAssertEqual(coordinator.currentSnapshot().remoteSpeakerSessionId, "session-b")
        XCTAssertEqual(coordinator.currentSnapshot().remoteGeneration, 11)
        XCTAssertTrue(applied.allSatisfy { $0 != nil })
    }

    func testTenReceiveCyclesClearRemoteAndRearmTransmitEligibility() {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = coordinator(clock: clock, applied: { applied.append($0) })

        for generation in 1...10 {
            XCTAssertTrue(coordinator.handleValidatedStart(
                event(type: "start", sequence: Int64(generation * 2 - 1)), generation: generation
            ))
            coordinator.audioSessionDidActivate()
            XCTAssertNotNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
            XCTAssertTrue(coordinator.completeDrain(
                generation: generation,
                sessionId: "session-a",
                leaseId: "lease-a",
                reason: "silence"
            ))
            let snapshot = coordinator.currentSnapshot()
            XCTAssertNil(snapshot.remoteSpeakerSessionId)
            XCTAssertEqual(snapshot.remoteParticipantState, "INACTIVE")
            XCTAssertNotNil(snapshot.remoteClearRequestedAt)
            XCTAssertNotNil(snapshot.remoteParticipantClearedAt)
        }
        XCTAssertEqual(applied.filter { $0 == nil }.count, 10)
    }

    func testLateActiveSpeakerAfterDrainCannotRecreateRemoteParticipant() {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = coordinator(clock: clock, applied: { applied.append($0) })

        XCTAssertTrue(coordinator.handleValidatedStart(
            event(type: "start", sequence: 1), generation: 7
        ))
        XCTAssertTrue(coordinator.completeDrain(
            generation: 7, sessionId: "session-a", leaseId: "lease-a", reason: "silence"
        ))
        let appliedCountAfterDrain = applied.count
        coordinator.handleRemoteAudioActivity(sessionId: "session-a", active: true)

        XCTAssertEqual(applied.count, appliedCountAfterDrain)
        XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "INACTIVE")
        XCTAssertEqual(coordinator.currentSnapshot().ghostActivityIgnored, 1)
    }

    func testAppleParticipantCompletionBindsActivationToCurrentGeneration() {
        let clock = AdvancingClock()
        var requests: [(Int, TrustedRemoteSpeaker?, RemoteParticipantRequestContext)] = []
        var nextRequestId = 0
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { TrustedRemoteSpeaker(sessionId: $0, displayName: "Staff A") },
            setRemoteParticipant: { _ in },
            setRemoteParticipantRequest: { speaker, context in
                nextRequestId += 1
                requests.append((nextRequestId, speaker, context))
                return nextRequestId
            },
            clock: clock,
            onUpdate: { _ in }
        )

        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1), generation: 41))
        XCTAssertFalse(coordinator.audioSessionDidActivate(), "Apple activation must wait for setActive completion")
        let request = requests[0]
        XCTAssertTrue(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
            requestId: request.0, context: request.2, errorCode: nil
        )))
        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.remoteParticipantState, "ACTIVE")
        XCTAssertEqual(snapshot.appleAudioActivationGeneration, 41)
        XCTAssertEqual(snapshot.remoteParticipantSetGeneration, 41)
        coordinator.handleRemotePcm()
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "PLAYING")
        XCTAssertEqual(coordinator.currentSnapshot().rxFirstPcmGeneration, 41)
    }

    func testMediaFlushIsRequestedOnlyAfterAppleConfirmsRemoteClear() {
        var requests: [(Int, TrustedRemoteSpeaker?, RemoteParticipantRequestContext)] = []
        var completedFlushes: [RemoteParticipantRequestContext] = []
        var nextRequestId = 0
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { TrustedRemoteSpeaker(sessionId: $0, displayName: "Staff A") },
            setRemoteParticipant: { _ in },
            setRemoteParticipantRequest: { speaker, context in
                nextRequestId += 1
                requests.append((nextRequestId, speaker, context))
                return nextRequestId
            },
            onClearCompleted: { completedFlushes.append($0) },
            onUpdate: { _ in }
        )

        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1), generation: 44))
        let set = requests.removeFirst()
        XCTAssertFalse(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
            requestId: set.0, context: set.2, errorCode: nil
        )))
        XCTAssertTrue(coordinator.completeDrain(
            generation: 44, sessionId: "session-a", leaseId: "lease-a", reason: "silence"
        ))
        XCTAssertTrue(completedFlushes.isEmpty, "LiveKit media must remain subscribed during Apple clear")

        let clear = requests.removeFirst()
        XCTAssertTrue(clear.2.clearing)
        XCTAssertFalse(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
            requestId: clear.0, context: clear.2, errorCode: nil
        )))
        XCTAssertEqual(completedFlushes, [clear.2])
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "INACTIVE")
    }

    func testAppleParticipantFailureNeverArmsPlaybackAndIsDiagnosed() {
        var request: (Int, RemoteParticipantRequestContext)?
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { TrustedRemoteSpeaker(sessionId: $0, displayName: "Staff A") },
            setRemoteParticipant: { _ in },
            setRemoteParticipantRequest: { _, context in request = (9, context); return 9 },
            onUpdate: { _ in }
        )
        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1), generation: 9))
        XCTAssertFalse(coordinator.audioSessionDidActivate())
        guard let request else { return XCTFail("Expected participant request") }
        XCTAssertFalse(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
            requestId: request.0, context: request.1, errorCode: "participant_rejected"
        )))
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "FAILED")
        XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantSetErrorCode, "participant_rejected")
        XCTAssertEqual(coordinator.currentSnapshot().appleAudioActivationGeneration, 0)
        XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
    }

    func testLateParticipantCompletionCannotActivateOrClearNewGeneration() {
        var requests: [(Int, RemoteParticipantRequestContext)] = []
        var nextRequestId = 0
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { sessionId in TrustedRemoteSpeaker(sessionId: sessionId, displayName: sessionId) },
            setRemoteParticipant: { _ in },
            setRemoteParticipantRequest: { _, context in
                nextRequestId += 1
                requests.append((nextRequestId, context))
                return nextRequestId
            },
            onUpdate: { _ in }
        )
        XCTAssertTrue(coordinator.handleValidatedStart(event(type: "start", sequence: 1), generation: 1))
        XCTAssertTrue(coordinator.handleValidatedStart(
            event(type: "start", session: "session-b", lease: "lease-b", sequence: 1), generation: 2
        ))
        XCTAssertFalse(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
            requestId: requests[0].0, context: requests[0].1, errorCode: nil
        )))
        XCTAssertEqual(coordinator.currentSnapshot().remoteSpeakerSessionId, "session-b")
        XCTAssertEqual(coordinator.currentSnapshot().rxLateCompletionIgnored, 1)
    }

    func testTwentyAsyncReceiveCyclesCompleteClearAndRearm() {
        var pending: [(Int, RemoteParticipantRequestContext)] = []
        var nextRequestId = 0
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { TrustedRemoteSpeaker(sessionId: $0, displayName: "Staff A") },
            setRemoteParticipant: { _ in },
            setRemoteParticipantRequest: { _, context in
                nextRequestId += 1
                pending.append((nextRequestId, context))
                return nextRequestId
            },
            onUpdate: { _ in }
        )
        for generation in 1...20 {
            XCTAssertTrue(coordinator.handleValidatedStart(
                event(type: "start", sequence: Int64(generation * 2 - 1)), generation: generation
            ))
            let set = pending.removeFirst()
            XCTAssertFalse(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
                requestId: set.0, context: set.1, errorCode: nil
            )))
            XCTAssertTrue(coordinator.audioSessionDidActivate())
            XCTAssertTrue(coordinator.completeDrain(
                generation: generation, sessionId: "session-a", leaseId: "lease-a", reason: "silence"
            ))
            let clear = pending.removeFirst()
            XCTAssertFalse(coordinator.handleParticipantSetResult(RemoteParticipantSetResult(
                requestId: clear.0, context: clear.1, errorCode: nil
            )))
            XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
            XCTAssertEqual(coordinator.currentSnapshot().remoteParticipantState, "INACTIVE")
        }
    }

    func testCompletedGenerationCannotDiscardNewerRemoteAudioSubscription() {
        var gate = RemoteAudioSubscriptionGenerationGate()
        gate.activate(sessionId: "session-a", generation: 1)
        XCTAssertTrue(gate.acceptsDiscard(sessionId: "session-a", generation: 1))
        gate.activate(sessionId: "session-a", generation: 2)
        XCTAssertFalse(gate.completeDiscard(sessionId: "session-a", generation: 1))
        XCTAssertTrue(gate.acceptsDiscard(sessionId: "session-a", generation: 2))
        XCTAssertTrue(gate.completeDiscard(sessionId: "session-a", generation: 2))
        XCTAssertFalse(gate.acceptsDiscard(sessionId: "session-a", generation: 2))
    }

    func testActiveSpeakerWithoutValidatedStartIsIgnored() {
        let clock = AdvancingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = coordinator(clock: clock, applied: { applied.append($0) })

        coordinator.handleRemoteAudioActivity(sessionId: "session-a", active: true)

        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
        XCTAssertEqual(coordinator.currentSnapshot().ghostActivityIgnored, 1)
    }

    func testAudioActivityCompletesDelayedTrustedResolutionWithoutNilGap() {
        let clock = AdvancingClock()
        var speakerBAvailable = false
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = RemoteReceiveActivationCoordinator(
            resolveSpeaker: { sessionId in
                if sessionId == "session-a" {
                    return TrustedRemoteSpeaker(sessionId: sessionId, displayName: "Staff A")
                }
                if sessionId == "session-b", speakerBAvailable {
                    return TrustedRemoteSpeaker(sessionId: sessionId, displayName: "Staff B")
                }
                return nil
            },
            setRemoteParticipant: { applied.append($0) },
            clock: clock,
            onUpdate: { _ in }
        )

        coordinator.handleValidatedStart(event(type: "start", sequence: 1))
        XCTAssertFalse(coordinator.handleValidatedStart(
            event(type: "start", session: "session-b", lease: "lease-b", sequence: 1), generation: 12
        ))
        speakerBAvailable = true
        coordinator.handleRemoteAudioActivity(sessionId: "session-b", active: true)

        XCTAssertTrue(applied.allSatisfy { $0 != nil })
        XCTAssertEqual(coordinator.currentSnapshot().remoteSpeakerSessionId, "session-b")
        XCTAssertEqual(coordinator.currentSnapshot().remoteGeneration, 12)
        coordinator.completeDrain(sessionId: "session-b", leaseId: "lease-b")
        XCTAssertNil(coordinator.currentSnapshot().remoteSpeakerSessionId)
    }

    func testIOSCuePolicyDoesNotUseAVAudioPlayerToOwnPushToTalkSession() {
        XCTAssertFalse(CuePolicy.alpha.koeonCueEnabled)
        XCTAssertTrue(CuePolicy.alpha.systemCuePreferred)
        XCTAssertTrue(CuePolicy.receiveAndStatus.koeonCueEnabled)
    }

    func testEndBeforeAppleActivationWaitsForFirstPcmBeforeDrain() {
        let clock = SuspendingClock()
        var applied: [TrustedRemoteSpeaker?] = []
        let coordinator = coordinator(clock: clock, applied: { applied.append($0) })
        let controller = RxAudioController(
            channelId: "stage",
            cuePlayer: ImmediateCue(),
            clock: clock,
            onValidatedStart: { coordinator.handleValidatedStart($0, generation: $1) },
            onDrainCompleted: {
                coordinator.completeDrain(generation: $0, sessionId: $1, leaseId: $2, reason: $3)
            },
            onUpdate: { _ in }
        )
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        XCTAssertEqual(controller.currentSnapshot().state, .endPending)
        XCTAssertTrue(controller.currentSnapshot().endBeforeAppleActivate)
        XCTAssertNotNil(applied.last ?? nil)

        controller.audioSessionDidActivate()
        XCTAssertEqual(controller.currentSnapshot().state, .endPending)
        controller.handleRemotePcm(at: clock.now)
        XCTAssertEqual(controller.currentSnapshot().state, .draining)
        XCTAssertTrue(controller.currentSnapshot().shortBurstProtectionUsed)
        XCTAssertNotNil(applied.last ?? nil)
    }

    func testEndAfterActivationBeforeFirstPcmUsesGrace() {
        let clock = SuspendingClock()
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue(), clock: clock) { _ in }
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.audioSessionDidActivate()
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")

        XCTAssertEqual(controller.currentSnapshot().state, .endPending)
        XCTAssertFalse(controller.currentSnapshot().endBeforeAppleActivate)
        XCTAssertTrue(controller.currentSnapshot().endBeforeFirstPcm)
        XCTAssertEqual(rxFirstAudioGraceAfterActivateMilliseconds, 500)
        XCTAssertEqual(rxStartupAbsoluteMaxMilliseconds, 1_500)
    }

    func testFloorConvergenceUsesSameEndPendingProtection() {
        let clock = SuspendingClock()
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue(), clock: clock) { _ in }
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.reconcileFloor(FloorResponse(
            outcome: .available, owner: nil, leaseId: nil, acquiredAt: nil,
            leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false
        ))
        XCTAssertEqual(controller.currentSnapshot().state, .endPending)
        XCTAssertNotNil(controller.currentSnapshot().rxFloorEndObservedAt)
    }

    func testEndCueCompletesBeforeAppleRemoteParticipantClear() async {
        let clock = AdvancingClock()
        let cleared = expectation(description: "Participant clear callback")
        let order = EventOrderRecorder { value in
            if value == "clear" { cleared.fulfill() }
        }
        let controller = RxAudioController(
            channelId: "stage",
            cuePlayer: RecordingCue(order: order),
            clock: clock,
            onDrainCompleted: { _, _, _, _ in order.append("clear"); return true },
            onUpdate: { _ in }
        )
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.audioSessionDidActivate()
        controller.handleRemotePcm(at: clock.now)
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: false)
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        await fulfillment(of: [cleared], timeout: 1)
        guard let cue = order.values.firstIndex(of: "end-cue"),
              let clear = order.values.firstIndex(of: "clear") else {
            return XCTFail("Expected END cue and participant clear")
        }
        XCTAssertLessThan(cue, clear)
    }

    func testRequestGateSerializesFiftyPreBeginReleases() {
        var gate = PttRequestGate()
        for _ in 0..<50 {
            XCTAssertEqual(gate.pressDown(), [.requestBegin])
            XCTAssertEqual(gate.pressUp(), [])
            XCTAssertTrue(gate.releaseRequestedBeforeBegin)
            XCTAssertEqual(gate.didBegin(), [.stopSystemTransmission])
            XCTAssertEqual(gate.didEnd(), [])
            XCTAssertEqual(gate.state, .rearming)
            _ = gate.finishRearming()
            XCTAssertEqual(gate.state, .idle)
        }
    }

    func testRequestGateKeepsAtMostOneHeldPressDuringEndAndRearm() {
        var gate = PttRequestGate()
        XCTAssertEqual(gate.pressDown(), [.requestBegin])
        XCTAssertEqual(gate.didBegin(), [.beginFloor])
        XCTAssertEqual(gate.pressUp(), [.stopSystemTransmission])
        XCTAssertEqual(gate.pressDown(), [.pending])
        XCTAssertTrue(gate.pendingPressHeld)
        XCTAssertEqual(gate.didEnd(), [.finishFloor])
        XCTAssertEqual(gate.pressDown(), [.pending])
        XCTAssertEqual(gate.finishRearming(), [.requestBegin])
        XCTAssertEqual(gate.state, .beginRequested)
        XCTAssertFalse(gate.pendingPressHeld)
    }

    func testPendingRapidPressCancelsOnFingerUp() {
        var gate = PttRequestGate()
        _ = gate.pressDown()
        _ = gate.didBegin()
        _ = gate.pressUp()
        XCTAssertEqual(gate.pressDown(), [.pending])
        XCTAssertEqual(gate.pressUp(), [])
        XCTAssertFalse(gate.pendingPressHeld)
        _ = gate.didEnd()
        XCTAssertEqual(gate.finishRearming(), [])
        XCTAssertEqual(gate.state, .idle)
    }

    func testTwentyRapidTransmitCyclesNeverEnterErrorOrStick() {
        var gate = PttRequestGate()
        for _ in 0..<20 {
            XCTAssertEqual(gate.pressDown(), [.requestBegin])
            XCTAssertEqual(gate.didBegin(), [.beginFloor])
            XCTAssertEqual(gate.pressUp(), [.stopSystemTransmission])
            XCTAssertEqual(gate.pressDown(), [.pending])
            XCTAssertEqual(gate.didEnd(), [.finishFloor])
            XCTAssertEqual(gate.finishRearming(), [.requestBegin])
            XCTAssertEqual(gate.didBegin(), [.beginFloor])
            XCTAssertEqual(gate.pressUp(), [.stopSystemTransmission])
            XCTAssertEqual(gate.didEnd(), [.finishFloor])
            XCTAssertEqual(gate.finishRearming(), [])
            XCTAssertEqual(gate.state, .idle)
        }
    }

    func testRecoverableGateFailureReturnsBusyAndDoesNotPoisonNextPress() {
        var gate = PttRequestGate()
        _ = gate.pressDown()
        XCTAssertEqual(gate.didFail(recoverable: true), [.busy])
        XCTAssertEqual(gate.state, .rearming)
        _ = gate.finishRearming()
        XCTAssertEqual(gate.pressDown(), [.requestBegin])
    }

    func testIncomingPushRuntimeRecoveryDecisionIsBoundedAndConnectionAware() {
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: true,
                connectionState: .connected,
                appLifecycleState: "active"
            ),
            .useWarmRuntime
        )
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: true,
                connectionState: .reconnecting,
                appLifecycleState: "active"
            ),
            .awaitReconnectThenResume
        )
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: true,
                connectionState: .disconnected,
                appLifecycleState: "active"
            ),
            .resumeImmediately
        )
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: false,
                connectionState: .disconnected,
                appLifecycleState: "active"
            ),
            .resumeImmediately
        )
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: true,
                connectionState: .connected,
                appLifecycleState: "background"
            ),
            .resumeImmediately
        )
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: true,
                connectionState: .connected,
                appLifecycleState: "inactive"
            ),
            .resumeImmediately
        )
        XCTAssertEqual(
            incomingPushRuntimeAction(
                hasJoinedRuntime: true,
                connectionState: .reconnecting,
                appLifecycleState: "background"
            ),
            .resumeImmediately
        )
    }

    func testAppleActivationDurationRequiresSameTransmitAttempt() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(0.318)
        XCTAssertEqual(pairedDurationMilliseconds(
            start: start,
            end: end,
            startGeneration: 44,
            endGeneration: 44
        ), 318)
        XCTAssertNil(pairedDurationMilliseconds(
            start: start,
            end: end,
            startGeneration: 43,
            endGeneration: 44
        ))
        XCTAssertNil(pairedDurationMilliseconds(
            start: start,
            end: end,
            startGeneration: nil,
            endGeneration: 44
        ))
    }

    func testReconnectAttemptDurationUsesOnlyItsOwnStartAndCompletion() {
        let start = Date(timeIntervalSince1970: 2_000)
        var attempt = ReconnectAttemptDiagnostic(
            id: 7,
            startedAt: start,
            reason: "livekit_reconnecting",
            completedAt: nil,
            result: nil
        )
        XCTAssertNil(attempt.durationMilliseconds)

        attempt.completedAt = start.addingTimeInterval(0.5)
        attempt.result = "connected"
        XCTAssertEqual(attempt.durationMilliseconds, 500)
        XCTAssertEqual(attempt.result, "connected")
    }

    func testLiveKitEndpointDiagnosticExposesHostWithoutCredentials() {
        let selfHost = LiveKitRoomController.endpointDiagnostic("wss://livekit.example.invalid")
        XCTAssertEqual(selfHost.deployment, "SELF_HOST")
        XCTAssertEqual(selfHost.host, "livekit.example.invalid")

        let cloud = LiveKitRoomController.endpointDiagnostic("wss://example.livekit.cloud")
        XCTAssertEqual(cloud.deployment, "CLOUD")
        XCTAssertEqual(cloud.host, "example.livekit.cloud")

        let invalid = LiveKitRoomController.endpointDiagnostic("not a URL")
        XCTAssertEqual(invalid.deployment, "UNKNOWN")
        XCTAssertNil(invalid.host)
    }

    func testEnteringPttManagedModePreservesAlreadyActiveAppleAudio() {
        XCTAssertTrue(shouldKeepLiveKitEngineAvailableWhenEnteringPttManagedMode(
            appleAudioSessionAlreadyActive: true
        ))
        XCTAssertFalse(shouldKeepLiveKitEngineAvailableWhenEnteringPttManagedMode(
            appleAudioSessionAlreadyActive: false
        ))
    }

    func testAppleTransmitCollisionClassificationIsRecoverable() {
        let error = NSError(
            domain: PTChannelError.errorDomain,
            code: PTChannelError.Code.transmissionInProgress.rawValue
        )
        let failure = ApplePttErrorClassifier.classify(error, operation: .begin)
        XCTAssertTrue(failure.recoverable)
        XCTAssertFalse(failure.affectsAudioAvailability)
    }

    func testStatusCueRateLimiterAllowsOneCuePerTypePer500ms() {
        var limiter = PttStatusCueRateLimiter()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(limiter.accept("busy", at: now))
        XCTAssertFalse(limiter.accept("busy", at: now.addingTimeInterval(0.499)))
        XCTAssertTrue(limiter.accept("error", at: now.addingTimeInterval(0.1)))
        XCTAssertTrue(limiter.accept("busy", at: now.addingTimeInterval(0.5)))
    }

    func testStartupProtectionHasAbsoluteBound() async {
        let clock = AdvancingClock()
        let idle = expectation(description: "Startup protection reaches idle")
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue(), clock: clock) {
            if $0.state == .idle { idle.fulfill() }
        }
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        await fulfillment(of: [idle], timeout: 1)
        XCTAssertEqual(controller.currentSnapshot().state, .idle)
        XCTAssertTrue(controller.currentSnapshot().shortBurstProtectionUsed)
    }

    func testMatchingFloorLeaseDoesNotEndReceive() {
        let controller = RxAudioController(channelId: "stage", cuePlayer: ImmediateCue(), clock: SuspendingClock()) { _ in }
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.reconcileFloor(FloorResponse(
            outcome: .busy, owner: FloorOwner(id: "staff-a", name: "Staff A"), leaseId: "lease-a",
            acquiredAt: nil, leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false
        ))
        XCTAssertEqual(controller.currentSnapshot().state, .arming)
    }

    func testRemoteBusyWithRedactedLeaseKeepsActiveReceive() {
        let controller = activeRemoteController()
        controller.reconcileFloor(remoteBusyStatus(ownerUserId: "staff-a"))

        let snapshot = controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .active)
        XCTAssertNil(snapshot.rxEndReason)
        XCTAssertEqual(snapshot.lastFloorStatusOutcome, FloorOutcome.busy.rawValue)
        XCTAssertEqual(snapshot.lastFloorStatusOwnerUserId, "staff-a")
        XCTAssertEqual(snapshot.lastFloorStatusIsOwner, false)
        XCTAssertEqual(snapshot.lastFloorStatusLeaseVisible, false)
        XCTAssertEqual(snapshot.lastFloorReconcileDecision, "KEEP_REMOTE_OWNER_MATCH")
        XCTAssertNil(snapshot.rxDrainStartedAt)
    }

    func testTenRedactedBusyPollsKeepSameRemoteReceiveActive() {
        let controller = activeRemoteController()
        for _ in 0..<10 {
            controller.reconcileFloor(remoteBusyStatus(ownerUserId: "staff-a"))
            XCTAssertEqual(controller.currentSnapshot().state, .active)
            XCTAssertNotEqual(controller.currentSnapshot().rxEndReason, "floor_lease_changed")
        }
    }

    func testRemoteBusyOwnerChangeEndsCurrentReceive() {
        let controller = activeRemoteController()
        controller.reconcileFloor(remoteBusyStatus(ownerUserId: "staff-b"))

        XCTAssertEqual(controller.currentSnapshot().state, .draining)
        XCTAssertEqual(controller.currentSnapshot().rxEndReason, "floor_owner_changed")
        XCTAssertEqual(controller.currentSnapshot().lastFloorReconcileDecision, "END_FLOOR_OWNER_CHANGED")
    }

    func testFloorAvailableRemainsReceiveEndFallback() {
        let controller = activeRemoteController()
        controller.reconcileFloor(FloorResponse(
            outcome: .available, owner: nil, leaseId: nil, acquiredAt: nil,
            leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false
        ))

        XCTAssertEqual(controller.currentSnapshot().state, .draining)
        XCTAssertEqual(controller.currentSnapshot().rxEndReason, "floor_available")
        XCTAssertEqual(controller.currentSnapshot().lastFloorReconcileDecision, "END_FLOOR_AVAILABLE")
    }

    func testExplicitEndStillDrainsAfterRemoteBusyPoll() {
        let controller = activeRemoteController()
        controller.reconcileFloor(remoteBusyStatus(ownerUserId: "staff-a"))
        XCTAssertEqual(controller.currentSnapshot().state, .active)

        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        XCTAssertEqual(controller.currentSnapshot().state, .draining)
        XCTAssertEqual(controller.currentSnapshot().rxEndReason, "control_end")
    }

    func testHeldRemotePttSurvivesFivePollsAndEndsOnlyOnControlEnd() {
        let controller = activeRemoteController()
        for _ in 0..<5 {
            controller.reconcileFloor(remoteBusyStatus(ownerUserId: "staff-a"))
        }
        XCTAssertEqual(controller.currentSnapshot().state, .active)
        XCTAssertNil(controller.currentSnapshot().rxEndSignalAt)

        controller.handleControl(event(type: "end", sequence: 2), senderSessionId: "session-a")
        XCTAssertEqual(controller.currentSnapshot().state, .draining)
    }

    func testTwentyReceiveGenerationsNeverEndOnRedactedRemoteLease() {
        for generation in 1...20 {
            let controller = RxAudioController(
                channelId: "stage", cuePlayer: ImmediateCue(), clock: SuspendingClock(), onUpdate: { _ in }
            )
            controller.handleControl(
                event(type: "start", sequence: Int64(generation * 2 - 1)), senderSessionId: "session-a"
            )
            controller.audioSessionDidActivate()
            controller.handleRemotePcm(at: Date())
            controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: true)
            controller.reconcileFloor(remoteBusyStatus(ownerUserId: "staff-a"))
            XCTAssertEqual(controller.currentSnapshot().state, .active)
            XCTAssertNil(controller.currentSnapshot().rxEndReason)
            controller.handleControl(
                event(type: "end", sequence: Int64(generation * 2)), senderSessionId: "session-a"
            )
            XCTAssertEqual(controller.currentSnapshot().state, .draining)
            controller.reset()
            XCTAssertEqual(controller.currentSnapshot().state, .idle)
        }
    }

    func testActiveCallClassificationIsRecoverableBusyWithoutPoisoningAudioAvailability() {
        let error = NSError(
            domain: PTChannelError.errorDomain,
            code: PTChannelError.Code.callActive.rawValue
        )
        let failure = ApplePttErrorClassifier.classify(error, operation: .begin)
        XCTAssertTrue(failure.recoverable)
        XCTAssertFalse(failure.affectsAudioAvailability)
    }

    func testFieldCueProfileIsLoudWithoutClippingAndPostCallWindowIsBounded() {
        XCTAssertEqual(PttCuePlayer.txStartFrequency, 1_350)
        XCTAssertEqual(PttCuePlayer.txEndFrequency, 850)
        XCTAssertEqual(PttCuePlayer.rxStartFrequency, 1_100)
        XCTAssertEqual(PttCuePlayer.rxEndFrequency, 700)
        XCTAssertGreaterThanOrEqual(PttCuePlayer.txRxAmplitude, 0.35)
        XCTAssertLessThan(PttCuePlayer.errorAmplitude, 0.95)
        XCTAssertEqual(postCallStableMilliseconds, 500)
    }

    private func coordinator(
        clock: any PTTClock,
        applied: @escaping (TrustedRemoteSpeaker?) -> Void
    ) -> RemoteReceiveActivationCoordinator {
        RemoteReceiveActivationCoordinator(
            resolveSpeaker: { sessionId in
                switch sessionId {
                case "session-a": TrustedRemoteSpeaker(sessionId: sessionId, displayName: "Staff A")
                case "session-b": TrustedRemoteSpeaker(sessionId: sessionId, displayName: "Staff B")
                default: nil
                }
            },
            setRemoteParticipant: applied,
            clock: clock,
            onUpdate: { _ in }
        )
    }

    private func activeRemoteController() -> RxAudioController {
        let controller = RxAudioController(
            channelId: "stage", cuePlayer: ImmediateCue(), clock: SuspendingClock(), onUpdate: { _ in }
        )
        controller.handleControl(event(type: "start", sequence: 1), senderSessionId: "session-a")
        controller.audioSessionDidActivate()
        controller.handleRemotePcm(at: Date())
        controller.handleRemoteAudioActivity(senderSessionId: "session-a", active: true)
        XCTAssertEqual(controller.currentSnapshot().state, .active)
        return controller
    }

    private func remoteBusyStatus(ownerUserId: String) -> FloorResponse {
        FloorResponse(
            outcome: .busy,
            owner: FloorOwner(id: ownerUserId, name: ownerUserId),
            leaseId: nil,
            acquiredAt: nil,
            leaseExpiresAt: nil,
            maxTxExpiresAt: nil,
            lastRenewedAt: nil,
            isOwner: false
        )
    }

    private func event(
        type: String,
        session: String = "session-a",
        lease: String = "lease-a",
        sequence: Int64
    ) -> PttControlEvent {
        PttControlEvent(
            version: 1,
            type: type,
            channelId: "stage",
            speakerUserId: session == "session-a" ? "staff-a" : "staff-b",
            sessionId: session,
            leaseId: lease,
            sequence: sequence,
            sentAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }
}

private final class RxRecorder: @unchecked Sendable {
    var value = RxSnapshot()
}

private actor ImmediateCue: PttCuePlaying {
    func playStart() async throws {}
    func playEnd() async throws {}
}

private actor RecordingCue: PttCuePlaying {
    let order: EventOrderRecorder
    init(order: EventOrderRecorder) { self.order = order }
    func playStart() async throws { order.append("start-cue") }
    func playEnd() async throws { order.append("end-cue") }
}

private final class EventOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let onAppend: (String) -> Void

    init(onAppend: @escaping (String) -> Void = { _ in }) {
        self.onAppend = onAppend
    }

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) {
        lock.withLock { storage.append(value) }
        onAppend(value)
    }
}

private final class AdvancingClock: PTTClock, @unchecked Sendable {
    private var current = Date(timeIntervalSince1970: 1_000)

    var now: Date { current }

    func sleep(milliseconds: Int) async throws {
        current = current.addingTimeInterval(Double(milliseconds) / 1_000)
        await Task.yield()
    }

    func advance(milliseconds: Int) {
        current = current.addingTimeInterval(Double(milliseconds) / 1_000)
    }
}

private final class SuspendingClock: PTTClock, @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
    func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}
