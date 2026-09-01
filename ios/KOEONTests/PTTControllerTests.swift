import AVFoundation
import XCTest
@testable import KOEON

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

    func testA2A3RenewContinuesWhileBufferedFinalizationExceedsLeaseTtl() async {
        let events = EventLog()
        let buffered = BlockingFinishBufferedAudioMock(events: events)
        let controller = PTTController(
            role: .staff, floor: FloorMock(events: events), microphone: MicrophoneMock(events: events),
            cuePlayer: CueMock(events: events), control: ControlMock(events: events), bufferedAudio: buffered,
            clock: ControlledClock(immediateSleeps: [1_000: 5]), onUpdate: { _ in }
        )
        let prepared = await controller.preArmForAppleActivation()
        XCTAssertTrue(prepared)
        await controller.appleAudioSessionDidActivate()
        await controller.activatePrearmedTransmission()
        let release = Task { await controller.pttUp(playEndCue: false) }
        await waitUntil { buffered.finishStarted }
        await waitUntil { (await controller.currentSnapshot()).txFloorRenewDuringReleaseCount > 0 }
        let releasing = await controller.currentSnapshot()
        XCTAssertEqual(releasing.state, .releasing)
        buffered.completeFinish()
        await release.value
        let snapshot = await controller.currentSnapshot()
        XCTAssertGreaterThan(snapshot.txFloorRenewDuringReleaseCount, 0)
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

    func testC4C5C6CaptureNormalizes16kAnd32kMonoTo48k() throws {
        for sourceRate in [16_000, 32_000, 48_000] {
            let samples = Array(repeating: Int16(1_024), count: sourceRate * 20 / 1_000)
            let output = try Batv1CaptureNormalizer.normalizeMono(samples: samples, sourceSampleRate: sourceRate)
            XCTAssertEqual(output.count, batv1SampleRate * 20 / 1_000, accuracy: 2)
        }
    }

    func testC5Non48kCaptureIsNormalizedAsynchronouslyAndGenerationFenced() async {
        let capture = Batv1CaptureBuffer()
        capture.arm(generationId: "hfp-16k")
        capture.append(
            samples: Array(repeating: Int16(1_024), count: 16_000 * 20 / 1_000),
            sampleRate: 16_000,
            channels: 1
        )
        let captureConfirmed = await capture.awaitCapture(timeoutMilliseconds: 750)
        XCTAssertTrue(captureConfirmed)
        XCTAssertEqual(capture.frameCount, 1)
        XCTAssertGreaterThan(capture.callbackDiagnostics.normalized, 0)

        capture.arm(generationId: "next-generation")
        capture.discard()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(capture.frameCount, 0, "Queued conversion from an old generation must be fenced")
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
            timedOut: false, firstReadyAt: nil, allReadyAt: nil
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
    let failFinish: Bool
    init(events: EventLog, failFinish: Bool = false) { self.events = events; self.failFinish = failFinish }
    func prepare(generationId: String) async {
        diagnostics.generationId = generationId
        Task { await events.append("buffer:prepare") }
    }
    func audioSessionDidActivate() async throws {
        diagnostics.captureArmed = true
        await events.append("buffer:capture-start")
    }
    func awaitCaptureAndMarkCueBoundary(generationId: String) async -> Bool {
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
    private(set) var pendingFrames = 0
    private(set) var completedFrames = 0
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var enqueueCount = 0
    private(set) var shutdownCount = 0
    private var activeToken: Int?

    func beginGeneration(token: Int) throws { activeToken = token; beginCount += 1 }
    func setRate(_ rate: Float) {}
    func enqueue(_ data: Data, generationToken: Int) throws {
        guard activeToken == generationToken else { throw BufferedAudioError.generationMismatch }
        enqueueCount += 1
        completedFrames += 1
    }
    func drain(generationToken: Int) async {}
    func endGeneration(token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
        endCount += 1
    }
    func resumeIfNeeded() throws {}
    func shutdown() { shutdownCount += 1 }
}

private final class Batv1APIStub: KOEONAPIClientProtocol, @unchecked Sendable {
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
        return Batv1PublishResponse(outcome: "accepted", acceptedChunks: request.chunks.count, latestSequence: request.chunks.last?.sequence ?? -1)
    }
    func subscribeBufferedAudio(_ request: Batv1SubscribeRequest) async throws -> Batv1SubscribeResponse {
        guard let subscribeHandler else { throw MockError.expected }
        return try subscribeHandler(request)
    }
    func logout() async throws { throw MockError.expected }
}

private actor FloorMock: FloorControlling {
    enum AcquireResult { case granted, busy }

    let events: EventLog
    let acquireResult: AcquireResult
    let failRenew: Bool
    let expectedSessions: [String]

    init(
        events: EventLog,
        acquireResult: AcquireResult = .granted,
        failRenew: Bool = false,
        expectedSessions: [String] = []
    ) {
        self.events = events
        self.acquireResult = acquireResult
        self.failRenew = failRenew
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
