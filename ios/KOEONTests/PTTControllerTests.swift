import AVFoundation
import XCTest
@testable import KOEON

@MainActor
final class PttInitializationGateTests: XCTestCase {
    func testConcurrentCallersWaitForTheSameCompleteRestoration() async throws {
        let gate = PttInitializationGate()
        let configurationStarted = expectation(description: "Manager created, restoration suspended")
        let secondEntered = expectation(description: "Second caller entered")
        var releaseConfiguration: CheckedContinuation<Void, Never>?
        var starts = 0
        var configured = false
        var secondReturned = false
        let first = Task {
            try await gate.run {
                starts += 1
                await withCheckedContinuation { continuation in
                    releaseConfiguration = continuation
                    configurationStarted.fulfill()
                }
                configured = true
            }
        }
        await fulfillment(of: [configurationStarted], timeout: 1)
        let second = Task {
            secondEntered.fulfill()
            try await gate.run { starts += 1 }
            secondReturned = true
            XCTAssertTrue(configured)
        }
        await fulfillment(of: [secondEntered], timeout: 1)
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(secondReturned)
        releaseConfiguration?.resume()
        try await first.value
        try await second.value
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(secondReturned)
        try await gate.run { XCTFail("Successful initialization must not repeat") }
    }

    func testFailedRestorationCanRetryInsteadOfTreatingCreatedManagerAsReady() async throws {
        enum Failure: Error { case configuration }
        let gate = PttInitializationGate()
        var attempts = 0
        do {
            try await gate.run { attempts += 1; throw Failure.configuration }
            XCTFail("Configuration failure must reach the caller")
        } catch Failure.configuration { }
        try await gate.run { attempts += 1 }
        try await gate.run { XCTFail("Completed retry must be shared") }
        XCTAssertEqual(attempts, 2)
    }

    func testCancellationOfOneCallerDoesNotCancelSharedInitialization() async throws {
        let gate = PttInitializationGate()
        let started = expectation(description: "Shared operation started")
        var release: CheckedContinuation<Void, Never>?
        var cancelledInsideOperation = false
        let caller = Task {
            try await gate.run {
                await withCheckedContinuation { release = $0; started.fulfill() }
                cancelledInsideOperation = Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 1)
        caller.cancel()
        release?.resume()
        try await caller.value
        try await gate.run { XCTFail("Cancelled waiter must not restart the shared operation") }
        XCTAssertFalse(cancelledInsideOperation)
    }
}

@MainActor
final class PTTControllerTests: XCTestCase {
    func testC1C2C8SpeakerBluetoothSpeakerPolicySurvivesFiftySwitches() {
        for _ in 0 ..< 50 {
            XCTAssertTrue(AudioSessionController.speakerOutputPreferred(for: .speaker))
            XCTAssertFalse(AudioSessionController.speakerOutputPreferred(for: .bluetooth))
            XCTAssertTrue(AudioSessionController.speakerOutputPreferred(for: .speaker))
        }
    }

    func testNormalAppleActivationDoesNotResetActiveRequestGate() {
        XCTAssertFalse(shouldFinishPostCallRecovery(onAppleActivation: .ready))
        XCTAssertTrue(shouldFinishPostCallRecovery(onAppleActivation: .recovering))
    }

    func testExpectedAppleEndDeactivationDoesNotBecomeError() {
        XCTAssertFalse(shouldSafetyStopForAppleDeactivation(gateState: .endRequested, pttState: .transmitting))
        XCTAssertFalse(shouldSafetyStopForAppleDeactivation(gateState: .rearming, pttState: .transmitting))
        XCTAssertTrue(shouldSafetyStopForAppleDeactivation(gateState: .transmitting, pttState: .transmitting))
        XCTAssertFalse(shouldSafetyStopForAppleDeactivation(
            gateState: .beginRequested,
            pttState: .requestingFloor,
            nextBeginIsRearmingPreviousRelease: true
        ))
    }

    func testLateStopFailureCannotPoisonNextTransmitGeneration() {
        let end = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(shouldIgnoreLateStopFailure(
            operation: .stop,
            gateState: .beginRequested,
            previousDidEndAt: end,
            nextPttDownAt: end.addingTimeInterval(0.3)
        ))
        XCTAssertFalse(shouldIgnoreLateStopFailure(
            operation: .begin,
            gateState: .beginRequested,
            previousDidEndAt: end,
            nextPttDownAt: end.addingTimeInterval(0.3)
        ))
    }
    func testAudioInterruptionStateRejectsStaleRecoveryAndNeverImpliesTXResume() {
        var machine = AudioInterruptionStateMachine()
        let started = Date(timeIntervalSince1970: 1)
        let first = machine.interrupt(reason: "call began", at: started)
        XCTAssertEqual(machine.interrupt(reason: "duplicate", at: started), first)
        XCTAssertEqual(machine.snapshot.interruptionReason, "call began")
        XCTAssertTrue(machine.beginRecovery(generation: first, at: Date(timeIntervalSince1970: 1.1)))

        let newer = machine.interrupt(reason: "new interruption", at: Date(timeIntervalSince1970: 1.2))
        XCTAssertGreaterThan(newer, first)
        XCTAssertFalse(machine.completeRecovery(generation: first, at: Date(timeIntervalSince1970: 1.3)))
        XCTAssertEqual(machine.snapshot.state, .interrupted)
    }

    func testAudioInterruptionRecoveryTimingAndFailureAreExplicit() {
        var machine = AudioInterruptionStateMachine()
        let generation = machine.interrupt(reason: "call", at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(machine.beginRecovery(generation: generation, at: Date(timeIntervalSince1970: 2.1)))
        XCTAssertTrue(machine.completeRecovery(generation: generation, at: Date(timeIntervalSince1970: 2.35)))
        XCTAssertEqual(machine.snapshot.state, .ready)
        XCTAssertEqual(machine.snapshot.recoveryMilliseconds, 250)

        let retryGeneration = machine.interrupt(reason: "voicemail", at: Date(timeIntervalSince1970: 3))
        XCTAssertTrue(machine.beginRecovery(generation: retryGeneration, at: Date(timeIntervalSince1970: 3.1)))
        XCTAssertTrue(machine.failRecovery(generation: retryGeneration, error: "route unavailable"))
        XCTAssertEqual(machine.snapshot.state, .recoveryFailed)
        XCTAssertEqual(machine.snapshot.lastRecoveryError, "route unavailable")
    }

    func testGrantPlaysStartCueBeforeEnablingMicrophoneAndReleaseOrdersEndCue() async throws {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let microphone = MicrophoneMock(events: events)
        let cue = CueMock(events: events)
        let recorder = SnapshotRecorder()
        let controller = PTTController(
            role: .staff,
            floor: floor,
            microphone: microphone,
            cuePlayer: cue,
            control: ControlMock(events: events),
            clock: ControlledClock(),
            onUpdate: { recorder.append($0) }
        )

        await controller.pttDown()
        let startedEvents = await events.values()
        let transmitting = await controller.currentSnapshot()
        XCTAssertEqual(Array(startedEvents.prefix(4)), ["acquire", "control:start", "cue:start", "mic:on"])
        XCTAssertEqual(transmitting.state, .transmitting)

        await controller.pttUp()
        let finishedEvents = await events.values()
        let idle = await controller.currentSnapshot()
        XCTAssertTrue(finishedEvents.contains("release"))
        XCTAssertLessThan(finishedEvents.firstIndex(of: "mic:off")!, finishedEvents.firstIndex(of: "control:end")!)
        XCTAssertLessThan(finishedEvents.firstIndex(of: "control:end")!, finishedEvents.firstIndex(of: "cue:end")!)
        XCTAssertEqual(idle.state, .idle)
    }

    func testBusyNeverPlaysCueOrEnablesMicrophone() async {
        let events = EventLog()
        let floor = FloorMock(events: events, acquireResult: .busy)
        let controller = makeController(floor: floor, events: events)

        await controller.pttDown()
        let busyEvents = await events.values()
        let busy = await controller.currentSnapshot()
        XCTAssertEqual(busyEvents, ["acquire"])
        XCTAssertEqual(busy.state, .busy)
        await controller.pttUp()
        let idle = await controller.currentSnapshot()
        XCTAssertEqual(idle.state, .idle)
    }

    func testAppPreArmDoesNotEnableMicrophoneUntilAppleActivation() async {
        let events = EventLog()
        let controller = makeController(floor: FloorMock(events: events), events: events)

        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        var values = await events.values()
        XCTAssertEqual(values, ["acquire", "control:start"])
        let prearmedSnapshot = await controller.currentSnapshot()
        XCTAssertEqual(prearmedSnapshot.state, .requestingFloor)

        await controller.activatePrearmedTransmission()
        values = await events.values()
        XCTAssertEqual(values, ["acquire", "control:start", "mic:on"])
        let transmittingSnapshot = await controller.currentSnapshot()
        XCTAssertEqual(transmittingSnapshot.state, .transmitting)
        XCTAssertGreaterThan(transmittingSnapshot.attemptGeneration, 0)
        XCTAssertNotNil(transmittingSnapshot.floorRequestAt)
        XCTAssertNotNil(transmittingSnapshot.floorGrantedAt)
        XCTAssertNotNil(transmittingSnapshot.localUiFeedbackAt)
        XCTAssertLessThanOrEqual(
            transmittingSnapshot.localUiFeedbackAt!.timeIntervalSince(transmittingSnapshot.pttDownAt!),
            0.1
        )
        XCTAssertNotNil(transmittingSnapshot.readyBarrierStartedAt)
        XCTAssertNotNil(transmittingSnapshot.readyBarrierCompletedAt)
        XCTAssertNotNil(transmittingSnapshot.talkingAt)
        await controller.pttUp(playEndCue: false)
        let releasedSnapshot = await controller.currentSnapshot()
        XCTAssertNotNil(releasedSnapshot.pttUpAt)
        XCTAssertNotNil(releasedSnapshot.microphoneMutedAt)
        XCTAssertNotNil(releasedSnapshot.controlEndPublishedAt)
        XCTAssertNotNil(releasedSnapshot.floorReleaseRequestedAt)
        XCTAssertNotNil(releasedSnapshot.floorReleaseCompletedAt)
    }

    func testFloorGrantMayStartAppleActivationWhileReadyBarrierStillBlocksMicrophone() async {
        let events = EventLog()
        let control = BlockingReadyControl(events: events)
        let controller = PTTController(
            role: .staff,
            floor: FloorMock(events: events, expectedSessions: ["receiver-a"]),
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events),
            control: control,
            clock: ControlledClock(),
            onUpdate: { _ in }
        )
        let floorGranted = EventLog()
        let prearm = Task {
            await controller.preArmForAppleActivation(onFloorGranted: {
                await floorGranted.append("apple:begin-requested")
            })
        }
        await waitUntil { control.isWaiting }
        let floorEvents = await floorGranted.values()
        let transmissionEvents = await events.values()
        XCTAssertEqual(floorEvents, ["apple:begin-requested"])
        XCTAssertFalse(transmissionEvents.contains("mic:on"))
        await controller.pttUp(playEndCue: false)
        _ = await prearm.value
    }

    func testAppleBeginAfterFloorGrantIsGenerationAndReleaseFenced() {
        XCTAssertTrue(shouldRequestAppleBeginAfterFloorGrant(
            attempt: 4, currentAttempt: 4, gateState: .beginRequested,
            releaseRequestedBeforeBegin: false, alreadyIssued: false
        ))
        XCTAssertFalse(shouldRequestAppleBeginAfterFloorGrant(
            attempt: 3, currentAttempt: 4, gateState: .beginRequested,
            releaseRequestedBeforeBegin: false, alreadyIssued: false
        ))
        XCTAssertFalse(shouldRequestAppleBeginAfterFloorGrant(
            attempt: 4, currentAttempt: 4, gateState: .beginRequested,
            releaseRequestedBeforeBegin: true, alreadyIssued: false
        ))
        XCTAssertFalse(shouldRequestAppleBeginAfterFloorGrant(
            attempt: 4, currentAttempt: 4, gateState: .beginRequested,
            releaseRequestedBeforeBegin: false, alreadyIssued: true
        ))
    }

    func testAppReleaseDuringPreArmNeverEnablesMicrophoneAndReleasesFloor() async {
        let events = EventLog()
        let controller = makeController(floor: FloorMock(events: events), events: events)
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)

        await controller.pttUp(playEndCue: false)
        await controller.activatePrearmedTransmission()
        let values = await events.values()
        XCTAssertFalse(values.contains("mic:on"))
        XCTAssertTrue(values.contains("control:end"))
        XCTAssertTrue(values.contains("release"))
        let idleSnapshot = await controller.currentSnapshot()
        XCTAssertEqual(idleSnapshot.state, .idle)
    }

    func testSystemTransmitPathBoundsReadyWaitTo250Milliseconds() async {
        let events = EventLog()
        let control = CapturingReadyControl(events: events)
        let controller = PTTController(
            role: .staff,
            floor: FloorMock(events: events),
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events),
            control: control,
            clock: ControlledClock(),
            onUpdate: { _ in }
        )

