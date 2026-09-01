import Foundation

@MainActor
protocol MicrophoneControlling: AnyObject {
    func setMicrophoneEnabled(_ enabled: Bool) async throws
}

protocol PttCuePlaying: Sendable {
    func playStart() async throws
    func playEnd() async throws
}

actor PTTController {
    static let renewIntervalMilliseconds = 1_000
    static let maxContinuousTxMilliseconds = 60_000

    private let role: KOEONRole
    private let floor: any FloorControlling
    private let microphone: any MicrophoneControlling
    private let cuePlayer: any PttCuePlaying
    private let control: any PttControlPublishing
    private let bufferedAudio: (any BufferedAudioTransmitting)?
    private let clock: any PTTClock
    private let onUpdate: @Sendable (PTTSnapshot) -> Void

    private var snapshot: PTTSnapshot
    private var isPressed = false
    private var generation = 0
    private var renewTask: Task<Void, Never>?
    private var maxTxTask: Task<Void, Never>?
    private var localCueEnabled = true
    private var preparedResponse: FloorResponse?
    private var preparedOperation: Int?
    private var activeBufferedGenerationId: String?

    init(
        role: KOEONRole,
        floor: any FloorControlling,
        microphone: any MicrophoneControlling,
        cuePlayer: any PttCuePlaying,
        control: any PttControlPublishing,
        bufferedAudio: (any BufferedAudioTransmitting)? = nil,
        clock: any PTTClock = SystemPTTClock(),
        onUpdate: @escaping @Sendable (PTTSnapshot) -> Void
    ) {
        self.role = role
        self.floor = floor
        self.microphone = microphone
        self.cuePlayer = cuePlayer
        self.control = control
        self.bufferedAudio = bufferedAudio
        self.clock = clock
        self.onUpdate = onUpdate
        snapshot = .initial(role: role)
    }

    func currentSnapshot() -> PTTSnapshot { snapshot }

    func pttDown(playReadyCue: Bool = true, maximumReadyWaitMilliseconds: Int? = nil) async {
        _ = await beginTransmission(
            playReadyCue: playReadyCue,
            deferMicrophoneUntilAppleActivation: false,
            maximumReadyWaitMilliseconds: maximumReadyWaitMilliseconds,
            onFloorGranted: nil
        )
    }

    /// App-button PRE-ARM: Floor is authoritative; Apple pre-arm may run in
    /// parallel with control publish / bounded receiver readiness afterwards.
    func preArmForAppleActivation(
        maximumReadyWaitMilliseconds: Int? = nil,
        onFloorGranted: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        await beginTransmission(
            playReadyCue: false,
            deferMicrophoneUntilAppleActivation: true,
            maximumReadyWaitMilliseconds: maximumReadyWaitMilliseconds,
            onFloorGranted: onFloorGranted
        )
    }

    private func beginTransmission(
        playReadyCue: Bool,
        deferMicrophoneUntilAppleActivation: Bool,
        maximumReadyWaitMilliseconds: Int?,
        onFloorGranted: (@Sendable () async -> Void)?
    ) async -> Bool {
        guard role.canPublish else {
            snapshot.state = .rxOnly
            publish()
            return false
        }
        guard !isPressed, snapshot.state != .transmitting else { return false }

        isPressed = true
        localCueEnabled = playReadyCue
        generation += 1
        let operation = generation
        snapshot = .initial(role: role)
        snapshot.attemptGeneration = operation
        snapshot.state = .requestingFloor
        snapshot.pttDownAt = clock.now
        snapshot.localUiFeedbackAt = clock.now
        snapshot.floorRequestAt = clock.now
        if bufferedAudio != nil {
            let bufferedGenerationId = UUID().uuidString.lowercased()
            activeBufferedGenerationId = bufferedGenerationId
            await bufferedAudio?.prepare(generationId: bufferedGenerationId)
        }
        publish()

        do {
            let response = try await floor.acquire()
            guard operation == generation, isPressed else {
                if let leaseId = response.leaseId, response.outcome == .granted {
                    try? await floor.release(leaseId: leaseId)
                }
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }
            guard response.outcome == .granted, let leaseId = response.leaseId else {
                await discardActiveBuffered()
                snapshot.state = .busy
                snapshot.ownerName = response.owner?.name
                publish()
                return false
            }

            snapshot.leaseId = leaseId
            snapshot.ownerName = response.owner?.name
            snapshot.leaseExpiresAt = response.leaseExpiresAt
            snapshot.maxTxExpiresAt = response.maxTxExpiresAt
            snapshot.floorGrantedAt = clock.now
            startLeaseTasks(leaseId: leaseId, operation: operation, response: response)
            await onFloorGranted?()
            guard operation == generation, isPressed, snapshot.attemptGeneration == operation else {
                try? await floor.release(leaseId: leaseId)
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }
            // BATv1 on Apple PushToTalk must wait for Apple's didActivate before
            // local recording, cue boundary, START, and RX_READY. Floor ownership
            // is retained, but no audio or START is published from this pre-arm.
            if deferMicrophoneUntilAppleActivation, activeBufferedGenerationId != nil {
                preparedResponse = response
                preparedOperation = operation
                snapshot.startCueResult = .skipped("Awaiting Apple PushToTalk audio activation")
                publish()
                return true
            }
            let expected = response.rxReadyExpectedSessionIds ?? []
            let expectedDevices = response.rxReadyExpectedDeviceIds ?? []
            snapshot.wakeRecipientCount = response.wakeRecipientCount ?? expectedDevices.count
            snapshot.coldWakeBarrierRequired = snapshot.wakeRecipientCount > 0
            snapshot.rxReadyExpectedCount = Set(expectedDevices.isEmpty ? expected : expectedDevices).count
            snapshot.rxReadyWaitStartedAt = clock.now
            snapshot.readyBarrierStartedAt = clock.now
            await control.prepareRxReady(
                leaseId: leaseId,
                expectedSessionIds: expected,
                expectedDeviceIds: expectedDevices
            )
            guard operation == generation, isPressed, snapshot.attemptGeneration == operation else {
                await control.cancelRxReady(leaseId: leaseId)
                try? await floor.release(leaseId: leaseId)
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }
            do {
                let timing: PttStartPublishDiagnostics
                if let bufferedGenerationId = activeBufferedGenerationId {
                    timing = try await control.publishBufferedStart(
                        leaseId: leaseId,
                        generationId: bufferedGenerationId
                    )
                } else {
                    timing = try await control.publishStart(leaseId: leaseId)
                }
                guard operation == generation, isPressed, snapshot.attemptGeneration == operation else {
                    try? await control.publishEnd(leaseId: leaseId)
                    try? await floor.release(leaseId: leaseId)
                    clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                    return false
                }
                snapshot.controlStartSentAt = clock.now
                snapshot.controlStartResult = "Published"
                snapshot.controlPublishFastStartedAt = timing.fastStartedAt
                snapshot.controlPublishFastCompletedAt = timing.fastCompletedAt
                snapshot.controlPublishFastMilliseconds = timing.fastMilliseconds
                snapshot.controlPublishReliableStartedAt = timing.reliableStartedAt
                snapshot.controlPublishReliableCompletedAt = timing.reliableCompletedAt
                snapshot.controlPublishReliableMilliseconds = timing.reliableMilliseconds
            } catch {
                guard operation == generation, isPressed, snapshot.attemptGeneration == operation else {
                    try? await floor.release(leaseId: leaseId)
                    clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                    return false
                }
                snapshot.controlStartResult = "Failed: \(Self.safeMessage(error))"
            }
            let ready = await control.awaitRxReady(
                leaseId: leaseId,
                maximumWaitMilliseconds: maximumReadyWaitMilliseconds
            )
            guard operation == generation, isPressed, snapshot.attemptGeneration == operation else {
                await control.cancelRxReady(leaseId: leaseId)
                try? await control.publishEnd(leaseId: leaseId)
                try? await floor.release(leaseId: leaseId)
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }
            snapshot.rxReadyExpectedCount = ready.expectedCount
            snapshot.rxReadyReceivedCount = ready.receivedCount
            snapshot.rxReadyLateCount = ready.lateCount
            snapshot.rxReadyWaitMilliseconds = ready.waitMilliseconds
            snapshot.rxReadyTimedOut = ready.timedOut
            snapshot.readyBarrierResult = ready.timedOut
                ? "READY_TIMEOUT"
                : ready.expectedCount == 0 ? "NO_EXPECTATIONS" : "READY_ACKNOWLEDGED"
            snapshot.rxReadyFirstAt = ready.firstReadyAt
            snapshot.rxReadyAllAt = ready.allReadyAt
            snapshot.readyBarrierCompletedAt = clock.now
            publish()

            if deferMicrophoneUntilAppleActivation {
                preparedResponse = response
                preparedOperation = operation
                snapshot.startCueResult = .skipped("Apple PushToTalk activation owns TX cue")
                publish()
                return true
            }

            snapshot.cueStartAt = clock.now

            if let bufferedGenerationId = activeBufferedGenerationId {
                guard await bufferedAudio?.awaitCaptureAndMarkCueBoundary(generationId: bufferedGenerationId) == true else {
                    throw BufferedAudioError.captureNotConfirmed
                }
            }

            if playReadyCue {
                do {
                    try await cuePlayer.playStart()
                    snapshot.startCueResult = .success
                } catch {
                    snapshot.startCueResult = .failure(Self.safeMessage(error))
                }
            } else {
                snapshot.startCueResult = .skipped("Apple system/handsfree transmit source")
            }
            snapshot.cueEndAt = clock.now
            publish()

            guard operation == generation, isPressed else {
                try? await floor.release(leaseId: leaseId)
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }

            if let bufferedGenerationId = activeBufferedGenerationId {
                try await bufferedAudio?.authorize(leaseId: leaseId, generationId: bufferedGenerationId)
            } else {
                try await microphone.setMicrophoneEnabled(true)
            }
            guard operation == generation, isPressed else {
                await discardActiveBuffered()
                try? await microphone.setMicrophoneEnabled(false)
                try? await floor.release(leaseId: leaseId)
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }

            snapshot.trackEnabledAt = clock.now
            snapshot.talkingAt = snapshot.trackEnabledAt
            snapshot.state = .transmitting
            publish()
            return true
        } catch {
            await discardActiveBuffered()
            try? await microphone.setMicrophoneEnabled(false)
            guard operation == generation, isPressed else {
                clearLeaseIfCurrentSnapshot(operation: operation, nextState: .idle)
                return false
            }
            if let leaseId = snapshot.leaseId {
                try? await floor.release(leaseId: leaseId)
            }
            snapshot.state = .error
            snapshot.lastError = Self.safeMessage(error)
            snapshot.leaseId = nil
            snapshot.ownerName = nil
            snapshot.leaseExpiresAt = nil
            snapshot.maxTxExpiresAt = nil
            publish()
            return false
        }
    }

    /// Called only after Apple's didActivate; no custom cue or readiness wait remains.
    func activatePrearmedTransmission() async {
        guard isPressed,
              snapshot.state == .requestingFloor,
              let leaseId = snapshot.leaseId,
              let response = preparedResponse,
              let operation = preparedOperation,
              operation == generation else { return }
        do {
            if let bufferedGenerationId = activeBufferedGenerationId {
                guard await bufferedAudio?.awaitCaptureAndMarkCueBoundary(generationId: bufferedGenerationId) == true else {
                    throw BufferedAudioError.captureNotConfirmed
                }
                snapshot.cueStartAt = clock.now
                do {
                    try await cuePlayer.playStart()
                    snapshot.startCueResult = .success
                } catch {
                    snapshot.startCueResult = .failure(Self.safeMessage(error))
                }
                snapshot.cueEndAt = clock.now
                let expected = response.rxReadyExpectedSessionIds ?? []
                let expectedDevices = response.rxReadyExpectedDeviceIds ?? []
                snapshot.wakeRecipientCount = response.wakeRecipientCount ?? expectedDevices.count
                snapshot.coldWakeBarrierRequired = snapshot.wakeRecipientCount > 0
                snapshot.rxReadyExpectedCount = Set(expectedDevices.isEmpty ? expected : expectedDevices).count
                snapshot.rxReadyWaitStartedAt = clock.now
                snapshot.readyBarrierStartedAt = clock.now
                await control.prepareRxReady(
                    leaseId: leaseId,
                    expectedSessionIds: expected,
                    expectedDeviceIds: expectedDevices
                )
                guard isPressed, operation == generation else { throw BufferedAudioError.generationMismatch }
                let timing = try await control.publishBufferedStart(
                    leaseId: leaseId,
                    generationId: bufferedGenerationId
                )
                snapshot.controlStartSentAt = clock.now
                snapshot.controlStartResult = "Published"
                snapshot.controlPublishFastStartedAt = timing.fastStartedAt
                snapshot.controlPublishFastCompletedAt = timing.fastCompletedAt
                snapshot.controlPublishFastMilliseconds = timing.fastMilliseconds
                snapshot.controlPublishReliableStartedAt = timing.reliableStartedAt
                snapshot.controlPublishReliableCompletedAt = timing.reliableCompletedAt
                snapshot.controlPublishReliableMilliseconds = timing.reliableMilliseconds
                let ready = await control.awaitRxReady(leaseId: leaseId, maximumWaitMilliseconds: nil)
                snapshot.rxReadyExpectedCount = ready.expectedCount
                snapshot.rxReadyReceivedCount = ready.receivedCount
                snapshot.rxReadyLateCount = ready.lateCount
                snapshot.rxReadyWaitMilliseconds = ready.waitMilliseconds
                snapshot.rxReadyTimedOut = ready.timedOut
                snapshot.readyBarrierResult = ready.timedOut
                    ? "READY_TIMEOUT"
                    : ready.expectedCount == 0 ? "NO_EXPECTATIONS" : "READY_ACKNOWLEDGED"
                snapshot.rxReadyFirstAt = ready.firstReadyAt
                snapshot.rxReadyAllAt = ready.allReadyAt
                snapshot.readyBarrierCompletedAt = clock.now
                guard isPressed, operation == generation else { throw BufferedAudioError.generationMismatch }
                try await bufferedAudio?.authorize(leaseId: leaseId, generationId: bufferedGenerationId)
            } else {
                try await microphone.setMicrophoneEnabled(true)
            }
            guard isPressed, operation == generation else {
                await discardActiveBuffered()
                try? await microphone.setMicrophoneEnabled(false)
                return
            }
            snapshot.trackEnabledAt = clock.now
            snapshot.talkingAt = snapshot.trackEnabledAt
            snapshot.state = .transmitting
            preparedResponse = nil
            preparedOperation = nil
            publish()
        } catch {
            await stopForSafety(reason: "TX activation failed: \(Self.safeMessage(error))")
        }
    }

    /// Apple PushToTalk is the audio-session authority. Capture is armed only
    /// after its didActivate callback and never before activation.
    func appleAudioSessionDidActivate() async {
        guard isPressed, activeBufferedGenerationId != nil else { return }
        do {
            try await bufferedAudio?.audioSessionDidActivate()
        } catch {
            await stopForSafety(reason: "BATv1 local recording start failed: \(Self.safeMessage(error))")
        }
    }

    func pttUp(playEndCue: Bool = true) async {
        guard isPressed else { return }
        snapshot.pttUpAt = clock.now
        isPressed = false

        if let leaseId = snapshot.leaseId { await control.cancelRxReady(leaseId: leaseId) }
        if snapshot.state == .transmitting, let leaseId = snapshot.leaseId {
            snapshot.lastStopReason = "user_release"
            enterReleasing()
            if let bufferedGenerationId = activeBufferedGenerationId {
                let completed = await bufferedAudio?.performReleaseHangover(generationId: bufferedGenerationId) == true
                if !completed {
                    snapshot.lastError = "BATv1 release hangover was interrupted."
                    snapshot.txErrorRecoverable = true
                }
            }
            await finishTransmission(leaseId: leaseId, playEndCue: playEndCue, nextState: .idle, error: nil)
        } else if snapshot.state == .requestingFloor, let leaseId = snapshot.leaseId {
            generation += 1
            await discardActiveBuffered()
            try? await control.publishEnd(leaseId: leaseId)
            try? await floor.release(leaseId: leaseId)
            clearLease(nextState: .idle)
        } else if snapshot.state == .requestingFloor {
            generation += 1
            await discardActiveBuffered()
            clearLease(nextState: .idle)
        } else if snapshot.state == .busy {
            generation += 1
            snapshot.state = .idle
            snapshot.ownerName = nil
            publish()
        }
    }

    func stopForSafety(reason: String) async {
        snapshot.lastStopReason = reason
        isPressed = false
        generation += 1
        if let leaseId = snapshot.leaseId {
            await control.cancelRxReady(leaseId: leaseId)
            if snapshot.state == .transmitting {
                await finishTransmission(leaseId: leaseId, playEndCue: false, nextState: .error, error: reason)
            } else {
                await discardActiveBuffered()
                try? await control.publishEnd(leaseId: leaseId)
                try? await floor.release(leaseId: leaseId)
                clearLease(nextState: .error)
                snapshot.lastError = reason
                publish()
            }
        } else {
            await discardActiveBuffered()
            try? await microphone.setMicrophoneEnabled(false)
            cancelTimers()
            snapshot.state = role.canPublish ? .error : .rxOnly
            snapshot.lastError = reason
            publish()
        }
    }

    func resetAfterReconnect() {
        guard snapshot.state == .error else { return }
        snapshot.state = role.canPublish ? .idle : .rxOnly
        publish()
    }

    private func startLeaseTasks(leaseId: String, operation: Int, response: FloorResponse) {
        cancelTimers()
        renewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(milliseconds: Self.renewIntervalMilliseconds)
                    guard !Task.isCancelled else { return }
                    await renew(leaseId: leaseId, operation: operation)
                } catch { return }
            }
        }

        let serverDuration = response.acquiredAt.flatMap { acquired in
            response.maxTxExpiresAt.map { max(0, Int($0.timeIntervalSince(acquired) * 1_000)) }
        } ?? Self.maxContinuousTxMilliseconds
        let duration = min(Self.maxContinuousTxMilliseconds, serverDuration)
        maxTxTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(milliseconds: duration)
                guard !Task.isCancelled else { return }
                await maxTxReached(leaseId: leaseId, operation: operation)
            } catch {}
        }
    }

    private func renew(leaseId: String, operation: Int) async {
        guard operation == generation,
              snapshot.leaseId == leaseId,
              ((isPressed && (snapshot.state == .requestingFloor || snapshot.state == .transmitting)) ||
               snapshot.state == .releasing) else { return }
        if snapshot.state == .releasing {
            snapshot.txFloorRenewDuringReleaseCount += 1
        }
        snapshot.floorRenewAttemptCount += 1
        snapshot.floorLastRenewStartedAt = clock.now
        snapshot.floorLastRenewResult = "in_progress"
        snapshot.floorLastRenewError = nil
        publish()
        do {
            let response = try await floor.renew(leaseId: leaseId)
            guard operation == generation,
                  response.outcome == .renewed,
                  response.leaseId == leaseId,
                  response.isOwner else {
                throw PTTError.leaseLost
            }
            snapshot.leaseExpiresAt = response.leaseExpiresAt
            snapshot.maxTxExpiresAt = response.maxTxExpiresAt
            snapshot.floorRenewSuccessCount += 1
            snapshot.floorLastRenewCompletedAt = clock.now
            snapshot.floorLastRenewResult = "renewed"
            publish()
        } catch {
            snapshot.floorLastRenewCompletedAt = clock.now
            snapshot.floorLastRenewResult = "failed"
            snapshot.floorLastRenewError = Self.safeMessage(error)
            snapshot.lastStopReason = "floor_renew_failed"
            if snapshot.state == .releasing {
                snapshot.lastError = "Floor renew failed during release: \(Self.safeMessage(error))"
                snapshot.txErrorRecoverable = true
                publish()
            } else {
                isPressed = false
                generation += 1
                await finishTransmission(
                    leaseId: leaseId,
                    playEndCue: false,
                    nextState: .error,
                    error: "Floor renew failed: \(Self.safeMessage(error))"
                )
            }
        }
    }

    private func maxTxReached(leaseId: String, operation: Int) async {
        guard operation == generation,
              (snapshot.state == .requestingFloor || snapshot.state == .transmitting) else { return }
        isPressed = false
        generation += 1
        snapshot.lastStopReason = "max_continuous_tx"
        await finishTransmission(
            leaseId: leaseId,
            playEndCue: true,
            nextState: .idle,
            error: "Maximum continuous TX reached (60 seconds)."
        )
    }

    private func finishTransmission(
        leaseId: String,
        playEndCue: Bool,
        nextState: PTTState,
        error: String?
    ) async {
        cancelMaxTxTimer()
        if snapshot.state != .releasing { enterReleasing() }
        var microphoneIsOff = false
        let wasBuffered = activeBufferedGenerationId != nil
        var terminalError = error
        do {
            if let bufferedGenerationId = activeBufferedGenerationId {
                snapshot.txReleasePhase = "FINALIZING_BUFFERED_AUDIO"
                publish()
                try await bufferedAudio?.finish(generationId: bufferedGenerationId)
                activeBufferedGenerationId = nil
                snapshot.txFinalMarkerAcceptedSequence = nextReleaseSequence()
                snapshot.txReleasePhase = "FINAL_MARKER_ACCEPTED"
            } else {
                try await microphone.setMicrophoneEnabled(false)
            }
            microphoneIsOff = true
            snapshot.microphoneMutedAt = clock.now
        } catch {
            if wasBuffered {
                await discardActiveBuffered()
                microphoneIsOff = true
            }
            snapshot.lastError = "TX OFF failed: \(Self.safeMessage(error))"
            terminalError = snapshot.lastError
            snapshot.txErrorRecoverable = microphoneIsOff
        }

        // Terminal authority order is strict: final marker, control END, then Floor release.
        if microphoneIsOff {
            snapshot.txReleasePhase = "PUBLISHING_CONTROL_END"
            do {
                try await control.publishEnd(leaseId: leaseId)
                snapshot.controlEndResult = "Published"
                snapshot.controlEndPublishedAt = clock.now
                snapshot.txControlEndPublishedSequence = nextReleaseSequence()
            } catch {
                snapshot.controlEndResult = "Failed: \(Self.safeMessage(error))"
                terminalError = "Control END failed: \(Self.safeMessage(error))"
                snapshot.txErrorRecoverable = true
            }
        }
        if playEndCue, microphoneIsOff, localCueEnabled {
            do {
                try await cuePlayer.playEnd()
                snapshot.endCueResult = .success
            } catch {
                snapshot.endCueResult = .failure(Self.safeMessage(error))
            }
        }

        snapshot.txReleasePhase = "RELEASING_FLOOR"
        snapshot.floorReleaseRequestedAt = clock.now
        snapshot.txFloorReleaseRequestedSequence = nextReleaseSequence()
        publish()
        do {
            try await floor.release(leaseId: leaseId)
        } catch {
            terminalError = "Floor release failed: \(Self.safeMessage(error))"
            snapshot.lastError = terminalError
            snapshot.txErrorRecoverable = false
        }
        snapshot.floorReleaseCompletedAt = clock.now
        snapshot.txFloorReleaseCompletedSequence = nextReleaseSequence()
        cancelRenewTimer()
        generation += 1
        let safeNextState: PTTState = snapshot.txErrorRecoverable == false ? .error : nextState
        clearLease(nextState: safeNextState)
        snapshot.txReleasePhase = "COMPLETE"
        snapshot.txReleaseCompletedSequence = nextReleaseSequence()
        snapshot.txTerminalCleanupComplete = true
        snapshot.txReleaseResult = terminalError == nil ? "PASS" : "RECOVERED_WITH_ERROR"
        if let terminalError { snapshot.lastError = terminalError }
        publish()
    }

    private func enterReleasing() {
        snapshot.state = .releasing
        snapshot.txReleasePhase = "RELEASING"
        snapshot.txReleaseAttemptGeneration = generation
        snapshot.txReleaseEnteredSequence = nextReleaseSequence()
        snapshot.txFloorRenewDuringReleaseCount = 0
        snapshot.txFinalMarkerAcceptedSequence = nil
        snapshot.txControlEndPublishedSequence = nil
        snapshot.txFloorReleaseRequestedSequence = nil
        snapshot.txFloorReleaseCompletedSequence = nil
        snapshot.txReleaseCompletedSequence = nil
        snapshot.txReleaseResult = "IN_PROGRESS"
        snapshot.txTerminalCleanupComplete = false
        snapshot.txErrorRecoverable = nil
        publish()
    }

    private func nextReleaseSequence() -> Int {
        snapshot.txReleaseEventSequence += 1
        return snapshot.txReleaseEventSequence
    }

    private func clearLease(nextState: PTTState) {
        cancelTimers()
        preparedResponse = nil
        preparedOperation = nil
        snapshot.state = nextState
        snapshot.leaseId = nil
        snapshot.ownerName = nil
        snapshot.leaseExpiresAt = nil
        snapshot.maxTxExpiresAt = nil
        localCueEnabled = true
        publish()
    }

    private func discardActiveBuffered() async {
        guard let generationId = activeBufferedGenerationId else { return }
        await bufferedAudio?.discard(generationId: generationId)
        activeBufferedGenerationId = nil
    }

    private func clearLeaseIfCurrentSnapshot(operation: Int, nextState: PTTState) {
        guard generation == operation,
              snapshot.attemptGeneration == operation else { return }
        clearLease(nextState: nextState)
    }

    private func cancelTimers() {
        renewTask?.cancel()
        maxTxTask?.cancel()
        renewTask = nil
        maxTxTask = nil
    }

    private func cancelRenewTimer() {
        renewTask?.cancel()
        renewTask = nil
    }

    private func cancelMaxTxTimer() {
        maxTxTask?.cancel()
        maxTxTask = nil
    }

    private func publish() { onUpdate(snapshot) }

    private static func safeMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }
}

private enum PTTError: LocalizedError {
    case leaseLost

    var errorDescription: String? { "Floor lease is no longer owned by this session." }
}
