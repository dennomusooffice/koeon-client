import AVFoundation
import XCTest
import LiveKit
@testable import KOEON

// Opt-in SFU interoperability probe. Apple PushToTalk is NOT exercised here.
private final class RtpLabAudioProbe: NSObject, AudioCustomProcessingDelegate, AudioRenderer, RoomDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0.0
    private var rate = 48000.0
    private var nonzero = 0
    private var subscribed = 0
    var counts: (Int, Int) { lock.withLock { (nonzero, subscribed) } }
    func audioProcessingInitialize(sampleRate: Int, channels: Int) { lock.withLock { rate = Double(sampleRate) } }
    func audioProcessingRelease() {}
    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        lock.withLock {
            for frame in 0..<audioBuffer.frames {
                let sample = Float(sin(phase) * 6000)
                phase += 2 * .pi * 660 / rate
                for channel in 0..<audioBuffer.channels { audioBuffer.rawBuffer(forChannel: channel)[frame] = sample }
            }
        }
    }
    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.withLock {
            if let data = pcmBuffer.floatChannelData {
                for i in 0..<Int(pcmBuffer.frameLength) where abs(data[0][i]) > 0.01 { nonzero += 1 }
            } else if let data = pcmBuffer.int16ChannelData {
                for i in 0..<Int(pcmBuffer.frameLength) where abs(Int(data[0][i])) > 300 { nonzero += 1 }
            }
        }
    }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? RemoteAudioTrack else { return }
        track.add(audioRenderer: self)
        lock.withLock { subscribed += 1 }
        Task { try? await room.localParticipant.publish(data: Data("ready".utf8), options: DataPublishOptions(topic: "rtp-lab", reliable: true)) }
    }
}

@MainActor
private final class RtpLabGateway: MicrophoneControlling, PttControlPublishing {
    let room: Room
    init(room: Room) { self.room = room }
    func setMicrophoneEnabled(_ enabled: Bool) async throws { _ = try await room.localParticipant.setMicrophone(enabled: enabled) }
    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics {
        try await room.localParticipant.publish(data: Data("start".utf8), options: DataPublishOptions(topic: "rtp-lab-control", reliable: true))
        return .init()
    }
    func publishEnd(leaseId: String) async throws {
        try await room.localParticipant.publish(data: Data("end".utf8), options: DataPublishOptions(topic: "rtp-lab-control", reliable: true))
    }
}