        await controller.pttDown(playReadyCue: false, maximumReadyWaitMilliseconds: 250)
        XCTAssertEqual(control.maximumWaitMilliseconds, 250)
        await controller.pttUp(playEndCue: false)
    }

    func testLeaseRenewsEveryIntervalWhileTransmitting() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let clock = ControlledClock(immediateSleeps: [1_000: 1])
        let controller = makeController(floor: floor, events: events, clock: clock)

        await controller.pttDown()
        await waitUntil { await events.values().contains("renew") }
        let renewedEvents = await events.values()
        let snapshot = await controller.currentSnapshot()
        XCTAssertTrue(renewedEvents.contains("renew"))
        XCTAssertEqual(snapshot.state, .transmitting)
        await controller.pttUp()
    }

    func testRenewFailureTurnsMicrophoneOffAndEntersError() async {
        let events = EventLog()
        let floor = FloorMock(events: events, failRenew: true)
        let controller = makeController(
            floor: floor,
            events: events,
            clock: ControlledClock(immediateSleeps: [1_000: 1])
        )

        await controller.pttDown()
        await waitUntil { await controller.currentSnapshot().state == .error }
        let values = await events.values()
        XCTAssertTrue(values.contains("renew"))
        XCTAssertTrue(values.contains("mic:off"))
        XCTAssertTrue(values.contains("release"))
        let failed = await controller.currentSnapshot()
        XCTAssertEqual(failed.state, .error)
        await Task.yield()
        let afterOldContinuationSettles = await controller.currentSnapshot()
        XCTAssertEqual(afterOldContinuationSettles.state, .error)
    }

    func testMaxContinuousTxStopsWithoutReacquiring() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = makeController(
            floor: floor,
            events: events,
            clock: ControlledClock(immediateSleeps: [60_000: 1])
        )

        await controller.pttDown()
        await waitUntil { await controller.currentSnapshot().state == .idle }
        let values = await events.values()
        let stopped = await controller.currentSnapshot()
        XCTAssertEqual(values.filter { $0 == "acquire" }.count, 1)
        XCTAssertTrue(values.contains("mic:off"))
        XCTAssertEqual(stopped.state, .idle)
    }

    func testListenerIsRxOnlyAndNeverAcquiresFloor() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = makeController(role: .listener, floor: floor, events: events)

        await controller.pttDown()
        let listenerEvents = await events.values()
        let listener = await controller.currentSnapshot()
        XCTAssertEqual(listenerEvents, [])
        XCTAssertEqual(listener.state, .rxOnly)
    }

    func testStartCueFailureStillEnablesMicrophone() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = PTTController(
            role: .staff,
            floor: floor,
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events, failStart: true),
            control: ControlMock(events: events),
            clock: ControlledClock(),
            onUpdate: { _ in }
        )

        await controller.pttDown()
        let snapshot = await controller.currentSnapshot()
        let cueEvents = await events.values()
        XCTAssertEqual(snapshot.state, .transmitting)
        XCTAssertTrue(cueEvents.contains("mic:on"))
        guard case .failure = snapshot.startCueResult else {
            return XCTFail("Expected cue failure diagnostic")
        }
        await controller.pttUp()
    }

    func testPttUpWhileWaitingForReceiverReadyNeverEnablesMicrophone() async {
        let events = EventLog()
        let floor = FloorMock(events: events, expectedSessions: ["receiver-a"])
        let control = BlockingReadyControl(events: events)
        let controller = PTTController(
            role: .staff,
            floor: floor,
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events),
            control: control,
            clock: ControlledClock(),
            onUpdate: { _ in }
        )
        let down = Task { await controller.pttDown() }
        await waitUntil { await control.isWaiting }
        await controller.pttUp()
        await down.value
        let values = await events.values()
        XCTAssertFalse(values.contains("mic:on"))
        XCTAssertTrue(values.contains("control:end"))
        XCTAssertTrue(values.contains("release"))
        let snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testDisconnectSafetyTurnsTxOffAndReleasesFloor() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = makeController(floor: floor, events: events)
        await controller.pttDown()

        await controller.stopForSafety(reason: "LiveKit disconnected")
        let snapshot = await controller.currentSnapshot()
        let values = await events.values()
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertTrue(values.contains("release"))
        XCTAssertTrue(values.contains("control:end"))
        XCTAssertLessThan(values.firstIndex(of: "mic:off")!, values.firstIndex(of: "control:end")!)
    }

    func testAudioInterruptionUsesSameImmediateSafetyPath() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = makeController(floor: floor, events: events)
        await controller.pttDown()

        await controller.stopForSafety(reason: "Audio interruption")
        let snapshot = await controller.currentSnapshot()
        let values = await events.values()
        XCTAssertNil(snapshot.leaseId)
        XCTAssertTrue(values.contains("mic:off"))
    }

    func testEndCueIsSuppressedIfMicrophoneCouldNotBeMuted() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = PTTController(
            role: .staff,
            floor: floor,
            microphone: MicrophoneMock(events: events, failOff: true),
            cuePlayer: CueMock(events: events),
            control: ControlMock(events: events),
            clock: ControlledClock(),
            onUpdate: { _ in }
        )
        await controller.pttDown()

        await controller.pttUp()
        let values = await events.values()
        XCTAssertFalse(values.contains("cue:end"))
        XCTAssertFalse(values.contains("control:end"))
        XCTAssertTrue(values.contains("release"))
    }

    func testEndCueFailureStillReleasesFloor() async {
        let events = EventLog()
        let floor = FloorMock(events: events)
        let controller = PTTController(
            role: .staff,
            floor: floor,
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events, failEnd: true),
            control: ControlMock(events: events),
            clock: ControlledClock(),
            onUpdate: { _ in }
        )
        await controller.pttDown()

        await controller.pttUp()
        let snapshot = await controller.currentSnapshot()
        let values = await events.values()
        guard case .failure = snapshot.endCueResult else {
            return XCTFail("Expected end cue failure diagnostic")
        }
        XCTAssertTrue(values.contains("release"))
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testBufferedApplePrearmDefersStartUntilDidActivateCaptureAndCue() async throws {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events)
        let controller = PTTController(
            role: .staff,
            floor: FloorMock(events: events),
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events),
            control: ControlMock(events: events),
            bufferedAudio: buffered,
            clock: ControlledClock(),
            onUpdate: { _ in }
        )

        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        var values = await events.values()
        XCTAssertTrue(values.contains("acquire"))
        XCTAssertFalse(values.contains("control:start"))
        XCTAssertFalse(values.contains("buffer:capture-start"))

        await controller.appleAudioSessionDidActivate()
        await controller.activatePrearmedTransmission()
        values = await events.values()
        XCTAssertLessThan(values.firstIndex(of: "buffer:capture-start")!, values.firstIndex(of: "buffer:capture-confirmed")!)
        XCTAssertLessThan(values.firstIndex(of: "buffer:capture-confirmed")!, values.firstIndex(of: "cue:start")!)
        XCTAssertLessThan(values.firstIndex(of: "cue:start")!, values.firstIndex(of: "control:start")!)
        XCTAssertLessThan(values.firstIndex(of: "control:start")!, values.firstIndex(of: "buffer:authorize")!)
        XCTAssertFalse(values.contains("mic:on"), "BATv1 generation must not enable LiveKit microphone publication")
        await controller.pttUp(playEndCue: false)
    }

    func testA1BufferedFinalMarkerPrecedesControlEndAndFloorRelease() async {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: ControlMock(events: events), bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in }
        )
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        await controller.appleAudioSessionDidActivate()
        await controller.activatePrearmedTransmission()
        await controller.pttUp(playEndCue: false)

        let values = await events.values()
        XCTAssertLessThan(values.firstIndex(of: "buffer:finish")!, values.firstIndex(of: "control:end")!)
        XCTAssertLessThan(values.firstIndex(of: "control:end")!, values.firstIndex(of: "release")!)
        let snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.txReleaseResult, "PASS")
        XCTAssertTrue(snapshot.txTerminalCleanupComplete)
        XCTAssertLessThan(snapshot.txFinalMarkerAcceptedSequence!, snapshot.txFloorReleaseRequestedSequence!)
    }

    func testReleaseDuringStartCuePreservesCapturedSpeechButSafetyStillDiscards() async throws {
        for safetyStop in [false, true] {
            let events = EventLog()
            let buffered = BufferedAudioMock(events: events)
            let control = BlockingReadyControl(events: events)
            let cue = SuspendedStartCue()
            let controller = PTTController(role: .staff, floor: FloorMock(events: events),
                microphone: MicrophoneMock(events: events), cuePlayer: cue, control: control,
                bufferedAudio: buffered, clock: ControlledClock(), onUpdate: { _ in })
            let prepared = await controller.preArmForAppleActivation()
            XCTAssertTrue(prepared)
            await controller.appleAudioSessionDidActivate()
            let activation = Task { await controller.activatePrearmedTransmission() }
            for _ in 0..<100 where !cue.waiting { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(cue.waiting)
            let release = Task { await controller.pttUp(playEndCue: false) }
            for _ in 0..<100 where !buffered.frozen { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(buffered.frozen, "Confirmed audio must freeze even while the start cue is pending")
            if safetyStop { await controller.stopForSafety(reason: "test safety stop during cue") }
            cue.resume()
            if !safetyStop {
                for _ in 0..<100 where !control.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
                XCTAssertTrue(control.isWaiting)
                control.ack()
            }
            await activation.value
            await release.value
            let values = await events.values()
            XCTAssertEqual(values.contains("buffer:authorize"), !safetyStop)
            XCTAssertFalse(values.contains("buffer:hangover"))
            let clean = await controller.cleanupIsConfirmed()
            XCTAssertTrue(clean)
        }
    }

    func testReleaseDuringCueSendsRealFrozenPcmAndExcludesPostReleaseSamples() async throws {
        let events = EventLog()
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let api = Batv1APIStub()
        let transmitter = BufferedAudioTransmitter(api: api, capture: capture,
            channelId: "channel", sessionId: "session", deviceId: "device", recordingAuthority: authority)
        let control = BlockingReadyControl(events: events)
        let cue = SuspendedStartCue()
        let controller = PTTController(role: .staff, floor: FloorMock(events: events),
            microphone: MicrophoneMock(events: events), cuePlayer: cue, control: control,
            bufferedAudio: transmitter, clock: ControlledClock(), onUpdate: { _ in })
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        await controller.appleAudioSessionDidActivate()
        capture.append(samples: [Int16](repeating: 1, count: 960), sampleRate: 48_000, channels: 1)
        let activation = Task { await controller.activatePrearmedTransmission() }
        for _ in 0..<100 where !cue.waiting { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(cue.waiting)
        capture.append(samples: [Int16](repeating: 7, count: 1060), sampleRate: 48_000, channels: 1)
        let release = Task { await controller.pttUp(playEndCue: false) }
        for _ in 0..<100 where authority.isRecording { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(authority.isRecording)
        XCTAssertTrue(api.publishedRequests.isEmpty)
        capture.append(samples: [Int16](repeating: 9, count: 960), sampleRate: 48_000, channels: 1)
        cue.resume()
        for _ in 0..<100 where !control.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(control.isWaiting)
        control.ack()
        await activation.value
        await release.value
        let chunks = api.publishedRequests.flatMap(\.chunks)
        XCTAssertEqual(chunks.map(\.sequence), [0, 1])
        let samples = try chunks.flatMap { chunk in
            try Batv1Pcm16LEConverter.floatSamples(from: XCTUnwrap(Data(base64Encoded: chunk.payloadBase64)))
        }
        XCTAssertEqual(samples.count, 1920)
        XCTAssertTrue(samples.prefix(1060).allSatisfy { abs($0 - Float(7) / 32768) < 0.000001 })
        XCTAssertTrue(samples.dropFirst(1060).allSatisfy { $0 == 0 })
        XCTAssertEqual(api.publishedRequests.last?.finalSequence, 1)
        let clean = await controller.cleanupIsConfirmed()
        XCTAssertTrue(clean)
    }

    func testShortBufferedReleaseKeepsReadyWaitAndSendsOnlyFrozenAudio() async throws {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events)
        let control = BlockingReadyControl(events: events)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: control, bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in }
        )
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        await controller.appleAudioSessionDidActivate()
        let activation = Task { await controller.activatePrearmedTransmission() }
        for _ in 0..<100 where !control.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(control.isWaiting)
        let release = Task { await controller.pttUp(playEndCue: false) }
        for _ in 0..<100 where !buffered.frozen { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(buffered.frozen)
        XCTAssertTrue(control.isWaiting)
        var values = await events.values()
        XCTAssertFalse(values.contains("buffer:authorize"))
        XCTAssertFalse(values.contains("release"))
        control.ack()
        await activation.value
        await release.value
        values = await events.values()
        XCTAssertTrue(values.contains("buffer:authorize"))
        XCTAssertTrue(values.contains("buffer:finish"))
        XCTAssertFalse(values.contains("buffer:hangover"))
        if let final = values.firstIndex(of: "buffer:finish"), let end = values.firstIndex(of: "control:end"),
           let released = values.firstIndex(of: "release") {
            XCTAssertLessThan(final, end)
            XCTAssertLessThan(end, released)
        } else { XCTFail("Missing final marker/END/release") }
        let confirmed = await controller.cleanupIsConfirmed()
        XCTAssertTrue(confirmed)
    }

    func testSafetyAbortsFrozenReadyWaitWithoutPublishingRecordedSpeech() async throws {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events)
        let control = BlockingReadyControl(events: events)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: control, bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in }
        )
        _ = await controller.preArmForAppleActivation()
        await controller.appleAudioSessionDidActivate()
        let activation = Task { await controller.activatePrearmedTransmission() }
        for _ in 0..<100 where !control.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        let release = Task { await controller.pttUp(playEndCue: false) }
        for _ in 0..<100 where !buffered.frozen { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(buffered.frozen)
        await controller.stopForSafety(reason: "disconnected")
        await activation.value
        await release.value
        control.ack()
        let values = await events.values()
        XCTAssertFalse(values.contains("buffer:authorize"))
        XCTAssertFalse(values.contains("buffer:finish"))
        XCTAssertTrue(values.contains("buffer:discard"))
        let confirmed = await controller.cleanupIsConfirmed()
        XCTAssertTrue(confirmed)
    }

    func testCancelledBarrierAloneCannotAuthorizeFrozenSpeech() async throws {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events)
        let control = BlockingReadyControl(events: events)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: control, bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in }
        )
        _ = await controller.preArmForAppleActivation()
        await controller.appleAudioSessionDidActivate()
        let activation = Task { await controller.activatePrearmedTransmission() }
        for _ in 0..<100 where !control.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        let release = Task { await controller.pttUp(playEndCue: false) }
        for _ in 0..<100 where !buffered.frozen { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(buffered.frozen)
        await control.cancelRxReady(leaseId: "lease-a")
        await activation.value
        await release.value
        let values = await events.values()
        XCTAssertFalse(values.contains("buffer:authorize"))
        XCTAssertTrue(values.contains("buffer:discard"))
        let confirmed = await controller.cleanupIsConfirmed()
        XCTAssertTrue(confirmed)
    }

    func testMissingOrCancelledReadyBarrierIsNotNoExpectations() async {
        let barrier = PttRxReadyBarrier()
        let missing = await barrier.wait(leaseId: "missing")
        XCTAssertTrue(missing.cancelled)
        await barrier.prepare(leaseId: "empty", expectedSessionIds: [])
        let empty = await barrier.wait(leaseId: "empty")
        XCTAssertFalse(empty.cancelled)
        await barrier.prepare(leaseId: "cancelled", expectedSessionIds: ["receiver"])
        await barrier.cancel(leaseId: "cancelled")
        let cancelled = await barrier.wait(leaseId: "cancelled")
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertFalse(cancelled.timedOut)
    }

    func testCancelledReadyWaitTaskReturnsWithoutBusyLoopingUntilTimeout() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(leaseId: "lease", expectedSessionIds: ["receiver"])
        let wait = Task { await barrier.wait(leaseId: "lease") }
        wait.cancel()
        let result = await wait.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
    }

    func testLeaseFailureAbortsFrozenReadyWaitWithoutPublication() async throws {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events)
        let control = BlockingReadyControl(events: events)
        let clock = RenewalGateClock()
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events, failRenew: true), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: control, bufferedAudio: buffered,
            clock: clock, onUpdate: { _ in }
        )
        _ = await controller.preArmForAppleActivation()
        await controller.appleAudioSessionDidActivate()
        let activation = Task { await controller.activatePrearmedTransmission() }
        for _ in 0..<100 where !control.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        let finished = expectation(description: "Release exits after lease loss")
        let release = Task { await controller.pttUp(playEndCue: false); finished.fulfill() }
        for _ in 0..<100 where !buffered.frozen { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(buffered.frozen)
        clock.allowRenewal()
        await fulfillment(of: [finished], timeout: 2)
        control.ack()
        await activation.value
        await release.value
        let values = await events.values()
        XCTAssertTrue(values.contains("renew"))
        XCTAssertFalse(values.contains("buffer:authorize"))
        XCTAssertFalse(values.contains("buffer:finish"))
        XCTAssertTrue(values.contains("buffer:discard"))
    }

    func testA2A3RenewContinuesWhileBufferedFinalizationExceedsLeaseTtl() async {
        let events = EventLog()
        let buffered = BlockingFinishBufferedAudioMock(events: events)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: ControlMock(events: events), bufferedAudio: buffered,
            clock: SystemPTTClock(), onUpdate: { _ in }
        )
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        await controller.appleAudioSessionDidActivate()
        await controller.activatePrearmedTransmission()
        let release = Task { await controller.pttUp(playEndCue: false) }
        await waitUntil { buffered.finishStarted }
        try? await Task.sleep(for: .milliseconds(3_200))
        let releasing = await controller.currentSnapshot()
        XCTAssertEqual(releasing.state, .releasing)
        XCTAssertGreaterThanOrEqual(releasing.txFloorRenewDuringReleaseCount, 3)
        buffered.completeFinish()
        await release.value
        let snapshot = await controller.currentSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.txFloorRenewDuringReleaseCount, 3)
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testA7FatalFinalMarkerFailureStillReleasesFloorAndRecoversReady() async {
        let events = EventLog()
        let buffered = BufferedAudioMock(events: events, failFinish: true)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: ControlMock(events: events), bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in }
        )
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        await controller.appleAudioSessionDidActivate()
        await controller.activatePrearmedTransmission()
        await controller.pttUp(playEndCue: false)
        let snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertTrue(snapshot.txTerminalCleanupComplete)
        XCTAssertEqual(snapshot.txErrorRecoverable, true)
        let values = await events.values()
        XCTAssertTrue(values.contains("release"))
    }

    func testA10HundredBufferedReleaseGenerationsCompleteWithoutLeaseLeakOrError() async {
        for generation in 0 ..< 100 {
            let events = EventLog()
            let controller = PTTController(
                role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
                cuePlayer: CueMock(events: events), control: ControlMock(events: events),
                bufferedAudio: BufferedAudioMock(events: events), clock: ControlledClock(), onUpdate: { _ in }
            )
            let prepared = await controller.preArmForAppleActivation()
            XCTAssertTrue(prepared, "generation \(generation)")
            await controller.appleAudioSessionDidActivate()
            await controller.activatePrearmedTransmission()
            await controller.pttUp(playEndCue: false)
            let snapshot = await controller.currentSnapshot()
            XCTAssertEqual(snapshot.state, .idle, "generation \(generation)")
            XCTAssertNil(snapshot.leaseId, "generation \(generation)")
            XCTAssertEqual(snapshot.txReleaseResult, "PASS", "generation \(generation)")
            XCTAssertTrue(snapshot.txTerminalCleanupComplete, "generation \(generation)")
        }
    }

    func testD50PreauthorizedAbortsRetainLeaseUntilConfirmedAndRequireAppleRearm() async {
        for iteration in 0..<50 {
            let events = EventLog()
            let buffered = BufferedAudioMock(events: events, failCapture: iteration % 3 == 1,
                failActivation: iteration % 3 == 2)
            let controller = PTTController(role: .staff, floor: FloorMock(events: events),
                microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
                control: ControlMock(events: events), bufferedAudio: buffered,
                clock: ControlledClock(), onUpdate: { _ in })
            var apple = PttRequestGate()
            _ = apple.pressDown()
            let prepared = await controller.preArmForAppleActivation()
            XCTAssertTrue(prepared)
            _ = apple.didBegin()
            if iteration % 3 == 0 { await controller.stopForSafety(reason: "TX_ACTIVATION_TIMEOUT") }
            else {
                await controller.appleAudioSessionDidActivate()
                await controller.activatePrearmedTransmission()
            }
            var snapshot = await controller.currentSnapshot()
            XCTAssertNil(snapshot.leaseId)
            XCTAssertNotNil(snapshot.floorReleaseCompletedAt)
            XCTAssertTrue(snapshot.txTerminalCleanupComplete)
            XCTAssertEqual(snapshot.txErrorRecoverable, true)
            XCTAssertEqual(snapshot.state, .error)
            await controller.completeRecoverableAbortAfterAppleRearm(appleSettled: false, audioRearmed: true)
            snapshot = await controller.currentSnapshot()
            XCTAssertEqual(snapshot.state, .error)
            _ = apple.didFail(recoverable: true)
            _ = apple.didEnd()
            _ = apple.finishRearming()
            await controller.completeRecoverableAbortAfterAppleRearm(appleSettled: apple.state == .idle, audioRearmed: true)
            snapshot = await controller.currentSnapshot()
            XCTAssertEqual(snapshot.state, .idle)
            let values = await events.values()
            XCTAssertEqual(values.filter { $0 == "release" }.count, 1)
            XCTAssertTrue(values.contains("buffer:discard"))
            XCTAssertFalse(values.contains("buffer:authorize"))
            XCTAssertFalse(values.contains("mic:on"))
        }
    }

    func testDFailedReleaseCannotForgetLeaseOrReleaseAnotherOwner() async {
        let events = EventLog()
        let controller = PTTController(role: .staff, floor: FloorMock(events: events, failRelease: true),
            microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
            control: ControlMock(events: events), bufferedAudio: BufferedAudioMock(events: events),
            clock: ControlledClock(), onUpdate: { _ in })
        _ = await controller.preArmForAppleActivation()
        await controller.stopForSafety(reason: "TX_ACTIVATION_TIMEOUT")
        var snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.leaseId, "lease-a")
        XCTAssertNil(snapshot.floorReleaseCompletedAt)
        XCTAssertFalse(snapshot.txTerminalCleanupComplete)
        let cleanupConfirmed = await controller.cleanupIsConfirmed()
        XCTAssertFalse(cleanupConfirmed)
        let other = FloorResponse(outcome: .busy, owner: FloorOwner(id: "other", name: "Other"),
            leaseId: nil, acquiredAt: nil, leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false)
        await controller.reconcileOwnFloor(other)
        await controller.completeRecoverableAbortAfterAppleRearm(appleSettled: true, audioRearmed: true)
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .error)
        let values = await events.values()
        XCTAssertEqual(values.filter { $0 == "release" }.count, 3)
        let available = FloorResponse(outcome: .available, owner: nil, leaseId: nil,
            acquiredAt: nil, leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false)
        await controller.reconcileOwnFloor(available)
        await controller.completeRecoverableAbortAfterAppleRearm(appleSettled: true, audioRearmed: true)
        snapshot = await controller.currentSnapshot()
        XCTAssertNil(snapshot.leaseId)
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testD100RoleReversalsUseBufferedReceiverWithoutChannelSwitch() async {
        let events = EventLog()
        let controller = PTTController(role: .staff, floor: FloorMock(events: events),
            microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
            control: ControlMock(events: events), bufferedAudio: BufferedAudioMock(events: events),
            clock: ControlledClock(), onUpdate: { _ in })
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0, bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())])
        }
        var firstPcmCount = 0
        let player = Batv1PcmPlayerMock()
        let receiver = BufferedAudioReceiver(api: api, sessionId: "receiver", onPcm: { _ in firstPcmCount += 1 }, player: player)
        for cycle in 0..<100 {
            let prepared = await controller.preArmForAppleActivation()
            XCTAssertTrue(prepared)
            await controller.appleAudioSessionDidActivate()
            await controller.activatePrearmedTransmission()
            await controller.pttUp(playEndCue: false)
            let snapshot = await controller.currentSnapshot()
            XCTAssertEqual(snapshot.state, .idle)
            receiver.audioSessionDidDeactivate()
            receiver.start(generationId: "reverse-\(cycle)", senderSessionId: "android")
            // The current Apple activation is rebound even if it predates START.
            receiver.audioSessionDidActivate()
            receiver.start(generationId: "reverse-\(cycle)", senderSessionId: "android")
            await receiver.awaitCurrentGenerationTermination()
            XCTAssertEqual(firstPcmCount, cycle + 1)
        }
        await receiver.shutdownAndAwait()
        XCTAssertEqual(player.beginCount, 100, "Duplicate START must not recreate player generation")
        XCTAssertEqual(player.endCount, 100)
        let values = await events.values()
        XCTAssertEqual(values.filter { $0 == "release" }.count, 100)
    }

    func testDLateActivationFailureCannotAbortTheNextAttempt() async {
        let events = EventLog()
        let buffered = SuspendedCaptureMock()
        let controller = PTTController(role: .staff, floor: FloorMock(events: events),
            microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
            control: ControlMock(events: events), bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in })
        _ = await controller.preArmForAppleActivation()
        let oldActivation = Task { await controller.activatePrearmedTransmission() }
        await waitUntil { buffered.isWaiting }
        await controller.pttUp(playEndCue: false)
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        let newAttempt = await controller.currentSnapshot().attemptGeneration
        buffered.failOldCapture()
        await oldActivation.value
        var snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.attemptGeneration, newAttempt)
        XCTAssertEqual(snapshot.state, .requestingFloor)
        XCTAssertNotNil(snapshot.leaseId)
        await controller.activatePrearmedTransmission()
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .transmitting)
        await controller.pttUp(playEndCue: false)
    }

    func testDLateRecordingStartFailureCannotAbortTheNextAttempt() async {
        let events = EventLog()
        let buffered = SuspendedCaptureMock(suspendRecording: true)
        let controller = PTTController(role: .staff, floor: FloorMock(events: events),
            microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
            control: ControlMock(events: events), bufferedAudio: buffered,
            clock: ControlledClock(), onUpdate: { _ in })
        _ = await controller.preArmForAppleActivation()
        let oldActivation = Task { await controller.appleAudioSessionDidActivate() }
        await waitUntil { buffered.isWaiting }
        await controller.pttUp(playEndCue: false)
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        let newAttempt = await controller.currentSnapshot().attemptGeneration
        buffered.failOldRecording()
        await oldActivation.value
        var snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.attemptGeneration, newAttempt)
        XCTAssertEqual(snapshot.state, .requestingFloor)
        XCTAssertNotNil(snapshot.leaseId)
        await controller.activatePrearmedTransmission()
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.state, .transmitting)
        await controller.pttUp(playEndCue: false)
    }

    private func makeController(
        role: KOEONRole = .staff,
        floor: FloorMock,
        events: EventLog,
        clock: any PTTClock = ControlledClock()
    ) -> PTTController {
        PTTController(
            role: role,
            floor: floor,
            microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events),
            control: ControlMock(events: events),
            clock: clock,
            onUpdate: { _ in }
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping () async -> Bool
    ) async {
        for _ in 0 ..< attempts {
            if await condition() { return }
            await Task.yield()
        }
    }
}

