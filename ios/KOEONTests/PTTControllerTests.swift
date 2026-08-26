import XCTest
@testable import KOEON

@MainActor
final class PTTControllerTests: XCTestCase {
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

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [PTTSnapshot] = []
    func append(_ value: PTTSnapshot) { lock.withLock { snapshots.append(value) } }
}

private enum MockError: Error { case expected }

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