@MainActor
final class LiveKitRtpLabTests: XCTestCase {
    func testNativeOpusInteroperability() async throws {
        guard ProcessInfo.processInfo.environment["KOEON_RTP_LAB"] == "1" else {
            throw XCTSkip("Opt-in local SFU probe")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("This test must not run on a physical device")
        #endif
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18766/token/ios27")!)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let token = try XCTUnwrap(object["token"])
        let probe = RtpLabAudioProbe()
        let manager = AudioManager.shared
        let oldProcessor = manager.capturePostProcessingDelegate
        let oldAutomatic = manager.audioSession.isAutomaticConfigurationEnabled
        let oldAvailability = manager.engineAvailability
        manager.audioSession.isAutomaticConfigurationEnabled = true
        try manager.setEngineAvailability(.default)
        manager.capturePostProcessingDelegate = probe
        let room = Room(delegate: probe, roomOptions: RoomOptions(
            defaultAudioPublishOptions: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 12000), dtx: false, red: true)))
        do {
            try await room.connect(url: "ws://127.0.0.1:19080", token: token)
            let gateway = RtpLabGateway(room: room)
            let events = EventLog()
            let controller = PTTController(role: .staff, floor: FloorMock(events: events),
                microphone: gateway, cuePlayer: CueMock(events: events), control: gateway,
                rtpReleaseHangoverMilliseconds: 180, onUpdate: { _ in })
            await controller.pttDown()
            let started = await controller.currentSnapshot()
            XCTAssertEqual(started.state, .transmitting)
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while probe.counts.0 < 16000, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(probe.counts.0, 16000)
            XCTAssertGreaterThan(probe.counts.1, 0)
            // Keep transmitting while the peer disconnects, rejoins and sends again.
            try await Task.sleep(for: .seconds(12))
            await controller.pttUp()
            let ended = await controller.currentSnapshot()
            XCTAssertEqual(ended.state, .idle)
            let result: [String: Any] = ["role": "ios27", "nonzeroSamples": probe.counts.0,
                "subscribedTracks": probe.counts.1, "codecTargetBps": 12000]
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18766/result")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: result)
            _ = try await URLSession.shared.data(for: request)
            try await Task.sleep(for: .seconds(5))
        } catch {
            await room.disconnect()
            manager.capturePostProcessingDelegate = oldProcessor
            manager.audioSession.isAutomaticConfigurationEnabled = oldAutomatic
            try? manager.setEngineAvailability(oldAvailability)
            throw error
        }
        await room.disconnect()
        manager.capturePostProcessingDelegate = oldProcessor
        manager.audioSession.isAutomaticConfigurationEnabled = oldAutomatic
        try? manager.setEngineAvailability(oldAvailability)
    }
}

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
    func testRtpTailKeepsMicUntilBoundedReleaseAndSafetyCanInterrupt() async throws {
        for interrupt in [false, true] {
            let events = EventLog()
            let clock = RtpTailGateClock()
            let controller = PTTController(role: .staff, floor: FloorMock(events: events),
                microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
                control: ControlMock(events: events), rtpReleaseHangoverMilliseconds: 180,
                clock: clock, onUpdate: { _ in })
            await controller.pttDown()
            let release = Task { await controller.pttUp() }
            for _ in 0..<100 where !clock.started { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(clock.started)
            let before = await events.values()
            XCTAssertFalse(before.contains("mic:off"))
            if interrupt { await controller.stopForSafety(reason: "interruption during RTP tail") }
            clock.allow()
            await release.value
            let after = await events.values()
            XCTAssertTrue(after.contains("mic:off"))
            XCTAssertEqual(after.filter { $0 == "release" }.count, 1)
        }
    }

    func testCarAudioClassificationAndDisconnectSafety() {
        let route = AudioSessionController.mapPortType(.carAudio)
        XCTAssertEqual(route, .car)
        XCTAssertTrue(AudioSessionController.lostExternalInputRoute(previous: route, reason: .oldDeviceUnavailable))
        XCTAssertFalse(AudioSessionController.lostExternalInputRoute(previous: route, reason: .categoryChange))
        XCTAssertFalse(AudioSessionController.lostExternalInputRoute(previous: .speaker, reason: .oldDeviceUnavailable))
        for external: AudioRouteKind in [.bluetooth, .wired, .usb] {
            XCTAssertTrue(AudioSessionController.lostExternalInputRoute(previous: external, reason: .oldDeviceUnavailable))
        }
    }

    func testVehicleAndExternalRoutesDoNotRequestBuiltInSpeakerOnActivation() {
        for route: AudioRouteKind in [.car, .usb, .wired, .bluetooth] {
            XCTAssertFalse(AudioSessionController.speakerOutputPreferred(for: route))
            let options = AudioSessionController.pushToTalkCategoryOptions(for: route)
            XCTAssertFalse(options.contains(.defaultToSpeaker))
            XCTAssertTrue(options.contains(.allowBluetoothHFP))
        }
        for route: AudioRouteKind in [.speaker, .receiver, .builtIn, .unknown] {
            XCTAssertTrue(AudioSessionController.speakerOutputPreferred(for: route))
            XCTAssertTrue(AudioSessionController.pushToTalkCategoryOptions(for: route).contains(.defaultToSpeaker))
        }
    }

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

    func testGrantEnablesRtpBeforeSpeakCueAndReleaseOrdersEndCue() async throws {
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
        XCTAssertEqual(Array(startedEvents.prefix(4)), ["acquire", "control:start", "mic:on", "cue:start"])
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
        XCTAssertEqual(values, ["acquire", "control:start", "mic:on", "cue:start"])
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


    func testD50PreauthorizedAbortsRetainLeaseUntilConfirmedAndRequireAppleRearm() async {
        for _ in 0..<50 {
            let events = EventLog()
            let controller = PTTController(role: .staff, floor: FloorMock(events: events),
                microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
                control: ControlMock(events: events),
                clock: ControlledClock(), onUpdate: { _ in })
            var apple = PttRequestGate()
            _ = apple.pressDown()
            let prepared = await controller.preArmForAppleActivation()
            XCTAssertTrue(prepared)
            _ = apple.didBegin()
            await controller.stopForSafety(reason: "TX_ACTIVATION_TIMEOUT")
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
            XCTAssertFalse(values.contains("mic:on"))
        }
    }

    func testDFailedReleaseCannotForgetLeaseOrReleaseAnotherOwner() async {
        let events = EventLog()
        let controller = PTTController(role: .staff, floor: FloorMock(events: events, failRelease: true),
            microphone: MicrophoneMock(events: events), cuePlayer: CueMock(events: events),
            control: ControlMock(events: events),
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
    func testManualHeadsetGainSupports24DbAndPersistsSeparatelyFromAuto() {
        let suite = "gain-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gain = InputGainProcessor(defaults: defaults)
        XCTAssertEqual(gain.snapshot().mode, .auto)
        gain.setRoute("Bluetooth")
        gain.setMode(.manual)
        gain.setManualGainDb(24)
        gain.beginTransmission()
        var samples: [Float] = [100, -100]
        samples.withUnsafeMutableBufferPointer { buffer in
            gain.processFloatS16(channels: 1, frames: buffer.count) { _ in buffer.baseAddress! }
        }
        XCTAssertEqual(gain.snapshot().effectiveGainDb, 24)
        XCTAssertEqual(samples[0], 100 * powf(10, 24 / 20) * 32_767 / 32_768, accuracy: 0.1)
        XCTAssertEqual(samples[0], -samples[1], accuracy: 0.1)
        gain.endTransmission()
        let restored = InputGainProcessor(defaults: defaults)
        restored.setRoute("Bluetooth")
        XCTAssertEqual(restored.snapshot().mode, .manual)
        XCTAssertEqual(restored.snapshot().effectiveGainDb, 24)
        restored.setRoute("Built-in")
        XCTAssertEqual(restored.snapshot().manualGainDb, 0)
        restored.setMode(.auto)
        XCTAssertEqual(restored.snapshot().effectiveGainDb, 0)
        XCTAssertEqual(InputGainProcessor.recommendedGain(speechRmsDbfs: -50), 12)
        restored.setMode(.off)
        XCTAssertEqual(InputGainProcessor(defaults: defaults).snapshot().mode, .off)
    }

    func testManual24DbStillLimitsPeaksAndDoesNotExpandAutoRange() {
        withGain { gain in
            gain.setMode(.manual)
            gain.setManualGainDb(30)
            gain.beginTransmission()
            var samples: [Float] = [32_000, -32_000]
            samples.withUnsafeMutableBufferPointer { buffer in
                gain.processFloatS16(channels: 1, frames: buffer.count) { _ in buffer.baseAddress! }
            }
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 24)
            XCTAssertLessThan(abs(samples[0]), 0.9 * 32_768)
            XCTAssertEqual(samples[0], -samples[1], accuracy: 0.1)
            XCTAssertEqual(gain.snapshot().limiterHits, 2)
            gain.endTransmission()
            gain.setMode(.auto)
            for _ in 0..<30 {
                gain.beginTransmission()
                feed(gain, value: 100, count: 9_600)
                gain.endTransmission()
            }
            XCTAssertEqual(gain.snapshot().autoTrimDb, 12)
        }
    }

    func testLimiterDominatedCompletedUtteranceReducesAutoGain() {
        withGain { gain in
            gain.setRoute("Bluetooth")
            gain.setMode(.auto)
            gain.beginTransmission()
            feed(gain, value: 32_000, count: 9_600)
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 0)
            XCTAssertEqual(gain.snapshot().limiterHits, 9_600)
            gain.endTransmission()
            XCTAssertEqual(gain.snapshot().autoTrimDb, -1)
            gain.endTransmission()
            XCTAssertEqual(gain.snapshot().autoTrimDb, -1)
            gain.setRoute("Built-in")
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
            gain.setRoute("Bluetooth")
            XCTAssertEqual(gain.snapshot().autoTrimDb, -1)
        }
    }

    func testSparseClippedPeakDoesNotRaiseAutoDespiteQuietAverage() {
        withGain { gain in
            gain.setMode(.auto)
            gain.beginTransmission()
            feed(gain, value: 1_000, count: 9_599)
            feed(gain, value: 32_000, count: 1)
            XCTAssertLessThan(gain.snapshot().rmsDbfs!, -24)
            gain.endTransmission()
            XCTAssertEqual(gain.snapshot().autoTrimDb, -1)
        }
    }

    func testCancelledOverloadedUtteranceDoesNotTrainAuto() {
        withGain { gain in
            gain.setMode(.auto)
            gain.beginTransmission()
            feed(gain, value: 32_000, count: 9_600)
            gain.endTransmission(learn: false)
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
            XCTAssertEqual(gain.snapshot().lastLearningDecision, "CANCELLED")
        }
    }

    func testInitialMicrophoneSelectionBeforeFirstSampleCanLearnItsOwnProfile() {
        withGain { gain in
            gain.setRoute("ios|Bluetooth|unavailable")
            gain.setMode(.auto)
            gain.beginTransmission()
            // Apple PTT activation can reveal the actual input only after DOWN.
            gain.setRoute("ios|BluetoothHFP|Test headset")
            feed(gain, value: 2_000, count: 9_600)
            gain.endTransmission()
            XCTAssertEqual(gain.snapshot().autoTrimDb, 1)
            XCTAssertEqual(gain.snapshot().lastLearningDecision, "INCREASED")
            XCTAssertEqual(gain.snapshot().lastCompletedSampleCount, 9_600)
            gain.setRoute("ios|Bluetooth|unavailable")
            XCTAssertEqual(gain.snapshot().lastLearningDecision, "INCREASED")
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
        }
    }

    func testRouteChangeCancelsCalibrationAndUsesNewMicrophoneGain() {
        withGain { gain in
            gain.setMode(.manual)
            gain.setRoute("Wired")
            gain.setManualGainDb(12)
            gain.setRoute("Built-in")
            gain.setManualGainDb(6)
            gain.beginTransmission()
            gain.startCalibration()
            gain.setRoute("Wired")
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 12)
            XCTAssertEqual(gain.snapshot().calibrationState, "IDLE")
            XCTAssertNil(gain.snapshot().recommendationDb)
        }
    }

    func testRouteChangeCannotTrainAnotherMicrophoneProfile() {
        withGain { gain in
            gain.setMode(.auto)
            gain.setRoute("Built-in")
            gain.beginTransmission()
            feed(gain, value: 2_000, count: 9_600)
            gain.setRoute("Wired")
            feed(gain, value: 2_000, count: 9_600)
            gain.endTransmission()
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
            XCTAssertEqual(gain.snapshot().lastLearningDecision, "ROUTE_CHANGED")
            gain.setRoute("Built-in")
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
        }
    }

    func testCancelledTransmissionDoesNotTrainAuto() {
        withGain { gain in
            gain.setMode(.auto)
            gain.beginTransmission()
            feed(gain, value: 2_000, count: 9_600)
            gain.endTransmission(learn: false)
            XCTAssertEqual(gain.snapshot().autoTrimDb, 0)
        }
    }

    func testLiveKitGainFixedUntilTransmissionEnds() {
        withGain { gain in
            gain.setMode(.manual)
            gain.setManualGainDb(6)
            gain.beginTransmission()
            feed(gain, value: 2_000, count: 960)
            gain.setManualGainDb(12)
            feed(gain, value: 2_000, count: 960)
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 6)
            gain.endTransmission()
            gain.beginTransmission()
            XCTAssertEqual(gain.snapshot().effectiveGainDb, 12)
        }
    }

    private func feed(_ gain: InputGainProcessor, value: Float, count: Int) {
        var samples = [Float](repeating: value, count: count)
        samples.withUnsafeMutableBufferPointer { buffer in
            gain.processFloatS16(channels: 1, frames: count) { _ in buffer.baseAddress! }
        }
    }

    private func withGain(_ body: (InputGainProcessor) -> Void) {
        let name = "livekit-gain-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gain = InputGainProcessor(defaults: defaults)
        gain.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        body(gain)
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


final class AudioBreadcrumbLifecycleTests: XCTestCase {
    func testPollingWindowIsBoundedAndRestartsAfterReload() {
        let defaults = isolatedDefaults()
        let store = AudioLifecycleBreadcrumbStore(defaults: defaults)
        store.startRun(build: "test")
        for index in 0..<100 {
            store.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "g\(index)")
        }
        XCTAssertEqual(store.snapshot().count, 64)
        for _ in 0..<2 { store.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "g0") }
        XCTAssertEqual(store.snapshot().filter { $0.generationToken == "g0" }.count, 1)
        let restored = AudioLifecycleBreadcrumbStore(defaults: defaults)
        restored.startRun(build: "next")
        restored.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "g0")
        XCTAssertEqual(restored.snapshot().last?.stage, "RX_SUBSCRIBE_BEGIN")
        XCTAssertEqual(restored.snapshot().last?.build, "next")
        XCTAssertEqual(restored.snapshot().count, 64)
    }

    func testPollingDoesNotEvictBackgroundAndFailureEvidenceAcrossReload() {
        let defaults = isolatedDefaults()
        let store = AudioLifecycleBreadcrumbStore(defaults: defaults)
        store.startRun(build: "test")
        store.recordAppLifecycle("background")
        store.record(role: "APP", stage: "RUNTIME_CONNECT_FAILED", resultClass: "LISTENING_RETAINED")
        for _ in 0..<200 {
            store.record(role: "RX", stage: "RX_SUBSCRIBE_BEGIN", generationId: "generation-a")
            store.record(role: "RX", stage: "RX_SUBSCRIBE_END", generationId: "generation-a")
        }
        let restored = AudioLifecycleBreadcrumbStore(defaults: defaults)
        restored.startRun(build: "next")
        XCTAssertTrue(restored.snapshot().contains { $0.stage == "APP_BACKGROUND" })
        XCTAssertTrue(restored.snapshot().contains { $0.stage == "RUNTIME_CONNECT_FAILED" })
        XCTAssertEqual(restored.snapshot().filter { $0.stage == "RX_SUBSCRIBE_BEGIN" }.count, 1)
        XCTAssertEqual(restored.snapshot().filter { $0.stage == "RX_SUBSCRIBE_END" }.count, 1)
    }

    func testPollingCoalescingSeparatesFullGenerationsAndPreservesErrors() {
        let store = AudioLifecycleBreadcrumbStore(defaults: isolatedDefaults())
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
            let store = AudioLifecycleBreadcrumbStore(defaults: defaults)
            store.startRun(build: "test")
            XCTAssertEqual(store.previousRunTermination, "UNKNOWN",
                "A lifecycle flag without a termination report cannot identify the cause")
        }
    }

    func testBackgroundTransitionIsNotEvidenceOfCleanProcessExit() {
        let defaults = isolatedDefaults()
        let before = AudioLifecycleBreadcrumbStore(defaults: defaults)
        before.startRun(build: "before")
        before.recordAppLifecycle("background")
        let after = AudioLifecycleBreadcrumbStore(defaults: defaults)
        after.startRun(build: "after")
        XCTAssertEqual(after.previousRunTermination, "UNKNOWN")
        XCTAssertEqual(after.previousRunLastLifecycleState, "BACKGROUND")
        XCTAssertEqual(before.snapshot().last?.stage, "APP_BACKGROUND")
    }

    func testBackgroundAudioDoesNotChangeLastObservedAppLifecycle() {
        let defaults = isolatedDefaults()
        let before = AudioLifecycleBreadcrumbStore(defaults: defaults)
        before.startRun(build: "before")
        before.recordAppLifecycle("background")
        for _ in 0..<100 { before.record(role: "RX", stage: "RX_SUBSCRIBE_END") }
        let after = AudioLifecycleBreadcrumbStore(defaults: defaults)
        after.startRun(build: "after")
        XCTAssertEqual(after.previousRunTermination, "UNKNOWN")
        XCTAssertEqual(after.previousRunLastLifecycleState, "BACKGROUND",
            "Audio callbacks and bounded breadcrumb eviction do not imply a foreground transition")
    }

    func testForegroundResumeUpdatesObservedLifecycleWithoutInferringTermination() {
        let defaults = isolatedDefaults()
        let before = AudioLifecycleBreadcrumbStore(defaults: defaults)
        before.startRun(build: "before")
        before.recordAppLifecycle("background")
        before.recordAppLifecycle("inactive")
        before.recordAppLifecycle("active")
        let after = AudioLifecycleBreadcrumbStore(defaults: defaults)
        after.startRun(build: "after")
        XCTAssertEqual(after.previousRunTermination, "UNKNOWN")
        XCTAssertEqual(after.previousRunLastLifecycleState, "ACTIVE")
    }

    func testStartupAndUnknownLifecycleAreReportedWithoutInventingACause() {
        let defaults = isolatedDefaults()
        let first = AudioLifecycleBreadcrumbStore(defaults: defaults)
        first.startRun(build: "first")
        XCTAssertEqual(first.previousRunLastLifecycleState, "UNKNOWN")
        let second = AudioLifecycleBreadcrumbStore(defaults: defaults)
        second.startRun(build: "second")
        XCTAssertEqual(second.previousRunLastLifecycleState, "STARTING")
        second.recordAppLifecycle("unrecognized-private-value")
        let third = AudioLifecycleBreadcrumbStore(defaults: defaults)
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

private final class RtpTailGateClock: PTTClock, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var permitted = false
    var started: Bool { lock.withLock { entered } }
    var now: Date { Date() }
    func allow() { lock.withLock { permitted = true } }
    func sleep(milliseconds: Int) async throws {
        if milliseconds == 180 {
            lock.withLock { entered = true }
            while !lock.withLock({ permitted }) { try await Task.sleep(for: .milliseconds(1)) }
        } else { try await Task.sleep(for: .seconds(3600)) }
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