final class InputGainProcessorTests: XCTestCase {
    func testRouteChangeCancelsCalibrationAndUsesNewMicrophoneGain() {
        withCapture { gain, capture in
            gain.setMode(.manual)
            gain.setRoute("Wired")
            gain.setManualGainDb(12)
            gain.setRoute("Built-in")
            gain.setManualGainDb(6)
            capture.arm(generationId: "route-change")
            gain.startCalibration()
            gain.setRoute("Wired")
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 12)
            XCTAssertEqual(gain.snapshot().calibrationState, "IDLE")
            XCTAssertNil(gain.snapshot().recommendationDb)
        }
    }

    func testRouteChangeCannotTrainAnotherMicrophoneProfile() {
        withCapture { gain, capture in
            gain.setMode(.auto)
            gain.setRoute("Built-in")
            capture.arm(generationId: "route-change")
            feed(gain, value: 2_000, count: 9_600)
            gain.setRoute("Wired")
            feed(gain, value: 2_000, count: 9_600)
            capture.discard(learnFromCapture: true)
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
            gain.setRoute("Built-in")
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
        }
    }

    func testCaptureRetainsPreRollMetersAndLearnsOnlyAfterSuccessfulCompletion() {
        withCapture { gain, capture in
            gain.setMode(.auto)
            capture.arm(generationId: "short")
            feed(gain, value: 32_000, count: 960)
            capture.markCueBoundary()
            feed(gain, value: 2_000, count: 9_600)
            XCTAssertTrue(capture.freeze(generationId: "short"))
            _ = capture.startForwarding { _ in }
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
            let before = gain.snapshot().rmsDbfs
            feed(gain, value: 32_000, count: 960)
            XCTAssertEqual(gain.snapshot().rmsDbfs, before)
            XCTAssertEqual(gain.snapshot().peakDbfs!, -24.2884, accuracy: 0.001)
            capture.discard(learnFromCapture: true)
            XCTAssertEqual(gain.snapshot().autoTrimDb, 1)
            capture.discard(learnFromCapture: true)
            XCTAssertEqual(gain.snapshot().autoTrimDb, 1)
        }
    }

    func testCancelledCaptureDoesNotTrainAuto() {
        withCapture { gain, capture in
            gain.setMode(.auto)
            capture.arm(generationId: "cancelled")
            feed(gain, value: 2_000, count: 9_600)
            capture.discard()
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
        }
    }

    func testGainRemainsFixedThroughReleaseTailAndStopsMeteringAfterCapture() {
        withCapture { gain, capture in
            gain.setMode(.manual)
            gain.setManualGainDb(6)
            capture.arm(generationId: "normal")
            capture.markCueBoundary()
            feed(gain, value: 2_000, count: 960)
            gain.setManualGainDb(12)
            _ = capture.startForwarding { _ in }
            feed(gain, value: 2_000, count: 960)
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 6)
            XCTAssertEqual(capture.frameCount, 2)
            capture.stopForwarding()
            feed(gain, value: 32_000, count: 960)
            XCTAssertEqual(gain.snapshot().peakDbfs!, -24.2884, accuracy: 0.001)
            capture.discard(learnFromCapture: true)
            capture.arm(generationId: "next")
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 12)
        }
    }

    private func feed(_ gain: InputGainProcessor, value: Float, count: Int) {
        var samples = [Float](repeating: value, count: count)
        samples.withUnsafeMutableBufferPointer { buffer in
            gain.processFloatS16(channels: 1, frames: count) { _ in buffer.baseAddress! }
        }
    }

    private func withCapture(_ body: (InputGainProcessor, Batv1CaptureBuffer) -> Void) {
        let name = "input-gain-capture-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gain = InputGainProcessor(defaults: defaults)
        let capture = Batv1CaptureBuffer(inputGain: gain)
        gain.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        gain.setPostProcessedPcmConsumer { [weak capture] samples, rate, channels in
            capture?.append(samples: samples, sampleRate: rate, channels: channels)
        }
        body(gain, capture)
    }

    func testAutoConvergesToOutputTargetAndReducesExcessGain() {
        var trim: Float = 0
        for _ in 0..<30 { trim = InputGainProcessor.nextAutoTrim(current: trim, speechRmsDbfs: -24) }
        XCTAssertEqual(trim, 6, accuracy: 0.001)
        XCTAssertEqual(InputGainProcessor.nextAutoTrim(current: 6, speechRmsDbfs: -18), 5)
    }

    func testAutoIgnoresSilentAndInvalidMeasurements() {
        for level: Float in [-120, -90, -60, .nan, -.infinity] {
            XCTAssertEqual(InputGainProcessor.nextAutoTrim(current: 4, speechRmsDbfs: level), 4)
        }
    }

    func testPositiveAndNegativeSamplesReceiveSymmetricManualGain() {
        let positive = InputGainProcessor.processSample(0.1, gainDb: 6)
        let negative = InputGainProcessor.processSample(-0.1, gainDb: 6)
        XCTAssertEqual(positive.sample, -negative.sample, accuracy: 0.0001)
        XCTAssertEqual(positive.sample, 0.1995, accuracy: 0.001)
        XCTAssertFalse(positive.limited)
    }

    func testSoftLimiterHasNoLookaheadAndStaysBelowFullScale() {
        let output = InputGainProcessor.processSample(0.95, gainDb: 12)
        XCTAssertTrue(output.limited)
        XCTAssertLessThan(output.sample, 0.9)
        XCTAssertGreaterThan(output.sample, 0.75)
    }

    func testCalibrationAndAutoTrimBounds() {
        XCTAssertEqual(InputGainProcessor.recommendedGain(speechRmsDbfs: -50), 12)
        XCTAssertEqual(InputGainProcessor.recommendedGain(speechRmsDbfs: -5), -6)
        XCTAssertEqual(InputGainProcessor.nextAutoTrim(current: 0, speechRmsDbfs: -30), 1)
        XCTAssertEqual(InputGainProcessor.nextAutoTrim(current: 0, speechRmsDbfs: -5), -1)
    }
}

final class BufferedAudioTimelineTests: XCTestCase {
    func testPlaybackGraphUsesStandardFloat32Format() throws {
        let format = try XCTUnwrap(makeBatv1PlaybackGraphFormat())
        XCTAssertTrue(format.isStandard)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertFalse(format.isInterleaved)
        XCTAssertTrue(isValidBatv1PlaybackGraphFormat(format))
    }

    func testPcm16LittleEndianConversionUsesExactScale() throws {
        let knownSamples = Data([
            0x00, 0x00,
            0xff, 0x7f,
            0x00, 0x80,
            0x00, 0x40,
            0x00, 0xc0
        ] + Array(repeating: 0, count: batv1BytesPerFrame - 10))
        let converted = try Batv1Pcm16LEConverter.floatSamples(from: knownSamples)
        XCTAssertEqual(converted.count, 960)
        XCTAssertEqual(converted[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(converted[1], 32_767.0 / 32_768.0, accuracy: 0.000_001)
        XCTAssertEqual(converted[2], -1, accuracy: 0.000_001)
        XCTAssertEqual(converted[3], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(converted[4], -0.5, accuracy: 0.000_001)
        XCTAssertTrue(converted.allSatisfy { $0.isFinite })
    }

    func testExactWireFrameCreatesNineHundredSixtyFrameFloatBuffer() throws {
        let format = try XCTUnwrap(makeBatv1PlaybackGraphFormat())
        let buffer = try Batv1Pcm16LEConverter.playbackBuffer(
            from: Data(count: batv1BytesPerFrame),
            format: format
        )
        XCTAssertEqual(buffer.frameCapacity, 960)
        XCTAssertEqual(buffer.frameLength, 960)
        XCTAssertNotNil(buffer.floatChannelData)
        XCTAssertNil(buffer.int16ChannelData)
    }

    func testInvalidWireByteCountsAreRejected() throws {
        let format = try XCTUnwrap(makeBatv1PlaybackGraphFormat())
        XCTAssertThrowsError(try Batv1Pcm16LEConverter.playbackBuffer(from: Data(count: 1_919), format: format))
        XCTAssertThrowsError(try Batv1Pcm16LEConverter.playbackBuffer(from: Data(count: 1_921), format: format))
    }

    @MainActor
    func testNonstandardGraphFormatFailsBeforeAttachOrConnect() throws {
        let int16Format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        XCTAssertFalse(isValidBatv1PlaybackGraphFormat(int16Format))
        let player = IOSBatv1PcmPlayer(playbackGraphFormat: int16Format)
        XCTAssertThrowsError(try player.prepareGraphIfNeeded()) { error in
            guard case BufferedAudioError.invalidAudioGraphFormat = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(player.graphPrepared)
        XCTAssertEqual(player.graphPreparationCount, 0)
        player.shutdown()
    }

    @MainActor
    func testRealAudioEngineGraphConnectsWithStandardPlaybackFormat() throws {
        let player = IOSBatv1PcmPlayer()
        XCTAssertNoThrow(try player.prepareGraphIfNeeded())
        XCTAssertTrue(player.graphPrepared)
        XCTAssertEqual(player.graphPreparationCount, 1)
        player.shutdown()
    }

    @MainActor
    func testRealAudioEngineGraphIsReusedAcrossGenerations() throws {
        let player = IOSBatv1PcmPlayer()
        try player.beginGeneration(token: 1, startEngine: false)
        player.endGeneration(token: 1)
        try player.beginGeneration(token: 2, startEngine: false)
        player.endGeneration(token: 2)
        XCTAssertEqual(player.graphPreparationCount, 1)
        player.shutdown()
    }

    @MainActor
    func testRealPlayerCancelledDrainReturnsWithoutMarkingQueuedAudioPlayed() async throws {
        let player = IOSBatv1PcmPlayer()
        defer { player.shutdown() }
        try player.beginGeneration(token: 1, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        let entered = expectation(description: "Drain entered")
        let returned = expectation(description: "Cancelled drain returned")
        let draining = Task { @MainActor in
            entered.fulfill()
            try await player.drain(generationToken: 1)
            returned.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        draining.cancel()
        await fulfillment(of: [returned], timeout: 1)
        try await draining.value
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        player.endGeneration(token: 1)
        try player.beginGeneration(token: 2, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 2)
        player.endGeneration(token: 1)
        XCTAssertEqual(player.pendingFrames, 1, "Old cleanup must not clear the next generation")
        XCTAssertEqual(player.completedFrames, 0)
    }

    @MainActor
    func testRealPlayerDrainContinuesWaitingForUnplayedAudioUntilGenerationEnds() async throws {
        let player = IOSBatv1PcmPlayer()
        defer { player.shutdown() }
        try player.beginGeneration(token: 1, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        var returned = false
        let draining = Task { @MainActor in
            try await player.drain(generationToken: 1)
            returned = true
        }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(returned)
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        player.endGeneration(token: 1)
        try await draining.value
        XCTAssertTrue(returned)
    }

    @MainActor
    func testConfigurationChangeRetainsUnplayedPcmUntilAppleAudioActivation() async throws {
        let engine = AVAudioEngine()
        let player = IOSBatv1PcmPlayer(engine: engine)
        defer { player.shutdown() }
        try player.beginGeneration(token: 1, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(player.configurationChangeCount, 1)
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        XCTAssertEqual(player.recoveryCount, 0)
        XCTAssertFalse(engine.isRunning, "Configuration changes do not grant Apple audio authority")
        XCTAssertEqual(player.playbackDiagnostics.inputRmsDbfs, -120)
        XCTAssertNotNil(player.playbackDiagnostics.lastEnqueueOutput)
        XCTAssertNil(player.playbackDiagnostics.lastCompletionOutput)
    }

    @MainActor
    func testConfigurationChangeRestartsEngineAndRendersRetainedPcm() async throws {
        for (outputRate, outputChannels) in [(16_000.0, AVAudioChannelCount(1)), (44_100.0, AVAudioChannelCount(2))] {
            let engine = AVAudioEngine()
            let player = IOSBatv1PcmPlayer(engine: engine)
            defer { player.shutdown() }
            let format = try XCTUnwrap(player.playbackGraphFormat)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try player.prepareGraphIfNeeded()
            try player.beginGeneration(token: 1)
            var data = Data()
            for _ in 0..<(batv1BytesPerFrame / 2) { data.append(contentsOf: [0x00, 0x10]) }
            try player.enqueue(data, generationToken: 1)
            try player.enqueue(data, generationToken: 1)
            engine.stop()
            engine.disableManualRenderingMode()
            let changedFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: outputChannels))
            try engine.enableManualRenderingMode(.offline, format: changedFormat, maximumFrameCount: 4096)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
            for _ in 0..<100 where player.recoveryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(engine.isRunning)
            XCTAssertEqual(player.recoveryCount, 1)
            XCTAssertEqual(player.pendingFrames, 2, "Stopped buffers must not be counted as played")
            XCTAssertEqual(player.completedFrames, 0)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 4096))
            var observedNonzeroPcm = false
            for _ in 0..<20 {
                _ = try engine.renderOffline(4096, to: output)
                if let samples = output.floatChannelData?[0] {
                    observedNonzeroPcm = observedNonzeroPcm || (0..<Int(output.frameLength)).contains { abs(samples[$0]) > 0.01 }
                }
                await Task.yield()
            }
            XCTAssertTrue(observedNonzeroPcm, "Recovery must render the retained speech, not just restart an empty node")
            XCTAssertEqual(player.graphPreparationCount, 1)
            XCTAssertEqual(try XCTUnwrap(player.playbackDiagnostics.inputRmsDbfs), -18.0618, accuracy: 0.001)
            // Offline manual rendering does not deliver dataPlayedBack on this
            // Simulator. The realtime test below checks actual callback accounting.
        }
    }

    @MainActor
    func testRealtimeRecoveryCompletesEachRetainedFrameExactlyOnce() async throws {
        let engine = AVAudioEngine()
        let player = IOSBatv1PcmPlayer(engine: engine)
        defer { player.shutdown() }
        try player.beginGeneration(token: 1)
        // Silent synthetic PCM: use the Simulator render clock without speech
        // playback, recording, or any connected phone operation.
        for _ in 0..<3 { try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1) }
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(player.pendingFrames, 3)
        XCTAssertEqual(player.completedFrames, 0)
        for _ in 0..<100 where player.completedFrames != 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.recoveryCount, 1)
        XCTAssertEqual(player.completedFrames, 3)
        XCTAssertEqual(player.pendingFrames, 0)
        XCTAssertNotNil(player.playbackDiagnostics.lastCompletionOutput)
        XCTAssertNil(player.playbackDiagnostics.lastErrorCode)
    }

    @MainActor
    func testConfigurationChangeFromEndedGenerationCannotRestartNextIdleGeneration() async throws {
        let engine = AVAudioEngine()
        let player = IOSBatv1PcmPlayer(engine: engine)
        defer { player.shutdown() }
        try player.beginGeneration(token: 1, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        player.endGeneration(token: 1)
        try player.beginGeneration(token: 2, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 2)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        XCTAssertEqual(player.configurationChangeCount, 0)
        XCTAssertEqual(player.recoveryCount, 0)
        XCTAssertFalse(engine.isRunning)
    }

    @MainActor
    func testInitialEngineStartRetriesAndRendersRetainedPcm() async throws {
        let engine = AVAudioEngine()
        var attempts = 0
        let player = IOSBatv1PcmPlayer(engine: engine, startEngine: {
            attempts += 1
            if attempts <= 2 { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
            try $0.start()
        })
        defer { player.shutdown() }
        let format = try XCTUnwrap(player.playbackGraphFormat)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try player.beginGeneration(token: 1)
        let pcm = Data(Array(repeating: [UInt8(0), UInt8(0x10)], count: batv1BytesPerFrame / 2).flatMap { $0 })
        try player.enqueue(pcm, generationToken: 1)
        try player.enqueue(pcm, generationToken: 1)
        XCTAssertEqual(player.pendingFrames, 2)
        XCTAssertEqual(player.completedFrames, 0)
        for _ in 0..<100 where player.recoveryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(player.playbackDiagnostics.engineStartFailures, 2)
        XCTAssertEqual(player.playbackDiagnostics.lastEngineStartErrorDomain, NSOSStatusErrorDomain)
        XCTAssertEqual(player.playbackDiagnostics.lastEngineStartErrorCode, -50)
        XCTAssertTrue(engine.isRunning)
        XCTAssertNil(player.playbackDiagnostics.lastErrorCode)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var renderedSpeech = false
        for _ in 0..<20 {
            _ = try engine.renderOffline(4096, to: output)
            if let samples = output.floatChannelData?[0] {
                renderedSpeech = renderedSpeech || (0..<Int(output.frameLength)).contains { abs(samples[$0]) > 0.01 }
            }
            await Task.yield()
        }
        XCTAssertTrue(renderedSpeech)
        XCTAssertEqual(player.graphPreparationCount, 1)
    }

    @MainActor
    func testInitialEngineStartFailureHasBoundedRetriesAndCannotReportDrainSuccess() async throws {
        var attempts = 0
        let player = IOSBatv1PcmPlayer(startEngine: { _ in
            attempts += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: -50)
        })
        defer { player.shutdown() }
        try player.beginGeneration(token: 1)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        for _ in 0..<100 where player.playbackDiagnostics.lastErrorCode == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(player.playbackDiagnostics.lastErrorCode, "RX_ENGINE_RECOVERY_FAILED")
        guard player.playbackDiagnostics.lastErrorCode != nil else { return }
        do { try await player.drain(generationToken: 1); XCTFail("No successful drain without a started engine") }
        catch { XCTAssertEqual((error as NSError).code, -50) }
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
    }

    @MainActor
    func testInitialStartRetryWaitsForAppleReactivation() async throws {
        let engine = AVAudioEngine()
        var attempts = 0
        let player = IOSBatv1PcmPlayer(engine: engine, startEngine: {
            attempts += 1
            if attempts == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
            try $0.start()
        })
        defer { player.shutdown() }
        try engine.enableManualRenderingMode(.offline, format: XCTUnwrap(player.playbackGraphFormat), maximumFrameCount: 4096)
        try player.beginGeneration(token: 1)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        player.audioSessionDidDeactivate()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(player.pendingFrames, 1)
        try player.resumeIfNeeded()
        for _ in 0..<100 where player.recoveryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(player.pendingFrames, 1)
    }

    @MainActor
    func testInitialStartRetryCannotStartReplacementGenerationWithoutAudioPermission() async throws {
        var attempts = 0
        let player = IOSBatv1PcmPlayer(startEngine: { _ in
            attempts += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: -50)
        })
        defer { player.shutdown() }
        try player.beginGeneration(token: 1)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        player.endGeneration(token: 1)
        try player.beginGeneration(token: 2, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 2)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        XCTAssertEqual(player.recoveryCount, 0)
    }

    @MainActor
    func testFailedEngineRecoveryTerminatesDrainWithoutFalsePlaybackCompletion() async throws {
        var attempts = 0
        let player = IOSBatv1PcmPlayer(startEngine: { _ in
            attempts += 1
            throw BufferedAudioError.playbackEngineUnavailable
        })
        defer { player.shutdown() }
        try player.beginGeneration(token: 1, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        try player.resumeIfNeeded()
        for _ in 0..<100 where player.playbackDiagnostics.lastErrorCode == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(player.playbackDiagnostics.lastErrorCode, "RX_ENGINE_RECOVERY_FAILED")
        guard player.playbackDiagnostics.lastErrorCode != nil else { return }
        XCTAssertThrowsError(try player.checkPlaybackHealth())
        do {
            try await player.drain(generationToken: 1)
            XCTFail("Failed recovery must not finish a successful drain")
        } catch BufferedAudioError.playbackEngineUnavailable { }
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        XCTAssertNil(player.playbackDiagnostics.lastCompletionOutput)
    }

    @MainActor
    func testAppleDeactivationCancelsRecoveryAndReactivationResumesRetainedAudio() async throws {
        let engine = AVAudioEngine()
        var attempts = 0
        let player = IOSBatv1PcmPlayer(engine: engine, startEngine: {
            attempts += 1
            try $0.start()
        })
        defer { player.shutdown() }
        try engine.enableManualRenderingMode(.offline, format: XCTUnwrap(player.playbackGraphFormat), maximumFrameCount: 4096)
        try player.prepareGraphIfNeeded()
        try player.beginGeneration(token: 1, startEngine: false)
        try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1)
        try player.resumeIfNeeded()
        player.audioSessionDidDeactivate()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
        XCTAssertFalse(engine.isRunning)
        try player.resumeIfNeeded()
        for _ in 0..<100 where player.recoveryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(player.recoveryCount, 1)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(player.pendingFrames, 1)
        XCTAssertEqual(player.completedFrames, 0)
    }

    @MainActor
    func testPlayerRetainedQueueIsBoundedWithoutSilentlyDroppingSpeech() throws {
        let player = IOSBatv1PcmPlayer()
        defer { player.shutdown() }
        try player.beginGeneration(token: 1, startEngine: false)
        for _ in 0..<batv1MaximumFrames { try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1) }
        XCTAssertThrowsError(try player.enqueue(Data(count: batv1BytesPerFrame), generationToken: 1))
        XCTAssertEqual(player.pendingFrames, batv1MaximumFrames)
        XCTAssertEqual(player.completedFrames, 0)
    }

    @MainActor
    func testRealAudioEnginePlayerReusesGraphForOneHundredGenerations() throws {
        let player = IOSBatv1PcmPlayer()
        let frame = Data(count: batv1BytesPerFrame)
        for token in 1...100 {
            try player.beginGeneration(token: token, startEngine: false)
            try player.enqueue(frame, generationToken: token)
            player.endGeneration(token: token)
        }
        XCTAssertEqual(player.graphPreparationCount, 1)
        XCTAssertEqual(player.pendingFrames, 0)
        player.shutdown()
    }

    func testCaptureIsMemoryBoundedToSixSeconds() {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: UUID().uuidString)
        let frame = Array(repeating: Int16(7), count: batv1BytesPerFrame / 2)
        for _ in 0..<350 {
            capture.append(samples: frame, sampleRate: batv1SampleRate, channels: 1)
        }
        XCTAssertEqual(capture.frameCount, 300)
        XCTAssertEqual(capture.droppedFrames, 50)
    }

    func testNetworkForwardingIsZeroBeforeAuthorizationBoundary() {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: UUID().uuidString)
        let frame = Array(repeating: Int16(9), count: batv1BytesPerFrame / 2)
        for _ in 0..<5 {
            capture.append(samples: frame, sampleRate: batv1SampleRate, channels: 1)
        }
        var forwarded = 0
        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(capture.startForwarding { _ in forwarded += 1 }, 5)
        capture.append(samples: frame, sampleRate: batv1SampleRate, channels: 1)
        XCTAssertEqual(forwarded, 6)
    }

    func testPerReceiverCatchupRateContractAndMaximum() {
        XCTAssertEqual(batv1PlaybackRate(backlogMilliseconds: 100), 1.00)
        XCTAssertEqual(batv1PlaybackRate(backlogMilliseconds: 800), 1.20)
        XCTAssertEqual(batv1PlaybackRate(backlogMilliseconds: 1_800), 1.325)
        XCTAssertEqual(batv1PlaybackRate(backlogMilliseconds: 4_000), 1.45)
        XCTAssertLessThanOrEqual(batv1PlaybackRate(backlogMilliseconds: Int.max), 1.50)
    }

    func testSenderIdentityResolutionRequiresSDKMatchOrCurrentRoomMatch() {
        XCTAssertEqual(
            resolveControlSenderIdentity(
                eventParticipantIdentity: "session-a",
                controlSessionId: "session-a",
                currentRemoteParticipantIdentities: ["session-a"]
            ),
            ResolvedControlSenderIdentity(identity: "session-a", resolution: .sdkEvent)
        )
        XCTAssertEqual(
            resolveControlSenderIdentity(
                eventParticipantIdentity: "attacker",
                controlSessionId: "session-a",
                currentRemoteParticipantIdentities: ["session-a"]
            ).resolution,
            .rejected
        )
        XCTAssertEqual(
            resolveControlSenderIdentity(
                eventParticipantIdentity: nil,
                controlSessionId: "session-a",
                currentRemoteParticipantIdentities: ["session-a", "session-b"]
            ),
            ResolvedControlSenderIdentity(identity: "session-a", resolution: .roomSessionMatch)
        )
        XCTAssertEqual(
            resolveControlSenderIdentity(
                eventParticipantIdentity: nil,
                controlSessionId: "session-a",
                currentRemoteParticipantIdentities: ["session-a", "session-a"]
            ).resolution,
            .rejected
        )
    }

    @MainActor
    func testCancelledCaptureWaitDoesNotAcceptBufferedPcm() async {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: "cancelled")
        capture.append(samples: Array(repeating: Int16(7), count: batv1BytesPerFrame / 2),
                       sampleRate: batv1SampleRate, channels: batv1Channels)
        let wait = Task { @MainActor in await capture.awaitCapture() }
        wait.cancel()
        let confirmed = await wait.value
        XCTAssertFalse(confirmed)
        XCTAssertEqual(capture.frameCount, 1)
    }

    @MainActor
    func testLateCaptureConfirmationCannotOverwriteStoppedDiagnostics() async throws {
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let transmitter = BufferedAudioTransmitter(
            api: Batv1APIStub(), capture: capture, channelId: "channel-a",
            sessionId: "session-a", deviceId: "device-a", recordingAuthority: authority
        )
        await transmitter.prepare(generationId: "old")
        try await transmitter.audioSessionDidActivate()
        let started = expectation(description: "Old capture wait started")
        let wait = Task { @MainActor in
            started.fulfill()
            return await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "old")
        }
        await fulfillment(of: [started], timeout: 1)
        await transmitter.discard(generationId: "old")
        let confirmed = await wait.value
        XCTAssertFalse(confirmed)
        XCTAssertEqual(transmitter.diagnostics.captureState, "STOPPED")
        XCTAssertNil(transmitter.diagnostics.lastErrorCode)
        XCTAssertFalse(authority.isRecording)
    }

    @MainActor
    func testOldCaptureWaitCannotConsumeNewGenerationPreRoll() async throws {
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let transmitter = BufferedAudioTransmitter(
            api: Batv1APIStub(), capture: capture, channelId: "channel-a",
            sessionId: "session-a", deviceId: "device-a", recordingAuthority: authority
        )
        await transmitter.prepare(generationId: "old")
        try await transmitter.audioSessionDidActivate()
        let started = expectation(description: "Old capture wait started")
        let wait = Task { @MainActor in
            started.fulfill()
            return await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "old")
        }
        await fulfillment(of: [started], timeout: 1)
        await transmitter.prepare(generationId: "new")
        try await transmitter.audioSessionDidActivate()
        capture.append(samples: Array(repeating: Int16(17), count: batv1BytesPerFrame / 2),
                       sampleRate: batv1SampleRate, channels: batv1Channels)
        let oldConfirmed = await wait.value
        XCTAssertFalse(oldConfirmed)
        XCTAssertEqual(capture.frameCount, 1, "Old confirmation must not clear the new capture boundary")
        XCTAssertEqual(transmitter.diagnostics.generationId, "new")
        XCTAssertEqual(transmitter.diagnostics.captureState, "RECORDING")
        XCTAssertFalse(transmitter.diagnostics.captureConfirmed)
        XCTAssertTrue(authority.isRecording)
        let newConfirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "new")
        XCTAssertTrue(newConfirmed)
        await transmitter.discard(generationId: "new")
    }

    @MainActor
    func testLocalRecordingStartsOnlyAfterDidActivateAndStopsIdempotently() async throws {
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let transmitter = BufferedAudioTransmitter(
            api: Batv1APIStub(),
            capture: capture,
            channelId: "channel-a",
            sessionId: "session-a",
            deviceId: "device-a",
            recordingAuthority: authority
        )
        await transmitter.prepare(generationId: "generation-a")
        XCTAssertEqual(authority.startCount, 0)
        try await transmitter.audioSessionDidActivate()
        XCTAssertEqual(authority.startCount, 1)
        capture.append(
            samples: Array(repeating: Int16(5), count: batv1BytesPerFrame / 2),
            sampleRate: batv1SampleRate,
            channels: batv1Channels
        )
        let captureConfirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "generation-a")
        XCTAssertTrue(captureConfirmed)
        await transmitter.discard(generationId: "generation-a")
        try authority.stop()
        XCTAssertEqual(authority.stopCount, 1, "Repeated stop is safe and does not invoke SDK twice")
    }

    @MainActor
    func testTxLifecycleStressRunsOneHundredGenerationsWithoutDoubleStop() async throws {
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let transmitter = BufferedAudioTransmitter(
            api: Batv1APIStub(), capture: capture, channelId: "channel-a",
            sessionId: "session-a", deviceId: "device-a", recordingAuthority: authority
        )
        let frame = Array(repeating: Int16(5), count: batv1BytesPerFrame / 2)

        for index in 0..<100 {
            let generation = "tx-stress-\(index)"
            await transmitter.prepare(generationId: generation)
            try await transmitter.audioSessionDidActivate()
            capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels)
            let captureConfirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: generation)
            XCTAssertTrue(captureConfirmed)
            try await transmitter.authorize(leaseId: "lease-a", generationId: generation)
            capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels)
            try await transmitter.finish(generationId: generation)
        }

        XCTAssertEqual(authority.startCount, 100)
        XCTAssertEqual(authority.stopCount, 100)
        XCTAssertFalse(authority.isRecording)
    }

    @MainActor
    func testOnlyAcknowledgedFinalMarkerCommitsCaptureGainLearning() async throws {
        for rejectFinal in [false, true] {
            let name = "gain-transmitter-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let gain = InputGainProcessor(defaults: defaults)
            gain.setMode(.auto)
            gain.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
            let capture = Batv1CaptureBuffer(inputGain: gain)
            gain.setPostProcessedPcmConsumer { [weak capture] samples, rate, channels in
                capture?.append(samples: samples, sampleRate: rate, channels: channels)
            }
            let api = Batv1APIStub()
            api.rejectFinal = rejectFinal
            let transmitter = BufferedAudioTransmitter(
                api: api, capture: capture, channelId: "channel-a", sessionId: "session-a",
                deviceId: "device-a", recordingAuthority: RecordingAuthorityMock()
            )
            await transmitter.prepare(generationId: "gain")
            try await transmitter.audioSessionDidActivate()
            capture.append(samples: [Int16](repeating: 1, count: 960), sampleRate: 48_000, channels: 1)
            let confirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "gain")
            XCTAssertTrue(confirmed)
            var samples = [Float](repeating: 2_000, count: 9_600)
            samples.withUnsafeMutableBufferPointer { buffer in
                gain.processFloatS16(channels: 1, frames: buffer.count) { _ in buffer.baseAddress! }
            }
            XCTAssertTrue(try transmitter.freezePendingCapture(generationId: "gain"))
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
            try await transmitter.authorize(leaseId: "lease-a", generationId: "gain")
            do {
                try await transmitter.finish(generationId: "gain")
                XCTAssertFalse(rejectFinal)
            } catch {
                XCTAssertTrue(rejectFinal)
            }
            XCTAssertEqual(gain.snapshot().autoTrimDb, rejectFinal ? 0 : 1)
            XCTAssertEqual(gain.snapshot().rmsDbfs!, -24.2884, accuracy: 0.001)
        }
    }

    @MainActor
    func testSlowHttpCatchesUpPreRollAndPreservesLiveSpeechThroughFinalMarker() async throws {
        for requestMs in [150, 250, 500] {
            let capture = Batv1CaptureBuffer()
            let api = Batv1APIStub()
            api.publishDelay = .milliseconds(requestMs)
            let transmitter = BufferedAudioTransmitter(
                api: api, capture: capture, channelId: "channel-a", sessionId: "session-a",
                deviceId: "device-a", recordingAuthority: RecordingAuthorityMock()
            )
            func append(_ index: Int) {
                capture.append(samples: [Int16](repeating: Int16(index), count: 960), sampleRate: 48_000, channels: 1)
            }
            await transmitter.prepare(generationId: "slow")
            try await transmitter.audioSessionDidActivate()
            append(0)
            let confirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "slow")
            XCTAssertTrue(confirmed)
            for index in 0..<200 { append(index) }
            try await transmitter.authorize(leaseId: "lease-a", generationId: "slow")
            // Continue recording at 50 frames/sec during real sender HTTP suspension.
            for index in 200..<250 {
                try await Task.sleep(for: .milliseconds(20))
                append(index)
            }
            let finishing = ContinuousClock.now
            try await transmitter.finish(generationId: "slow")
            XCTAssertLessThan(finishing.duration(to: .now), .seconds(6), "HTTP \(requestMs)ms must fit terminal budget")
            let chunks = api.publishedRequests.flatMap(\.chunks)
            XCTAssertEqual(chunks.map(\.sequence), Array(0..<250))
            for (index, chunk) in chunks.enumerated() {
                let pcm = try XCTUnwrap(Data(base64Encoded: chunk.payloadBase64))
                XCTAssertEqual(pcm.count, 1920)
                for offset in stride(from: 0, to: pcm.count, by: 2) {
                    XCTAssertEqual(Int(pcm[offset]) | Int(pcm[offset + 1]) << 8, index)
                }
            }
            XCTAssertTrue(api.publishedRequests.allSatisfy { $0.chunks.count <= 32 })
            XCTAssertEqual(api.publishedRequests.last?.finalSequence, 249)
            XCTAssertEqual(api.publishedRequests.filter { $0.finalSequence != nil }.count, 1)
        }
    }

    @MainActor
    func testFrozenRecordingStopsBeforeReadinessAndPublishesOnlyRetainedPcm() async throws {
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let api = Batv1APIStub()
        let transmitter = BufferedAudioTransmitter(
            api: api, capture: capture, channelId: "channel-a", sessionId: "session-a",
            deviceId: "device-a", recordingAuthority: authority
        )
        await transmitter.prepare(generationId: "short")
        try await transmitter.audioSessionDidActivate()
        capture.append(samples: [Int16](repeating: 1, count: 960), sampleRate: 48_000, channels: 1)
        let confirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: "short")
        XCTAssertTrue(confirmed)
        capture.append(samples: [Int16](repeating: 7, count: 1060), sampleRate: 48_000, channels: 1)
        XCTAssertTrue(try transmitter.freezePendingCapture(generationId: "short"))
        XCTAssertFalse(authority.isRecording)
        XCTAssertEqual(authority.stopCount, 1)
        capture.append(samples: [Int16](repeating: 9, count: 960), sampleRate: 48_000, channels: 1)
        XCTAssertTrue(api.publishedRequests.isEmpty)
        try await transmitter.authorize(leaseId: "lease-a", generationId: "short")
        capture.append(samples: [Int16](repeating: 11, count: 960), sampleRate: 48_000, channels: 1)
        try await transmitter.finish(generationId: "short")
        let chunks = api.publishedRequests.flatMap(\.chunks)
        XCTAssertEqual(chunks.map(\.sequence), [0, 1])
        let last = try XCTUnwrap(chunks.last)
        let tail = try XCTUnwrap(Data(base64Encoded: last.payloadBase64))
        let samples = try Batv1Pcm16LEConverter.floatSamples(from: tail)
        XCTAssertTrue(samples.prefix(100).allSatisfy { abs($0 - Float(7) / 32768) < 0.000001 })
        XCTAssertTrue(samples.dropFirst(100).allSatisfy { $0 == 0 })
        XCTAssertEqual(api.publishedRequests.last?.finalSequence, 1)
        XCTAssertEqual(authority.stopCount, 1)
        capture.arm(generationId: "new")
        XCTAssertFalse(capture.freeze(generationId: "short"))
        capture.append(samples: [Int16](repeating: 3, count: 960), sampleRate: 48_000, channels: 1)
        XCTAssertEqual(capture.frameCount, 1)
    }

    @MainActor
    func testReleaseHangoverIncludesDelayedTailAndFinalMarkerIsLast() async throws {
        let capture = Batv1CaptureBuffer()
        let authority = RecordingAuthorityMock()
        let api = Batv1APIStub()
        let transmitter = BufferedAudioTransmitter(
            api: api, capture: capture, channelId: "channel-a",
            sessionId: "session-a", deviceId: "device-a", recordingAuthority: authority
        )
        let frame = Array(repeating: Int16(5), count: batv1BytesPerFrame / 2)
        let generation = "tail-contract"
        await transmitter.prepare(generationId: generation)
        try await transmitter.audioSessionDidActivate()
        capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels)
        let captureConfirmed = await transmitter.awaitCaptureAndMarkCueBoundary(generationId: generation)
        XCTAssertTrue(captureConfirmed)
        try await transmitter.authorize(leaseId: "lease-a", generationId: generation)
        capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels)
        let tail50 = Task { try? await Task.sleep(for: .milliseconds(50)); capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels) }
        let tail150 = Task { try? await Task.sleep(for: .milliseconds(150)); capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels) }
        let excluded300 = Task { try? await Task.sleep(for: .milliseconds(300)); capture.append(samples: frame, sampleRate: batv1SampleRate, channels: batv1Channels) }
        let hangoverCompleted = await transmitter.performReleaseHangover(generationId: generation)
        XCTAssertTrue(hangoverCompleted)
        try await transmitter.finish(generationId: generation)
        _ = await tail50.value
        _ = await tail150.value
        _ = await excluded300.value

        let audio = api.publishedRequests.filter { !$0.chunks.isEmpty }.flatMap(\.chunks)
        XCTAssertEqual(audio.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(api.publishedRequests.last?.finalSequence, 2)
        XCTAssertEqual(transmitter.diagnostics.framesAcceptedAfterPttUp, 2)
        XCTAssertEqual(transmitter.diagnostics.lastAudioSequence, 2)
        XCTAssertEqual(transmitter.diagnostics.finalMarkerSequence, 2)
    }

    @MainActor
    func testRxLifecycleStressSerializesOneHundredGenerationsOnPersistentPlayer() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion,
                generationId: request.generationId,
                codec: "pcm16le",
                sampleRate: batv1SampleRate,
                channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds,
                firstAvailableSequence: 0,
                latestSequence: 0,
                nextSequence: 1,
                finalSequence: 0,
                bufferHeadExpired: false,
                timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())]
            )
        }
        let player = Batv1PcmPlayerMock()
        let receiver = BufferedAudioReceiver(api: api, sessionId: "session-a", player: player)
        receiver.audioSessionDidActivate()

        for index in 0..<100 {
            receiver.start(generationId: "rx-stress-\(index)", senderSessionId: "speaker")
            await receiver.awaitCurrentGenerationTermination()
        }
        await receiver.shutdownAndAwait()

        XCTAssertEqual(player.beginCount, 100)
        XCTAssertEqual(player.endCount, 100)
        XCTAssertEqual(player.enqueueCount, 100)
        XCTAssertEqual(player.shutdownCount, 1)
    }

    @MainActor
    func testDLateDrainCompletionCannotClearReplacementGeneration() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0, bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())])
        }
        var receiver: BufferedAudioReceiver!
        var terminals = 0
        var replacementPreserved = false
        receiver = BufferedAudioReceiver(api: api, sessionId: "local",
            onTimelineDrained: {
                terminals += 1
                if terminals == 1 {
                    receiver.start(generationId: "replacement", senderSessionId: "next-speaker")
                    await Task.yield()
                    replacementPreserved = receiver.diagnostics.generationId == "replacement"
                }
            }, player: Batv1PcmPlayerMock())
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "old", senderSessionId: "old-speaker")
        await receiver.awaitCurrentGenerationTermination()
        await receiver.awaitCurrentGenerationTermination()
        XCTAssertTrue(replacementPreserved)
        XCTAssertEqual(terminals, 2)
        await receiver.shutdownAndAwait()
    }

    @MainActor
    func testLateStopCompletionPreservesReplacementReceiverTask() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0, bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())])
        }
        var releaseOldDrain: CheckedContinuation<Void, Never>?
        var drainCount = 0
        var activities: [(String?, Bool)] = []
        let player = Batv1PcmPlayerMock()
        let receiver = BufferedAudioReceiver(api: api, sessionId: "local",
            onActivity: { activities.append(($0, $1)) },
            onTimelineDrained: {
                drainCount += 1
                if drainCount == 1 { await withCheckedContinuation { releaseOldDrain = $0 } }
            }, player: player)
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "old", senderSessionId: "old-speaker")
        for _ in 0..<100 where releaseOldDrain == nil { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(releaseOldDrain)
        receiver.audioSessionDidDeactivate()
        var stopEntered = false
        let stopping = Task { @MainActor in
            stopEntered = true
            await receiver.stopAndAwait()
        }
        while !stopEntered { await Task.yield() }
        receiver.start(generationId: "replacement", senderSessionId: "next-speaker")
        releaseOldDrain?.resume()
        await stopping.value

        XCTAssertEqual(receiver.diagnostics.generationId, "replacement")
        XCTAssertFalse(activities.contains { $0.0 == "next-speaker" && !$0.1 },
            "The obsolete stop must not clear the replacement speaker's activity")
        receiver.audioSessionDidActivate()
        await receiver.awaitCurrentGenerationTermination()
        XCTAssertEqual(drainCount, 2, "The replacement Task must remain owned and awaitable")
        XCTAssertEqual(player.enqueueCount, 2)
        await receiver.shutdownAndAwait()
    }

    @MainActor
    func testStopActivityCallbackCanStartReplacementWithoutLosingItsState() async {
        for awaitStop in [false, true] {
            var receiver: BufferedAudioReceiver!
            receiver = BufferedAudioReceiver(api: Batv1APIStub(), sessionId: "local",
                onActivity: { sender, active in
                    if sender == "old-speaker", !active {
                        receiver.start(generationId: "replacement", senderSessionId: "next-speaker")
                    }
                }, player: Batv1PcmPlayerMock())
            // No Apple audio activation: both tasks wait without fetching PCM.
            receiver.start(generationId: "old", senderSessionId: "old-speaker")
            if awaitStop { await receiver.stopAndAwait() } else { receiver.stop() }
            XCTAssertEqual(receiver.diagnostics.generationId, "replacement")
            await receiver.shutdownAndAwait()
        }
    }

    @MainActor
    func testShutdownRejectsStartsWhilePreviousDrainIsFinishing() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0, bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())])
        }
        var releaseOldDrain: CheckedContinuation<Void, Never>?
        var drainCount = 0
        let player = Batv1PcmPlayerMock()
        let receiver = BufferedAudioReceiver(api: api, sessionId: "local", onTimelineDrained: {
            drainCount += 1
            if drainCount == 1 { await withCheckedContinuation { releaseOldDrain = $0 } }
        }, player: player)
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "old", senderSessionId: "old-speaker")
        for _ in 0..<100 where releaseOldDrain == nil { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(releaseOldDrain)
        receiver.audioSessionDidDeactivate()
        var shutdownEntered = false
        let shuttingDown = Task { @MainActor in
            shutdownEntered = true
            await receiver.shutdownAndAwait()
        }
        while !shutdownEntered { await Task.yield() }
        receiver.start(generationId: "during-shutdown", senderSessionId: "next-speaker")
        releaseOldDrain?.resume()
        await shuttingDown.value
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "after-shutdown", senderSessionId: "next-speaker")
        await receiver.awaitCurrentGenerationTermination()
        XCTAssertEqual(player.beginCount, 1, "A retired receiver cannot restart its audio graph")
        XCTAssertEqual(player.enqueueCount, 1)
        XCTAssertEqual(player.shutdownCount, 1)
        XCTAssertNil(receiver.diagnostics.generationId)
    }

    func testTerminalReceiveDiagnosticJSONSeparatesFailureAndUnknownOutput() throws {
        let keys: Set<String> = ["capturedAt", "build", "outcome", "terminalReason", "playbackCursor",
            "latestSequence", "finalSequence", "missingSequenceCount", "duplicateSequenceCount",
            "playerDrainCompletedAt", "endCueAt", "lastEnqueueOutput", "lastCompletionOutput",
            "engineStartFailures", "lastErrorCode", "inputRmsDbfs", "inputPeakDbfs"]
        for failed in [false, true] {
            let snapshot = BufferedAudioRxSnapshot(
                receive: BufferedAudioRxDiagnostics(generationId: "private-generation",
                    playbackCursor: 42, latestSequence: 41, timelineLost: failed, finalSequence: 41,
                    playerDrainCompletedAt: failed ? nil : Date(timeIntervalSince1970: 1),
                    terminalReason: failed ? "receive_failed" : "final_sequence"),
                playback: Batv1PlaybackDiagnostics(generationToken: 123))
            let data = try JSONSerialization.data(withJSONObject: snapshot.fieldDiagnostic(build: "test-build"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(json.keys), keys)
            XCTAssertEqual(json["outcome"] as? String, failed ? "failed" : "completed")
            XCTAssertEqual(json["playbackCursor"] as? Int, 42)
            XCTAssertEqual(json["engineStartFailures"] as? Int, 0)
            XCTAssertTrue(json["inputRmsDbfs"] is NSNull)
            XCTAssertTrue(json["lastCompletionOutput"] is NSNull)
            if failed { XCTAssertTrue(json["playerDrainCompletedAt"] is NSNull) }
            else { XCTAssertEqual(json["playerDrainCompletedAt"] as? String, "1970-01-01T00:00:01Z") }
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-generation"))
            XCTAssertNil(json["generationToken"])
        }
    }

    @MainActor
    func testTerminalReceiveSnapshotSurvivesReplacementAndShutdownWithoutIdentifiers() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0, bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())])
        }
        var retained: BufferedAudioRxSnapshot?
        let player = Batv1PcmPlayerMock()
        player.playbackDiagnostics.inputRmsDbfs = -24
        player.playbackDiagnostics.inputPeakDbfs = -12
        let receiver = BufferedAudioReceiver(api: api, sessionId: "private-session",
            onTerminalSnapshot: { retained = $0 }, player: player)
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "private-generation", senderSessionId: "private-sender")
        await receiver.awaitCurrentGenerationTermination()
        let completed = retained
        XCTAssertEqual(completed?.receive.terminalReason, "final_sequence")
        XCTAssertEqual(completed?.receive.playbackCursor, 1)
        XCTAssertNotNil(completed?.receive.playerDrainCompletedAt)
        XCTAssertNotNil(completed?.receive.endCueAt)
        XCTAssertEqual(completed?.playback.inputRmsDbfs, -24)
        XCTAssertEqual(completed?.playback.inputPeakDbfs, -12)
        XCTAssertNil(completed?.receive.generationId)
        XCTAssertNil(completed?.playback.generationToken)

        // A pending replacement cancelled before starting must not overwrite terminal evidence.
        receiver.start(generationId: "cancelled-replacement", senderSessionId: "next-sender")
        await receiver.shutdownAndAwait()
        XCTAssertEqual(retained, completed)
        let replacement = BufferedAudioReceiver(api: api, sessionId: "next-runtime",
            onTerminalSnapshot: { retained = $0 }, player: Batv1PcmPlayerMock())
        await replacement.shutdownAndAwait()
        XCTAssertEqual(retained, completed)
    }

    @MainActor
    func testReceiverDrainsFinalSequenceWhenControlEndArrivesFirst() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0,
                bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())]
            )
        }
        let player = Batv1PcmPlayerMock()
        let receiver = BufferedAudioReceiver(api: api, sessionId: "session-a", player: player)
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "end-first", senderSessionId: "speaker")
        receiver.noteControlEnd(at: Date(timeIntervalSince1970: 1))
        await receiver.awaitCurrentGenerationTermination()

        XCTAssertEqual(receiver.diagnostics.finalSequence, 0)
        XCTAssertEqual(receiver.diagnostics.playbackCursor, 1)
        XCTAssertNotNil(receiver.diagnostics.finalSequenceObservedAt)
        XCTAssertNotNil(receiver.diagnostics.finalFrameWrittenAt)
        XCTAssertNotNil(receiver.diagnostics.playerDrainCompletedAt)
        XCTAssertNotNil(receiver.diagnostics.endCueAt)
        XCTAssertEqual(receiver.diagnostics.controlEndReceivedAt, Date(timeIntervalSince1970: 1))
    }

    @MainActor
    func testExpiredTimelineHeadIsRetainedInFieldDiagnostic() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 1368,
                latestSequence: 1667, nextSequence: 1368, finalSequence: 1667,
                bufferHeadExpired: true, timelineEnded: false, chunks: []
            )
        }
        let player = Batv1PcmPlayerMock()
        var retained: BufferedAudioRxSnapshot?
        let receiver = BufferedAudioReceiver(
            api: api, sessionId: "session-a", onFailure: { _ in },
            onTerminalSnapshot: { retained = $0 }, player: player
        )
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "expired-head", senderSessionId: "speaker")
        await receiver.awaitCurrentGenerationTermination()
        let diagnostic = retained?.fieldDiagnostic(build: "test")
        XCTAssertEqual(diagnostic?["terminalReason"] as? String, "timeline_head_expired")
        XCTAssertEqual(retained?.receive.bufferHeadExpired, true)
        XCTAssertEqual(diagnostic?["outcome"] as? String, "failed")
        XCTAssertEqual(diagnostic?["playbackCursor"] as? Int, 0)
        XCTAssertNil(retained?.receive.playerDrainCompletedAt)
        XCTAssertEqual(player.endCount, 1)
    }

    @MainActor
    func testReceiverDrainFailureIsNotPublishedAsSuccessfulPlayback() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0,
                bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())]
            )
        }
        let player = Batv1PcmPlayerMock()
        player.drainError = BufferedAudioError.playbackEngineUnavailable
        var failureReported = false
        var retained: BufferedAudioRxSnapshot?
        let receiver = BufferedAudioReceiver(
            api: api, sessionId: "session-a", onFailure: { _ in failureReported = true },
            onTerminalSnapshot: { retained = $0 }, player: player
        )
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "failed-engine", senderSessionId: "speaker")
        await receiver.awaitCurrentGenerationTermination()
        XCTAssertEqual(retained?.receive.terminalReason, "playback_engine_unavailable")
        XCTAssertTrue(retained?.receive.timelineLost == true)
        XCTAssertNil(retained?.receive.playerDrainCompletedAt)
        XCTAssertNil(retained?.receive.generationId)
        XCTAssertTrue(failureReported)
        XCTAssertTrue(receiver.diagnostics.timelineLost)
        XCTAssertNil(receiver.diagnostics.playerDrainCompletedAt)
        XCTAssertEqual(receiver.diagnostics.terminalReason, "playback_engine_unavailable")
        XCTAssertEqual(player.endCount, 1)
    }


    @MainActor
    func testReceiverWaitsForQueuedPlaybackBeforeFetchingMoreFrames() async throws {
        let api = Batv1APIStub()
        let payload = Data(count: batv1BytesPerFrame).base64EncodedString()
        api.subscribeHandler = { request in
            let first = request.nextSequence == 0
            return Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 76, nextSequence: first ? 76 : 77, finalSequence: first ? nil : 76,
                bufferHeadExpired: false, timelineEnded: !first,
                chunks: (first ? Array(0..<76) : [76]).map { Batv1Chunk(sequence: $0, payloadBase64: payload) }
            )
        }
        let player = Batv1PcmPlayerMock()
        player.holdFrames = true
        let receiver = BufferedAudioReceiver(api: api, sessionId: "session-a", player: player)
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "backpressure", senderSessionId: "speaker")
        for _ in 0..<100 where player.enqueueCount < 76 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(player.enqueueCount, 76, "Do not fetch the next batch while playback is behind")
        player.completeHeldFrames()
        await receiver.awaitCurrentGenerationTermination()
        XCTAssertEqual(player.enqueueCount, 77)
        XCTAssertFalse(receiver.diagnostics.timelineLost)
        XCTAssertNotNil(receiver.diagnostics.playerDrainCompletedAt)
    }

    @MainActor
    func testReceiverFinalSequenceRemainsTruthWhenControlEndArrivesAfterDrain() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: 0,
                bufferHeadExpired: false, timelineEnded: true,
                chunks: [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())]
            )
        }
        let receiver = BufferedAudioReceiver(api: api, sessionId: "session-a", player: Batv1PcmPlayerMock())
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "final-first", senderSessionId: "speaker")
        await receiver.awaitCurrentGenerationTermination()
        receiver.noteControlEnd(at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(receiver.diagnostics.finalSequence, 0)
        XCTAssertEqual(receiver.diagnostics.playbackCursor, 1)
        XCTAssertEqual(receiver.diagnostics.controlEndReceivedAt, Date(timeIntervalSince1970: 2))
    }

    func testC4Canonical48kMonoCaptureRemainsAccepted() async {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: "canonical-48k")
        capture.append(
            samples: Array(repeating: Int16(1_024), count: 48_000 * 20 / 1_000),
            sampleRate: 48_000,
            channels: 1
        )
        let captureConfirmed = await capture.awaitCapture(timeoutMilliseconds: 750)
        XCTAssertTrue(captureConfirmed)
        XCTAssertEqual(capture.frameCount, 1)
        XCTAssertEqual(capture.callbackDiagnostics.unsupported, 0)
        XCTAssertEqual(capture.callbackDiagnostics.normalized, 0)
    }

    func testBluetoothVoiceRatesProduceCanonicalFramesAcrossCallbacks() {
        for sourceRate in [8_000, 16_000, 24_000, 32_000, 44_100] {
            let capture = Batv1CaptureBuffer()
            capture.arm(generationId: "bluetooth-\(sourceRate)")
            for _ in 0..<10 {
                capture.append(samples: Array(repeating: Int16(1_024), count: sourceRate / 100),
                    sampleRate: sourceRate, channels: 1)
            }
            XCTAssertEqual(capture.callbackDiagnostics.count, 10)
            XCTAssertEqual(capture.callbackDiagnostics.sampleRate, sourceRate)
            XCTAssertEqual(capture.callbackDiagnostics.unsupported, 0)
            XCTAssertGreaterThan(capture.callbackDiagnostics.normalized, 0)
            XCTAssertGreaterThanOrEqual(capture.frameCount, 4, "Rate \(sourceRate)")
            XCTAssertLessThanOrEqual(capture.frameCount, 5, "Rate \(sourceRate)")
            XCTAssertNotNil(capture.firstPcmTimestamp)
        }
    }

    func testCaptureStillRejectsInvalidFormats() {
        for (rate, channels) in [(0, 1), (96_000, 1), (16_000, 2)] {
            let capture = Batv1CaptureBuffer()
            capture.arm(generationId: "invalid")
            capture.append(samples: [1, 2, 3], sampleRate: rate, channels: channels)
            XCTAssertEqual(capture.frameCount, 0)
            XCTAssertEqual(capture.callbackDiagnostics.unsupported, 3)
        }
    }

    func testBluetoothConversionDoesNotCarrySpeechAcrossCueBoundary() {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: "bluetooth-cue")
        capture.append(samples: Array(repeating: 10_000, count: 160), sampleRate: 16_000, channels: 1)
        capture.markCueBoundary()
        for _ in 0..<4 {
            capture.append(samples: Array(repeating: 0, count: 160), sampleRate: 16_000, channels: 1)
        }
        let collected = BluetoothFrameCollector()
        _ = capture.startForwarding { collected.append($0) }
        XCTAssertGreaterThan(capture.frameCount, 0)
        XCTAssertTrue(collected.frames.allSatisfy { $0.allSatisfy { $0 == 0 } })
        capture.discard()
        capture.arm(generationId: "next")
        XCTAssertEqual(capture.frameCount, 0)
        XCTAssertEqual(capture.callbackDiagnostics.normalized, 0)
    }

    func testC7ZeroCallbackCannotBeMisreportedAsCaptureConfirmed() async {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: "zero-callback")
        let confirmed = await capture.awaitCapture(timeoutMilliseconds: 1)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(capture.callbackDiagnostics.count, 0)
        XCTAssertEqual(capture.frameCount, 0)
    }

    @MainActor
    func testReceiverMissingFinalUsesControlEndFloorTerminalAndStableLatestSequence() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: 0, nextSequence: 1, finalSequence: nil,
                bufferHeadExpired: false, timelineEnded: false,
                chunks: request.nextSequence == 0
                    ? [Batv1Chunk(sequence: 0, payloadBase64: Data(count: batv1BytesPerFrame).base64EncodedString())]
                    : []
            )
        }
        api.floorStatusHandler = {
            FloorResponse(
                outcome: .available, owner: nil, leaseId: nil, acquiredAt: nil,
                leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false
            )
        }
        var uptime: TimeInterval = 0
        let receiver = BufferedAudioReceiver(
            api: api, sessionId: "receiver", player: Batv1PcmPlayerMock(),
            monotonicNow: { uptime += 0.25; return uptime }
        )
        receiver.audioSessionDidActivate()
        receiver.start(
            generationId: "missing-final", senderSessionId: "speaker-session",
            leaseId: "lease-a", senderUserId: "staff-a"
        )
        receiver.noteControlEnd()
        await receiver.awaitCurrentGenerationTermination()

        XCTAssertNil(receiver.diagnostics.finalSequence)
        XCTAssertEqual(receiver.diagnostics.playbackCursor, 1)
        XCTAssertEqual(receiver.diagnostics.terminalReason, "missing_final_floor_terminal_stable")
        XCTAssertNotNil(receiver.diagnostics.missingFinalFallbackEligibleAt)
        XCTAssertNotNil(receiver.diagnostics.missingFinalFallbackCompletedAt)
        XCTAssertNotNil(receiver.diagnostics.playerDrainCompletedAt)
    }

    @MainActor
    func testReceiverMissingFinalDoesNotCloseWhileSenderStillOwnsFloor() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "pcm16le", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: -1, nextSequence: 0, finalSequence: nil,
                bufferHeadExpired: false, timelineEnded: false, chunks: []
            )
        }
        api.floorStatusHandler = {
            FloorResponse(
                outcome: .busy, owner: FloorOwner(id: "staff-a", name: "Staff A"), leaseId: "lease-a",
                acquiredAt: nil, leaseExpiresAt: nil, maxTxExpiresAt: nil, lastRenewedAt: nil, isOwner: false
            )
        }
        var uptime: TimeInterval = 0
        let receiver = BufferedAudioReceiver(
            api: api, sessionId: "receiver", player: Batv1PcmPlayerMock(),
            monotonicNow: { uptime += 0.5; return uptime }
        )
        receiver.audioSessionDidActivate()
        receiver.start(
            generationId: "still-owned", senderSessionId: "speaker-session",
            leaseId: "lease-a", senderUserId: "staff-a"
        )
        receiver.noteControlEnd()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(receiver.diagnostics.missingFinalFallbackCompletedAt)
        XCTAssertNil(receiver.diagnostics.playerDrainCompletedAt)
        await receiver.stopAndAwait()
    }

    @MainActor
    func testReceiverFatalTerminalPathClearsActivityAndGeneration() async {
        let api = Batv1APIStub()
        api.subscribeHandler = { request in
            Batv1SubscribeResponse(
                protocolVersion: batv1ProtocolVersion, generationId: request.generationId,
                codec: "unsupported", sampleRate: batv1SampleRate, channels: batv1Channels,
                frameDurationMs: batv1FrameDurationMilliseconds, firstAvailableSequence: 0,
                latestSequence: -1, nextSequence: 0, finalSequence: nil,
                bufferHeadExpired: false, timelineEnded: false, chunks: []
            )
        }
        var activity: [Bool] = []
        var terminalCallbacks = 0
        let receiver = BufferedAudioReceiver(
            api: api,
            sessionId: "receiver",
            onActivity: { _, active in activity.append(active) },
            onTimelineDrained: { terminalCallbacks += 1 },
            player: Batv1PcmPlayerMock()
        )
        receiver.audioSessionDidActivate()
        receiver.start(generationId: "fatal", senderSessionId: "speaker")
        await receiver.awaitCurrentGenerationTermination()

        XCTAssertEqual(activity, [true, false])
        XCTAssertEqual(terminalCallbacks, 1)
        XCTAssertNil(receiver.diagnostics.generationId)
    }

    @MainActor
    func testOldGenerationCompletionIsFencedAfterReplacement() {
        let fence = Batv1GenerationCompletionFence()
        fence.begin(1)
        XCTAssertTrue(fence.accepts(1))
        fence.begin(2)
        XCTAssertFalse(fence.accepts(1))
        XCTAssertTrue(fence.accepts(2))
        fence.end(1)
        XCTAssertTrue(fence.accepts(2))
        fence.end(2)
        XCTAssertNil(fence.activeToken)
    }

    func testPersistentBreadcrumbCapacityIsBoundedToSixtyFour() {
        let store = Batv1CrashBreadcrumbStore.shared
        store.startRun(build: "test")
        for index in 0..<100 {
            store.record(role: "TX", stage: "STRESS_\(index)", generationId: "generation-\(index)")
        }
        XCTAssertEqual(store.snapshot().count, 64)
        XCTAssertEqual(store.snapshot().last?.stage, "STRESS_99")
    }
}

final class Batv1BreadcrumbLifecycleTests: XCTestCase {
    func testPollingWindowIsBoundedAndRestartsAfterReload() {
        let defaults = isolatedDefaults()
        let store = Batv1CrashBreadcrumbStore(defaults: defaults)
        store.startRun(build: "test")
        for index in 0..<100 {
            store.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "g\(index)")
        }
        XCTAssertEqual(store.snapshot().count, 64)
        for _ in 0..<2 { store.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "g0") }
        XCTAssertEqual(store.snapshot().filter { $0.generationToken == "g0" }.count, 1)
        let restored = Batv1CrashBreadcrumbStore(defaults: defaults)
        restored.startRun(build: "next")
        restored.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "g0")
        XCTAssertEqual(restored.snapshot().last?.stage, "RX_SUBSCRIBE_BEGIN")
        XCTAssertEqual(restored.snapshot().last?.build, "next")
        XCTAssertEqual(restored.snapshot().count, 64)
    }

    func testPollingDoesNotEvictBackgroundAndFailureEvidenceAcrossReload() {
        let defaults = isolatedDefaults()
        let store = Batv1CrashBreadcrumbStore(defaults: defaults)
        store.startRun(build: "test")
        store.recordAppLifecycle("background")
        store.record(role: "APP", stage: "RUNTIME_CONNECT_FAILED", resultClass: "LISTENING_RETAINED")
        for _ in 0..<200 {
            store.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "generation-a")
            store.record(role: "RX", stage: "RX_SUBSCRIBE_END", generationId: "generation-a")
        }
        let restored = Batv1CrashBreadcrumbStore(defaults: defaults)
        restored.startRun(build: "next")
        XCTAssertTrue(restored.snapshot().contains { $0.stage == "APP_BACKGROUND" })
        XCTAssertTrue(restored.snapshot().contains { $0.stage == "RUNTIME_CONNECT_FAILED" })
        XCTAssertEqual(restored.snapshot().filter { $0.stage == "RX_SUBSCRIBE_BEGIN" }.count, 1)
        XCTAssertEqual(restored.snapshot().filter { $0.stage == "RX_SUBSCRIBE_END" }.count, 1)
    }

    func testPollingCoalescingSeparatesFullGenerationsAndPreservesErrors() {
        let store = Batv1CrashBreadcrumbStore(defaults: isolatedDefaults())
        store.startRun(build: "test")
        for generation in ["samepref-one", "samepref-two"] {
            for _ in 0..<20 {
                store.record(role: "RX", stage: "RX_SUBSCRIBE_END", generationId: generation)
            }
        }
        store.record(role: "RX", stage: "RX_SUBSCRIBE_END", generationId: "samepref-two", resultClass: "ERROR")
        XCTAssertEqual(store.snapshot().filter { $0.stage == "RX_SUBSCRIBE_END" }.count, 3)
        XCTAssertEqual(store.snapshot().last?.resultClass, "ERROR")
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "koeon.breadcrumb.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testLegacyFlagsDoNotProveCleanExitOrUnexpectedTermination() {
        for clean in [false, true] {
            let defaults = isolatedDefaults()
            defaults.set(true, forKey: "batv1.runKnown")
            defaults.set(clean, forKey: "batv1.cleanExit")
            let store = Batv1CrashBreadcrumbStore(defaults: defaults)
            store.startRun(build: "test")
            XCTAssertEqual(store.previousRunTermination, "UNKNOWN",
                "A lifecycle flag without a termination report cannot identify the cause")
        }
    }

    func testBackgroundTransitionIsNotEvidenceOfCleanProcessExit() {
        let defaults = isolatedDefaults()
        let before = Batv1CrashBreadcrumbStore(defaults: defaults)
        before.startRun(build: "before")
        before.recordAppLifecycle("background")
        let after = Batv1CrashBreadcrumbStore(defaults: defaults)
        after.startRun(build: "after")
        XCTAssertEqual(after.previousRunTermination, "UNKNOWN")
        XCTAssertEqual(after.previousRunLastLifecycleState, "BACKGROUND")
        XCTAssertEqual(before.snapshot().last?.stage, "APP_BACKGROUND")
    }

    func testBackgroundAudioDoesNotChangeLastObservedAppLifecycle() {
        let defaults = isolatedDefaults()
        let before = Batv1CrashBreadcrumbStore(defaults: defaults)
        before.startRun(build: "before")
        before.recordAppLifecycle("background")
        for _ in 0..<100 { before.record(role: "RX", stage: "RX_SUBSCRIBE_END") }
        let after = Batv1CrashBreadcrumbStore(defaults: defaults)
        after.startRun(build: "after")
        XCTAssertEqual(after.previousRunTermination, "UNKNOWN")
        XCTAssertEqual(after.previousRunLastLifecycleState, "BACKGROUND",
            "Audio callbacks and bounded breadcrumb eviction do not imply a foreground transition")
    }

    func testForegroundResumeUpdatesObservedLifecycleWithoutInferringTermination() {
        let defaults = isolatedDefaults()
        let before = Batv1CrashBreadcrumbStore(defaults: defaults)
        before.startRun(build: "before")
        before.recordAppLifecycle("background")
        before.recordAppLifecycle("inactive")
        before.recordAppLifecycle("active")
        let after = Batv1CrashBreadcrumbStore(defaults: defaults)
        after.startRun(build: "after")
        XCTAssertEqual(after.previousRunTermination, "UNKNOWN")
        XCTAssertEqual(after.previousRunLastLifecycleState, "ACTIVE")
    }

    func testStartupAndUnknownLifecycleAreReportedWithoutInventingACause() {
        let defaults = isolatedDefaults()
        let first = Batv1CrashBreadcrumbStore(defaults: defaults)
        first.startRun(build: "first")
        XCTAssertEqual(first.previousRunLastLifecycleState, "UNKNOWN")
        let second = Batv1CrashBreadcrumbStore(defaults: defaults)
        second.startRun(build: "second")
        XCTAssertEqual(second.previousRunLastLifecycleState, "STARTING")
        second.recordAppLifecycle("unrecognized-private-value")
        let third = Batv1CrashBreadcrumbStore(defaults: defaults)
        third.startRun(build: "third")
        XCTAssertEqual(third.previousRunLastLifecycleState, "UNKNOWN")
        XCTAssertFalse(third.snapshot().contains { $0.stage.contains("private") })
        XCTAssertEqual(third.previousRunTermination, "UNKNOWN")
    }
}

final class FieldLabSafetyTests: XCTestCase {
    func testVolumeProbeNeverTriggersPttIncludingMinMaxNoChange() {
        for mode in IOSVolumeProbeMode.allCases {
            XCTAssertFalse(iosVolumeProbeCanTriggerPtt(mode: mode, foreground: true, joined: true, outputVolumeChanged: true))
            XCTAssertFalse(iosVolumeProbeCanTriggerPtt(mode: mode, foreground: true, joined: true, outputVolumeChanged: false))
            XCTAssertFalse(iosVolumeProbeCanTriggerPtt(mode: mode, foreground: false, joined: true, outputVolumeChanged: true))
        }
    }

    func testRapidIsolationModesHaveStablePersistedRawValues() {
        XCTAssertEqual(Set(AppTxPath.allCases.map(\.rawValue)), ["PREARM_FAST", "POST_BEGIN_CONTROL"])
        XCTAssertEqual(Set(RxReadyPolicy.allCases.map(\.rawValue)), ["OFF", "FAST_250", "ADAPTIVE"])
        XCTAssertEqual(Set(RestorePath.allCases.map(\.rawValue)), ["FAST_RESUME", "LEGACY_SERIAL"])
        XCTAssertEqual(Set(RxStartCueMode.allCases.map(\.rawValue)), ["ON", "OFF"])
    }
}

@MainActor
private final class ControlMock: PttControlPublishing {
    let events: EventLog
    init(events: EventLog) { self.events = events }
    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics {
        await events.append("control:start")
        return .init()
    }
    func publishEnd(leaseId: String) async throws { await events.append("control:end") }
}

@MainActor
private final class CapturingReadyControl: PttControlPublishing {
    let events: EventLog
    private(set) var maximumWaitMilliseconds: Int?
    init(events: EventLog) { self.events = events }
    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics {
        await events.append("control:start")
        return .init()
    }
    func publishEnd(leaseId: String) async throws { await events.append("control:end") }
    func awaitRxReady(leaseId: String, maximumWaitMilliseconds: Int?) async -> PttRxReadyWaitResult {
        self.maximumWaitMilliseconds = maximumWaitMilliseconds
        return PttRxReadyWaitResult(
            expectedCount: 1, receivedCount: 0, lateCount: 0,
            waitMilliseconds: maximumWaitMilliseconds ?? 0, timedOut: true,
            firstReadyAt: nil, allReadyAt: nil
        )
    }
}

@MainActor
private final class BlockingReadyControl: PttControlPublishing {
    let events: EventLog
    private var continuation: CheckedContinuation<PttRxReadyWaitResult, Never>?
    private(set) var isWaiting = false
    func ack() {
        isWaiting = false
        continuation?.resume(returning: PttRxReadyWaitResult(
            expectedCount: 1, receivedCount: 1, lateCount: 0, waitMilliseconds: 2_800,
            timedOut: false, firstReadyAt: Date(), allReadyAt: Date()
        ))
        continuation = nil
    }
    init(events: EventLog) { self.events = events }
    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics {
        await events.append("control:start")
        return .init()
    }
    func publishEnd(leaseId: String) async throws { await events.append("control:end") }
    func prepareRxReady(leaseId: String, expectedSessionIds: [String]) async {}
    func awaitRxReady(leaseId: String, maximumWaitMilliseconds: Int? = nil) async -> PttRxReadyWaitResult {
        isWaiting = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func cancelRxReady(leaseId: String) async {
        isWaiting = false
        continuation?.resume(returning: PttRxReadyWaitResult(
            expectedCount: 1, receivedCount: 0, lateCount: 0, waitMilliseconds: 1,
            timedOut: false, firstReadyAt: nil, allReadyAt: nil, cancelled: true
        ))
        continuation = nil
    }
}

private actor EventLog {
    private var events: [String] = []
    func append(_ value: String) { events.append(value) }
    func values() -> [String] { events }
}

@MainActor
private final class BufferedAudioMock: BufferedAudioTransmitting {
    let events: EventLog
    var diagnostics = BufferedAudioTxDiagnostics()
    var frozen = false
    func freezePendingCapture(generationId: String) throws -> Bool {
        guard diagnostics.generationId == generationId, diagnostics.captureConfirmed else { return false }
        frozen = true
        return true
    }
    let failFinish: Bool
    let failCapture: Bool
    let failActivation: Bool
    init(events: EventLog, failFinish: Bool = false, failCapture: Bool = false, failActivation: Bool = false) {
        self.events = events; self.failFinish = failFinish; self.failCapture = failCapture; self.failActivation = failActivation
    }
    func prepare(generationId: String) async {
        diagnostics.generationId = generationId
        Task { await events.append("buffer:prepare") }
    }
    func audioSessionDidActivate() async throws {
        if failActivation { throw MockError.expected }
        diagnostics.captureArmed = true
        await events.append("buffer:capture-start")
    }
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool {
        if failCapture { return false }
        await events.append("buffer:capture-confirmed")
        diagnostics.captureConfirmed = true
        return true
    }
    func authorize(leaseId: String, generationId: String) async throws {
        await events.append("buffer:authorize")
    }
    func performReleaseHangover(generationId: String) async -> Bool {
        await events.append("buffer:hangover")
        return true
    }
    func finish(generationId: String) async throws {
        await events.append("buffer:finish")
        if failFinish { throw MockError.expected }
    }
    func discard(generationId: String) async { await events.append("buffer:discard") }
}

@MainActor
private final class BlockingFinishBufferedAudioMock: BufferedAudioTransmitting {
    let events: EventLog
    var diagnostics = BufferedAudioTxDiagnostics()
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var finishStarted = false
    init(events: EventLog) { self.events = events }
    func prepare(generationId: String) async { diagnostics.generationId = generationId }
    func audioSessionDidActivate() async throws { diagnostics.captureArmed = true }
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool { diagnostics.captureConfirmed = true; return true }
    func authorize(leaseId: String, generationId: String) async throws {}
    func performReleaseHangover(generationId: String) async -> Bool { true }
    func finish(generationId: String) async throws {
        finishStarted = true
        await events.append("buffer:finish")
        await withCheckedContinuation { finishContinuation = $0 }
    }
    func completeFinish() { finishContinuation?.resume(); finishContinuation = nil }
    func discard(generationId: String) async { finishContinuation?.resume(); finishContinuation = nil }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [PTTSnapshot] = []
    func append(_ value: PTTSnapshot) { lock.withLock { snapshots.append(value) } }
}

private enum MockError: Error { case expected }

@MainActor
private final class RecordingAuthorityMock: Batv1LocalRecordingAuthority {
    private(set) var isRecording = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() throws {
        guard !isRecording else { return }
        isRecording = true
        startCount += 1
    }
    func stop() throws {
        guard isRecording else { return }
        isRecording = false
        stopCount += 1
    }
}

@MainActor
private final class Batv1PcmPlayerMock: IOSBatv1PcmPlaying {
    var playbackDiagnostics = Batv1PlaybackDiagnostics()
    var drainError: Error?
    var holdFrames = false
    private(set) var pendingFrames = 0
    private(set) var completedFrames = 0
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var enqueueCount = 0
    private(set) var shutdownCount = 0
    private var activeToken: Int?

    func beginGeneration(token: Int) throws { activeToken = token; playbackDiagnostics.generationToken = token; beginCount += 1 }
    func setRate(_ rate: Float) {}
    func enqueue(_ data: Data, generationToken: Int) throws {
        guard activeToken == generationToken else { throw BufferedAudioError.generationMismatch }
        enqueueCount += 1
        if holdFrames { pendingFrames += 1 } else { completedFrames += 1 }
    }
    func completeHeldFrames() {
        completedFrames += pendingFrames
        pendingFrames = 0
        holdFrames = false
    }
    func drain(generationToken: Int) async throws { if let drainError { throw drainError } }
    func endGeneration(token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
        endCount += 1
    }
    func resumeIfNeeded() throws {}
    func shutdown() { shutdownCount += 1 }
}

private final class Batv1APIStub: KOEONAPIClientProtocol, @unchecked Sendable {
    var publishDelay: Duration = .zero
    var rejectFinal = false
    var subscribeHandler: ((Batv1SubscribeRequest) throws -> Batv1SubscribeResponse)?
    var floorStatusHandler: (() throws -> FloorResponse)?
    private(set) var publishedRequests: [Batv1PublishRequest] = []
    func fixture() async throws -> FixtureResponse { throw MockError.expected }
    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse { throw MockError.expected }
    func me() async throws -> MeResponse { throw MockError.expected }
    func join(_ request: JoinRequest) async throws -> JoinResponse { throw MockError.expected }
    func resume(_ request: ResumeRequest) async throws -> JoinResponse { throw MockError.expected }
    func leave(sessionId: String) async throws { throw MockError.expected }
    func acquireFloor(sessionId: String) async throws -> FloorResponse { throw MockError.expected }
    func renewFloor(sessionId: String, leaseId: String) async throws -> FloorResponse { throw MockError.expected }
    func releaseFloor(sessionId: String, leaseId: String) async throws -> FloorReleaseResponse { throw MockError.expected }
    func floorStatus(sessionId: String) async throws -> FloorResponse {
        guard let floorStatusHandler else { throw MockError.expected }
        return try floorStatusHandler()
    }
    func registerPttToken(sessionId: String, channelId: String, token: String) async throws { throw MockError.expected }
    func unregisterPttToken(sessionId: String) async throws { throw MockError.expected }
    func publishBufferedAudio(_ request: Batv1PublishRequest) async throws -> Batv1PublishResponse {
        publishedRequests.append(request)
        if publishDelay > .zero { try await Task.sleep(for: publishDelay) }
        if rejectFinal, request.finalSequence != nil { throw MockError.expected }
        return Batv1PublishResponse(outcome: "accepted", acceptedChunks: request.chunks.count, latestSequence: request.chunks.last?.sequence ?? -1)
    }
    func subscribeBufferedAudio(_ request: Batv1SubscribeRequest) async throws -> Batv1SubscribeResponse {
        guard let subscribeHandler else { throw MockError.expected }
        return try subscribeHandler(request)
    }
    func logout() async throws { throw MockError.expected }
}

@MainActor
private final class SuspendedCaptureMock: BufferedAudioTransmitting {
    var diagnostics = BufferedAudioTxDiagnostics()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var recordingContinuation: CheckedContinuation<Void, Error>?
    private let suspendRecording: Bool
    private var first = true
    init(suspendRecording: Bool = false) { self.suspendRecording = suspendRecording }
    var isWaiting: Bool { continuation != nil || recordingContinuation != nil }
    func prepare(generationId: String) async {}
    func audioSessionDidActivate() async throws {
        if suspendRecording {
            try await withCheckedThrowingContinuation { recordingContinuation = $0 }
        }
    }
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool {
        guard first, !suspendRecording else { return true }
        first = false
        return await withCheckedContinuation { continuation = $0 }
    }
    func failOldCapture() { continuation?.resume(returning: false); continuation = nil }
    func failOldRecording() { recordingContinuation?.resume(throwing: MockError.expected); recordingContinuation = nil }
    func authorize(leaseId: String, generationId: String) async throws {}
    func performReleaseHangover(generationId: String) async -> Bool { true }
    func finish(generationId: String) async throws {}
    func discard(generationId: String) async {}
}

private actor FloorMock: FloorControlling {
    enum AcquireResult { case granted, busy }

    let events: EventLog
    let acquireResult: AcquireResult
    let failRenew: Bool
    let failRelease: Bool
    let expectedSessions: [String]

    init(
        events: EventLog,
        acquireResult: AcquireResult = .granted,
        failRenew: Bool = false,
        failRelease: Bool = false,
        expectedSessions: [String] = []
    ) {
        self.events = events
        self.acquireResult = acquireResult
        self.failRenew = failRenew
        self.failRelease = failRelease
        self.expectedSessions = expectedSessions
    }

    func acquire() async throws -> FloorResponse {
        await events.append("acquire")
        let acquired = Date()
        switch acquireResult {
        case .granted:
            return FloorResponse(
                outcome: .granted,
                owner: FloorOwner(id: "staff-a", name: "Staff A"),
                leaseId: "lease-a",
                acquiredAt: acquired,
                leaseExpiresAt: acquired.addingTimeInterval(3),
                maxTxExpiresAt: acquired.addingTimeInterval(60),
                lastRenewedAt: acquired,
                isOwner: true,
                rxReadyExpectedSessionIds: expectedSessions
            )
        case .busy:
            return FloorResponse(
                outcome: .busy,
                owner: FloorOwner(id: "staff-b", name: "Staff B"),
                leaseId: nil,
                acquiredAt: nil,
                leaseExpiresAt: nil,
                maxTxExpiresAt: nil,
                lastRenewedAt: nil,
                isOwner: false
            )
        }
    }

    func renew(leaseId: String) async throws -> FloorResponse {
        await events.append("renew")
        if failRenew { throw MockError.expected }
        let now = Date()
        return FloorResponse(
            outcome: .renewed,
            owner: FloorOwner(id: "staff-a", name: "Staff A"),
            leaseId: leaseId,
            acquiredAt: now.addingTimeInterval(-1),
            leaseExpiresAt: now.addingTimeInterval(3),
            maxTxExpiresAt: now.addingTimeInterval(59),
            lastRenewedAt: now,
            isOwner: true
        )
    }

    func release(leaseId: String) async throws {
        await events.append("release")
        if failRelease { throw MockError.expected }
    }
}

@MainActor
private final class MicrophoneMock: MicrophoneControlling {
    let events: EventLog
    let failOff: Bool
    init(events: EventLog, failOff: Bool = false) {
        self.events = events
        self.failOff = failOff
    }
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        await events.append(enabled ? "mic:on" : "mic:off")
        if !enabled, failOff { throw MockError.expected }
    }
}

private actor CueMock: PttCuePlaying {
    let events: EventLog
    let failStart: Bool
    let failEnd: Bool

    init(events: EventLog, failStart: Bool = false, failEnd: Bool = false) {
        self.events = events
        self.failStart = failStart
        self.failEnd = failEnd
    }

    func playStart() async throws {
        await events.append("cue:start")
        if failStart { throw MockError.expected }
    }

    func playEnd() async throws {
        await events.append("cue:end")
        if failEnd { throw MockError.expected }
    }
}

private final class RenewalGateClock: PTTClock, @unchecked Sendable {
    private let lock = NSLock()
    private var permitted = false
    var now: Date { Date() }
    func allowRenewal() { lock.withLock { permitted = true } }
    func sleep(milliseconds: Int) async throws {
        if milliseconds == 1_000 {
            while !lock.withLock({ permitted }) { try await Task.sleep(for: .milliseconds(1)) }
            lock.withLock { permitted = false }
        } else {
            try await Task.sleep(for: .seconds(3_600))
        }
    }
}

private final class ControlledClock: PTTClock, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Int: Int]
    var now: Date { Date() }

    init(immediateSleeps: [Int: Int] = [:]) { remaining = immediateSleeps }

    func sleep(milliseconds: Int) async throws {
        let shouldReturn = lock.withLock {
            guard let count = remaining[milliseconds], count > 0 else { return false }
            remaining[milliseconds] = count - 1
            return true
        }
        if shouldReturn {
            await Task.yield()
            return
        }
        try await Task.sleep(for: .seconds(3_600))
    }
}

final class ApplePttTokenLifecycleTests: XCTestCase {
    private let channelA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let channelB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    func testT1LiveKitReconnectDoesNotCreateANewAppleJoinGeneration() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        let first = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-a"))
        lifecycle.finishRegistration(first, succeeded: true)
        let appleGeneration = lifecycle.currentJoinGeneration

        let rebound = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-b"))
        XCTAssertEqual(rebound.channelUUID, channelA)
        XCTAssertEqual(rebound.tokenGeneration, first.tokenGeneration)
        XCTAssertEqual(lifecycle.currentJoinGeneration, appleGeneration)
        lifecycle.finishRegistration(rebound, succeeded: true)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-b"))
    }

    func testT2SameChannelLeaveRejoinRestoresRegistrationExactlyOnce() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        lifecycle.didLeave(channelUUID: channelA)
        lifecycle.beginJoin(channelId: "1ch", channelUUID: channelA)
        lifecycle.didJoin(channelUUID: channelA)

        let registration = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-next"))
        XCTAssertEqual(registration.token, "01")
        lifecycle.finishRegistration(registration, succeeded: true)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-next"))
    }

    func testT3DifferentChannelNeverSubmitsPreviousChannelToken() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        lifecycle.didLeave(channelUUID: channelA)
        lifecycle.beginJoin(channelId: "2ch", channelUUID: channelB)
        lifecycle.didJoin(channelUUID: channelB)

        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-b"))
        lifecycle.receivedToken(Data([0x02]), activeChannelUUID: channelB)
        let registration = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-b"))
        XCTAssertEqual(registration.channelUUID, channelB)
        XCTAssertEqual(registration.channelId, "2ch")
        XCTAssertEqual(registration.token, "02")
    }

    func testT4TokenBeforeDidJoinRegistersAfterJoinExactlyOnce() throws {
        var lifecycle = ApplePttTokenLifecycle()
        lifecycle.beginJoin(channelId: "1ch", channelUUID: channelA)
        lifecycle.receivedToken(Data([0x01]), activeChannelUUID: nil)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-a"))

        lifecycle.didJoin(channelUUID: channelA)
        let registration = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-a"))
        lifecycle.finishRegistration(registration, succeeded: true)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-a"))
    }

    func testT5DidJoinBeforeTokenRegistersWhenCallbackArrives() throws {
        var lifecycle = ApplePttTokenLifecycle()
        lifecycle.beginJoin(channelId: "1ch", channelUUID: channelA)
        lifecycle.didJoin(channelUUID: channelA)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-a"))

        lifecycle.receivedToken(Data([0x01]), activeChannelUUID: channelA)
        let registration = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-a"))
        lifecycle.finishRegistration(registration, succeeded: true)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-a"))
    }

    func testT6TokenRotationSupersedesSubmittedToken() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        let first = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-a"))
        lifecycle.finishRegistration(first, succeeded: true)

        lifecycle.receivedToken(Data([0x02]), activeChannelUUID: channelA)
        let rotated = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-a"))
        XCTAssertGreaterThan(rotated.tokenGeneration, first.tokenGeneration)
        XCTAssertEqual(rotated.token, "02")
    }

    func testT7LeaveMakesTokenIneligibleUntilAValidRejoin() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        lifecycle.didLeave(channelUUID: channelA)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-a"))
    }

    func testT8PowerOffOnSameChannelReseedsWithNewBackendSession() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        let old = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-old"))
        lifecycle.finishRegistration(old, succeeded: true)
        lifecycle.didLeave(channelUUID: channelA)
        lifecycle.beginJoin(channelId: "1ch", channelUUID: channelA)
        lifecycle.didJoin(channelUUID: channelA)

        let next = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-new"))
        XCTAssertEqual(next.channelUUID, channelA)
        XCTAssertEqual(next.backendSessionId, "session-new")
    }

    func testT9ChannelSwitchLeavesAUnregisteredAndRequiresBToken() throws {
        var lifecycle = joinedLifecycle(channelId: "1ch", channelUUID: channelA, token: 0x01)
        lifecycle.didLeave(channelUUID: channelA)
        lifecycle.beginJoin(channelId: "2ch", channelUUID: channelB)
        lifecycle.didJoin(channelUUID: channelB)
        XCTAssertNil(lifecycle.claimRegistration(backendSessionId: "session-b"))

        lifecycle.receivedToken(Data([0x02]), activeChannelUUID: channelB)
        let next = try XCTUnwrap(lifecycle.claimRegistration(backendSessionId: "session-b"))
        XCTAssertEqual(next.channelUUID, channelB)
        XCTAssertNotEqual(next.token, "01")
    }

    func testRestorationReseedsRegardlessOfTokenCallbackOrdering() throws {
        var callbackFirst = ApplePttTokenLifecycle()
        callbackFirst.receivedToken(Data([0x01]), activeChannelUUID: channelA)
        callbackFirst.restoreJoined(channelId: "1ch", channelUUID: channelA)
        XCTAssertNotNil(callbackFirst.claimRegistration(backendSessionId: "session-a"))

        var restorationFirst = ApplePttTokenLifecycle()
        restorationFirst.restoreJoined(channelId: "1ch", channelUUID: channelA)
        XCTAssertNil(restorationFirst.claimRegistration(backendSessionId: "session-a"))
        restorationFirst.receivedToken(Data([0x02]), activeChannelUUID: channelA)
        XCTAssertNotNil(restorationFirst.claimRegistration(backendSessionId: "session-a"))
    }

    private func joinedLifecycle(
        channelId: String,
        channelUUID: UUID,
        token: UInt8
    ) -> ApplePttTokenLifecycle {
        var lifecycle = ApplePttTokenLifecycle()
        lifecycle.receivedToken(Data([token]), activeChannelUUID: nil)
        lifecycle.beginJoin(channelId: channelId, channelUUID: channelUUID)
        lifecycle.didJoin(channelUUID: channelUUID)
        return lifecycle
    }
}

private final class BluetoothFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
}

@MainActor
private final class SuspendedStartCue: PttCuePlaying {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func playStart() async throws { await withCheckedContinuation { continuation = $0 } }
    func playEnd() async throws {}
    func resume() { continuation?.resume(); continuation = nil }
}
