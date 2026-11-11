import XCTest
@testable import KOEON

@MainActor
final class RuntimeRestorePipelineTests: XCTestCase {
    func testActionButtonIntentColdSessionRejectsWithoutWaitingOrQueueing() async {
        let suite = "ActionButtonIntent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IntercomSessionController(api: ResumeCleanupAPIStub(),
            pushToTalk: ApplePushToTalkController(defaults: defaults), audioPublishDefaults: defaults)
        let unavailableByDefault = await controller.toggleActionButtonPttFromIntent()
        XCTAssertEqual(unavailableByDefault, .unavailable)
        XCTAssertTrue(controller.actionButtonPttEnabled)
        controller.setActionButtonPttEnabled(true)
        let unavailable = await controller.toggleActionButtonPttFromIntent()
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertEqual(controller.pttRequestGateState, .idle)
        XCTAssertFalse(controller.isPoweredOn)
        XCTAssertFalse(controller.isJoined)
    }

    func testActionButtonColdSessionRejectsWithoutQueuedTransmitOrPowerOn() {
        let suite = "ActionButton-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IntercomSessionController(api: ResumeCleanupAPIStub(),
            pushToTalk: ApplePushToTalkController(defaults: defaults), audioPublishDefaults: defaults)
        XCTAssertTrue(controller.actionButtonPttEnabled)
        XCTAssertEqual(controller.toggleActionButtonPtt(), .unavailable)
        controller.setActionButtonPttEnabled(true)
        controller.appLifecycleDidChange("background")
        for _ in 0..<5 { XCTAssertEqual(controller.toggleActionButtonPtt(), .unavailable) }
        XCTAssertFalse(controller.isPoweredOn)
        XCTAssertFalse(controller.isJoined)
        XCTAssertEqual(controller.pttRequestGateState, .idle)
        XCTAssertTrue(defaults.bool(forKey: "ptt.actionButtonEnabled"))
        controller.setActionButtonPttEnabled(false)
        XCTAssertEqual(controller.toggleActionButtonPtt(), .disabled)
        XCTAssertFalse(defaults.bool(forKey: "ptt.actionButtonEnabled"))
    }

    func testSavedActionButtonOffIsNotOverriddenByDefault() {
        let suite = "ActionButtonSavedOff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "ptt.actionButtonEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IntercomSessionController(api: ResumeCleanupAPIStub(),
            pushToTalk: ApplePushToTalkController(defaults: defaults), audioPublishDefaults: defaults)
        XCTAssertFalse(controller.actionButtonPttEnabled)
        XCTAssertEqual(controller.toggleActionButtonPtt(), .disabled)
        XCTAssertFalse(controller.isPoweredOn)
    }

    func testFailedResumePreservesPushUntilExplicitPowerOff() async {
        let api = ResumeCleanupAPIStub()
        let controller = isolatedResumeController(api: api)
        let result = await controller.establishResumedRuntime(invalidResumeResponse("fresh"))
        XCTAssertFalse(result)
        XCTAssertTrue(api.listening, "A connection failure must not revoke the next incoming push")
        XCTAssertEqual(api.cleanupCalls, [])
        await controller.leave()
        XCTAssertFalse(api.listening)
        XCTAssertEqual(api.cleanupCalls, ["unregister:fresh", "leave:fresh"])
        await controller.leave()
        XCTAssertEqual(api.cleanupCalls.count, 2, "A stopped failed runtime has no remaining backend ownership")
    }

    func testRepeatedResumeFailuresOnlyLeaveLatestSessionOnPowerOff() async {
        let api = ResumeCleanupAPIStub()
        let controller = isolatedResumeController(api: api)
        for id in ["first", "second"] {
            let result = await controller.establishResumedRuntime(invalidResumeResponse(id))
            XCTAssertFalse(result)
            XCTAssertTrue(api.listening)
        }
        XCTAssertEqual(api.cleanupCalls, [])
        await controller.leave()
        XCTAssertEqual(api.cleanupCalls, ["unregister:second", "leave:second"])
    }

    func testCancelledResumeStillLeavesItsBackendSessionAtExplicitStop() async {
        let api = ResumeCleanupAPIStub()
        let controller = isolatedResumeController(api: api)
        let response = invalidResumeResponse("cancelled")
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return await controller.establishResumedRuntime(response)
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(api.cleanupCalls, [])
        await controller.leave()
        XCTAssertEqual(api.cleanupCalls, ["unregister:cancelled", "leave:cancelled"])
    }

    func testFailedResumePersistsLatestSessionForPowerOffAfterColdLaunch() async {
        let suite = "ResumeListening-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PttRestoreDescriptor(channelId: "stage", channelName: "Stage",
            channelUUID: PushToTalkChannelUUID.make(channelId: "stage"),
            canPublish: true, lastBackendSessionId: "previous").persist(to: defaults)
        XCTAssertEqual(PttRestoreDescriptor.load(from: defaults)?.lastBackendSessionId, "previous")
        let api = ResumeCleanupAPIStub()
        let controller = IntercomSessionController(api: api,
            pushToTalk: ApplePushToTalkController(defaults: defaults))
        let result = await controller.establishResumedRuntime(invalidResumeResponse("fresh"))
        XCTAssertFalse(result)
        XCTAssertEqual(PttRestoreDescriptor.load(from: defaults)?.lastBackendSessionId, "fresh")
        XCTAssertEqual(api.cleanupCalls, [])
        // A new app instance has no joined/pending runtime, only the descriptor.
        let relaunched = IntercomSessionController(api: api,
            pushToTalk: ApplePushToTalkController(defaults: defaults))
        await relaunched.leave()
        XCTAssertEqual(api.cleanupCalls, ["unregister:fresh", "leave:fresh"])
        XCTAssertNil(PttRestoreDescriptor.load(from: defaults))
    }

    func testBackendJoinExpiryRequiresFreshResumeEvenWhileLiveKitConnected() {
        let error = APIClientError.http(401, #"{"error":{"code":"SESSION_INVALID","message":"expired"}}"#)
        XCTAssertTrue(shouldRestoreExpiredBackendSession(error, requestedSessionId: "old", currentSessionId: "old", poweredOn: true))
        XCTAssertEqual(runtimeRestoreEntryDecision(reason: .backendSessionExpired,
            hasJoinedRuntime: true, connectionState: .connected), .performFreshResume)
    }

    func testLateExpiryCannotResumeAfterPowerOffOrNewSession() {
        let error = APIClientError.http(401, #"{"error":{"code":"SESSION_INVALID"}}"#)
        XCTAssertFalse(shouldRestoreExpiredBackendSession(error, requestedSessionId: "old", currentSessionId: "new", poweredOn: true))
        XCTAssertFalse(shouldRestoreExpiredBackendSession(error, requestedSessionId: "old", currentSessionId: "old", poweredOn: false))
    }

    func testOtherAuthenticationAndMalformedErrorsAreNotJoinExpiry() {
        let errors: [Error] = [
            APIClientError.http(401, #"{"error":{"code":"DEVICE_REVOKED"}}"#),
            APIClientError.http(403, #"{"error":{"code":"SESSION_INVALID"}}"#),
            APIClientError.http(401, "SESSION_INVALID"),
            APIClientError.invalidResponse,
        ]
        for error in errors {
            XCTAssertFalse(shouldRestoreExpiredBackendSession(error, requestedSessionId: "old", currentSessionId: "old", poweredOn: true))
        }
    }

    func testStartupTransportFailurePreservesCredentialAndCanRetry() async {
        let api = ResumeCleanupAPIStub()
        let store = StartupCredentialStub()
        let controller = IntercomSessionController(api: api, credentialStore: store,
            pushToTalk: ApplePushToTalkController(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        for error: Error in [URLError(.notConnectedToInternet), APIClientError.http(503, "unavailable"),
                             APIClientError.http(401, "proxy unauthorized")] {
            api.meError = error
            await controller.loadFixture()
            XCTAssertEqual(store.clearCount, 0)
            XCTAssertNotNil(store.read())
            XCTAssertFalse(controller.enrollmentRequired)
            XCTAssertNotNil(controller.lastError)
        }
        api.meError = nil
        api.meResponse = MeResponse(user: IdentityUser(id: "user", displayName: "Test", role: .staff),
            workspace: IdentityWorkspace(id: "workspace", name: "Workspace"),
            device: IdentityDevice(id: "device", name: nil, platform: "ios"),
            channels: [IdentityChannel(id: "stage", name: "Stage", type: "INTERCOM")])
        await controller.loadFixture()
        XCTAssertNotNil(controller.fixture)
        XCTAssertNil(controller.lastError)
        XCTAssertFalse(controller.enrollmentRequired)
        XCTAssertEqual(store.clearCount, 0)
    }

    func testStartupCancellationDoesNotEraseCredential() async {
        let api = ResumeCleanupAPIStub(); api.meError = CancellationError()
        let store = StartupCredentialStub()
        let controller = IntercomSessionController(api: api, credentialStore: store,
            pushToTalk: ApplePushToTalkController(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        await controller.loadFixture()
        XCTAssertEqual(store.clearCount, 0)
        XCTAssertNotNil(store.read())
        XCTAssertFalse(controller.enrollmentRequired)
    }

    func testStartupExplicitCredentialExpiryRequiresEnrollment() async {
        for code in ["DEVICE_CREDENTIAL_INVALID", "DEVICE_CREDENTIAL_EXPIRED"] {
            let api = ResumeCleanupAPIStub()
            api.meError = APIClientError.http(401, "{\"error\":{\"code\":\"\(code)\"}}")
            let store = StartupCredentialStub()
            let controller = IntercomSessionController(api: api, credentialStore: store,
                pushToTalk: ApplePushToTalkController(defaults: UserDefaults(suiteName: UUID().uuidString)!))
            await controller.loadFixture()
            XCTAssertEqual(store.clearCount, 1)
            XCTAssertNil(store.read())
            XCTAssertTrue(controller.enrollmentRequired)
        }
    }

    func testStartupLateUnauthorizedResponseCannotEraseReplacedCredential() async throws {
        let api = ResumeCleanupAPIStub()
        api.meError = APIClientError.http(401, #"{"error":{"code":"DEVICE_CREDENTIAL_INVALID"}}"#)
        let gate = StartupMeGate()
        api.beforeMe = { await gate.wait() }
        let store = StartupCredentialStub()
        let controller = IntercomSessionController(api: api, credentialStore: store,
            pushToTalk: ApplePushToTalkController(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let task = Task { await controller.loadFixture() }
        while !(await gate.started) { await Task.yield() }
        try store.write("replacement-device-credential-1234567890")
        await gate.release()
        await task.value
        XCTAssertEqual(store.read(), "replacement-device-credential-1234567890")
        XCTAssertEqual(store.clearCount, 0)
        XCTAssertFalse(controller.enrollmentRequired)
    }

    private func isolatedResumeController(api: ResumeCleanupAPIStub) -> IntercomSessionController {
        IntercomSessionController(api: api,
            pushToTalk: ApplePushToTalkController(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    private func invalidResumeResponse(_ id: String) -> JoinResponse {
        // The real SDK rejects this scheme before opening any network connection.
        JoinResponse(sessionId: id, livekitUrl: "not-a-livekit-url", token: "fixture",
            roomName: "stage", user: User(id: "user", workspaceId: "workspace", name: "User",
                role: .staff, channelIds: ["stage"]),
            channel: Channel(id: "stage", workspaceId: "workspace", name: "Stage"),
            canPublish: true, tokenExpiresInSeconds: 300, deviceId: "device")
    }

    func testPowerIntentSurvivesFailedRuntimeReplacementAndAllowsRetry() async throws {
        var intent = RuntimeRecoveryIntent()
        intent.powerOn()
        var session: String? = "old"
        XCTAssertTrue(intent.beginRestore())
        let result = try await performFreshRuntimeRestore(
            requestFreshSession: { "fresh" },
            onFreshSessionReceived: { (_: String) in },
            teardownStaleRuntime: { session = nil },
            establishFreshRuntime: { _ in false })
        XCTAssertFalse(result)
        XCTAssertNil(session)
        XCTAssertTrue(intent.isPoweredOn, "A failed connection must not look like POWER OFF")
        XCTAssertEqual(intent.nextRetryDelay(isForeground: true), 1)
        XCTAssertTrue(intent.beginRestore())
        let recovered = try await performFreshRuntimeRestore(
            requestFreshSession: { "retry" }, onFreshSessionReceived: { (_: String) in },
            teardownStaleRuntime: {}, establishFreshRuntime: { session = $0; return true })
        XCTAssertTrue(recovered)
        intent.powerOn()
        XCTAssertEqual(session, "retry")
        XCTAssertEqual(intent.retryAttempt, 0)
    }

    func testRuntimeRetriesAreBoundedAndDeferredWhileBackgrounded() {
        var intent = RuntimeRecoveryIntent()
        XCTAssertTrue(intent.beginRestore(), "Cold Apple channel restoration remains supported")
        XCTAssertNil(intent.nextRetryDelay(isForeground: false))
        XCTAssertEqual(intent.retryAttempt, 0)
        XCTAssertEqual(intent.nextRetryDelay(isForeground: true), 1)
        XCTAssertEqual(intent.nextRetryDelay(isForeground: true), 2)
        XCTAssertEqual(intent.nextRetryDelay(isForeground: true), 4)
        XCTAssertNil(intent.nextRetryDelay(isForeground: true))
        XCTAssertTrue(intent.isPoweredOn)
        intent.resetRetries()
        XCTAssertEqual(intent.nextRetryDelay(isForeground: true), 1)
        intent.powerOff()
        XCTAssertFalse(intent.beginRestore(), "Late pushes must not undo explicit POWER OFF")
        XCTAssertNil(intent.nextRetryDelay(isForeground: true))
    }

    func testRetryKeepsDescriptorWhenSystemChannelWasLeftForSelfHeal() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let descriptor = PttRestoreDescriptor(channelId: "channel", channelName: "Channel",
            channelUUID: PushToTalkChannelUUID.make(channelId: "channel"), canPublish: true,
            lastBackendSessionId: "old-session")
        descriptor.persist(to: defaults)
        var intent = RuntimeRecoveryIntent()
        XCTAssertTrue(intent.beginRestore(descriptor))
        PttRestoreDescriptor.clear(from: defaults)
        XCTAssertNil(PttRestoreDescriptor.load(from: defaults))
        XCTAssertEqual(intent.descriptor, descriptor)
        XCTAssertEqual(intent.nextRetryDelay(isForeground: true), 1)
        intent.powerOff()
        XCTAssertNil(intent.descriptor)
    }

    func testPowerOffDuringFreshResponsePreventsLateRuntimeReestablishment() async {
        var intent = RuntimeRecoveryIntent()
        intent.powerOn()
        var continuation: CheckedContinuation<String, Never>?
        var teardownCalled = false
        var established = false
        var discarded: String?
        let task = Task { @MainActor in
            try await performFreshRuntimeRestore(
                requestFreshSession: { await withCheckedContinuation { continuation = $0 } },
                onFreshSessionReceived: { (_: String) in },
                teardownStaleRuntime: { teardownCalled = true },
                establishFreshRuntime: { _ in established = true; return true },
                discardFreshSession: { discarded = $0 })
        }
        while continuation == nil { await Task.yield() }
        intent.powerOff()
        task.cancel()
        continuation?.resume(returning: "late response")
        do {
            _ = try await task.value
            XCTFail("Cancelled restore must not reconnect")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(teardownCalled)
        XCTAssertFalse(established)
        XCTAssertEqual(discarded, "late response")
        XCTAssertFalse(intent.isPoweredOn)
        XCTAssertFalse(intent.beginRestore())
    }

    func testCancellationDuringTeardownDoesNotCreateReplacementRuntime() async {
        var continuation: CheckedContinuation<Void, Never>?
        var established = false
        var discarded = false
        let task = Task { @MainActor in
            try await performFreshRuntimeRestore(
                requestFreshSession: { "fresh" }, onFreshSessionReceived: { (_: String) in },
                teardownStaleRuntime: { await withCheckedContinuation { continuation = $0 } },
                establishFreshRuntime: { _ in established = true; return true },
                discardFreshSession: { _ in discarded = true })
        }
        while continuation == nil { await Task.yield() }
        task.cancel()
        continuation?.resume()
        do {
            _ = try await task.value
            XCTFail("Cancelled teardown must not be followed by connect")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(established)
        XCTAssertTrue(discarded)
    }

    func testDDirtyConnectedNeverBecomesWarmOnTransientActive() {
        var runtime = RuntimeLiveness()
        runtime.beginRuntime()
        runtime.validate(bindingsReady: true)
        XCTAssertFalse(runtime.dirty)
        runtime.invalidate()
        for lifecycle in ["background", "inactive", "active"] {
            XCTAssertEqual(incomingPushRuntimeAction(hasJoinedRuntime: true, connectionState: .connected,
                appLifecycleState: lifecycle, runtimeDirty: runtime.dirty), .awaitReconnectThenResume)
        }
        runtime.validate(bindingsReady: false)
        XCTAssertTrue(runtime.dirty)
        XCTAssertEqual(runtimeRestoreEntryDecision(reason: .foregroundRecovery, hasJoinedRuntime: true,
            connectionState: .connected, runtimeDirty: runtime.dirty), .performFreshResume)
        runtime.beginRuntime()
        runtime.validate(bindingsReady: true)
        XCTAssertFalse(runtime.dirty)
        XCTAssertEqual(runtime.validatedGeneration, runtime.generation)
    }

    func testDDiagnosticCurrentNeverInheritsCompletedAttemptFields() {
        var ledger = LifecycleAttemptLedger()
        let first = Date(timeIntervalSince1970: 10)
        ledger.begin(generation: 1, channelId: "stage", sessionGeneration: 1, at: first)
        ledger.finish(at: first.addingTimeInterval(1))
        ledger.begin(generation: 2, channelId: "stage", sessionGeneration: 2, at: first.addingTimeInterval(3))
        XCTAssertEqual(ledger.lastCompleted?.generation, 1)
        XCTAssertEqual(ledger.current?.generation, 2)
        XCTAssertNil(ledger.current?.completedAt)
        XCTAssertNotEqual(ledger.current?.channelHash, "stage")
        XCTAssertLessThan(ledger.lastCompleted!.completedAt!, ledger.current!.startedAt)
    }

    func testDNoMediaEscalatesThroughFreshRuntimeAndFencesOldGeneration() async throws {
        for resolved in [true, false] {
            var liveness = RuntimeLiveness()
            liveness.beginRuntime()
            let oldRuntime = liveness.generation
            var consistency = RxConsistencyGuard()
            let start = Date(timeIntervalSince1970: 1_000)
            consistency.updateValidatedRx(active: true, sessionId: "remote", generation: 1,
                participantResolved: resolved, trackSubscribed: false, at: start)
            var levels: [Int] = []
            for time in [0.25, 0.75, 1.5, 2.5] {
                levels.append(consistency.evaluate(at: start.addingTimeInterval(time)).recoveryLevel)
            }
            XCTAssertEqual(levels, [1, 2, 3, 4])
            XCTAssertFalse(consistency.snapshot.validatedRemoteRxActive)
            var stages: [String] = []
            let result = try await performFreshRuntimeRestore(
                requestFreshSession: { stages.append("resume"); return "new-local-session" },
                onFreshSessionReceived: { (_: String) in },
                teardownStaleRuntime: {
                    stages.append("teardown")
                    liveness.beginRuntime()
                    consistency.reset()
                },
                establishFreshRuntime: { _ in
                    stages.append("bind-current-track")
                    consistency.updateValidatedRx(active: true, sessionId: "remote", generation: 2,
                        participantResolved: true, trackSubscribed: true, at: start)
                    liveness.validate(bindingsReady: true)
                    return true
                })
            XCTAssertTrue(result)
            XCTAssertEqual(stages, ["resume", "teardown", "bind-current-track"])
            XCTAssertNotEqual(oldRuntime, liveness.generation)
            XCTAssertEqual(consistency.handleRemotePcm(sessionId: "remote", generation: 1, at: start), .rejected)
            XCTAssertEqual(consistency.handleRemotePcm(sessionId: "remote", generation: 2, at: start), .observed)
            XCTAssertEqual(consistency.snapshot.pathState, "PCM_FLOWING")
        }
    }

    func testQ1BackgroundStaleConnectedRunsResumeTeardownAndFreshConnectExactlyOnce() async throws {
        XCTAssertEqual(runtimeRestoreEntryDecision(
            reason: .incomingPushColdWake,
            hasJoinedRuntime: true,
            connectionState: .connected
        ), .performFreshResume)

        var resumeCount = 0
        var teardownCount = 0
        var connectCount = 0
        var events: [String] = []
        let established = try await performFreshRuntimeRestore(
            requestFreshSession: {
                resumeCount += 1
                events.append("api.resume")
                return "fresh-session"
            },
            onFreshSessionReceived: { response in
                XCTAssertEqual(response, "fresh-session")
                events.append("resume.response")
            },
            teardownStaleRuntime: {
                teardownCount += 1
                events.append("old-runtime.teardown")
            },
            establishFreshRuntime: { response in
                connectCount += 1
                events.append("fresh-livekit.connect:\(response)")
                return true
            }
        )

        XCTAssertTrue(established)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(teardownCount, 1)
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(events, [
            "api.resume", "resume.response", "old-runtime.teardown",
            "fresh-livekit.connect:fresh-session",
        ])
    }

    func testQ2ActiveConnectedKeepsWarmRuntime() {
        XCTAssertEqual(runtimeRestoreEntryDecision(
            reason: .systemChannelRestoration,
            hasJoinedRuntime: true,
            connectionState: .connected
        ), .useConnectedRuntime)
    }

    func testQ3BackgroundDisconnectedRequiresFreshResume() {
        XCTAssertEqual(runtimeRestoreEntryDecision(
            reason: .incomingPushColdWake,
            hasJoinedRuntime: true,
            connectionState: .disconnected
        ), .performFreshResume)
    }

    func testQ4BackgroundReconnectingRequiresFreshResume() {
        XCTAssertEqual(runtimeRestoreEntryDecision(
            reason: .incomingPushColdWake,
            hasJoinedRuntime: true,
            connectionState: .reconnecting
        ), .performFreshResume)
    }

    func testQ5DuplicateRestoreIsSingleFlight() {
        var gate = RuntimeRestoreSingleFlightGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.finish()
        XCTAssertTrue(gate.begin())
    }

    func testQ6RetryableFailureDoesNotPoisonNextRestore() async {
        enum Retryable: Error { case unavailable }
        var gate = RuntimeRestoreSingleFlightGate()
        XCTAssertTrue(gate.begin())
        let failingRequest: () async throws -> String = { throw Retryable.unavailable }
        do {
            _ = try await performFreshRuntimeRestore(
                requestFreshSession: failingRequest,
                onFreshSessionReceived: { (_: String) in },
                teardownStaleRuntime: {},
                establishFreshRuntime: { _ in true }
            )
            XCTFail("Expected retryable failure")
        } catch {
            gate.finish()
        }
        XCTAssertTrue(gate.begin())
    }

    func testQ7OnlyIdentityStatusesAreTerminal() {
        XCTAssertTrue(isTerminalRuntimeRestoreError(APIClientError.http(401, "unauthorized")))
        XCTAssertTrue(isTerminalRuntimeRestoreError(APIClientError.http(403, "forbidden")))
        XCTAssertTrue(isTerminalRuntimeRestoreError(APIClientError.http(404, "missing")))
        XCTAssertFalse(isTerminalRuntimeRestoreError(APIClientError.http(503, "retry")))
    }

    func testQ8AppleActivationOwnershipIsNotPartOfRuntimeSwap() async throws {
        var operations: [String] = []
        _ = try await performFreshRuntimeRestore(
            requestFreshSession: { operations.append("resume"); return 1 },
            onFreshSessionReceived: { _ in operations.append("response") },
            teardownStaleRuntime: { operations.append("livekit.disconnect") },
            establishFreshRuntime: { _ in operations.append("livekit.connect"); return true }
        )
        XCTAssertEqual(operations, ["resume", "response", "livekit.disconnect", "livekit.connect"])
    }

    func testQ9CurrentIncomingEventCanBeReappliedAfterRuntimeSwap() async throws {
        var incomingEventAppliedToFreshRuntime = false
        _ = try await performFreshRuntimeRestore(
            requestFreshSession: { "fresh" },
            onFreshSessionReceived: { (_: String) in },
            teardownStaleRuntime: {},
            establishFreshRuntime: { _ in
                incomingEventAppliedToFreshRuntime = true
                return true
            }
        )
        XCTAssertTrue(incomingEventAppliedToFreshRuntime)
    }

    func testQ10ForegroundConnectedPolicyRemainsWarmAndDisconnectedRestores() {
        XCTAssertEqual(foregroundRuntimeRecoveryAction(
            hasJoinedRuntime: true, connectionState: .connected
        ), .keepConnectedRuntime)
        XCTAssertEqual(foregroundRuntimeRecoveryAction(
            hasJoinedRuntime: true, connectionState: .disconnected
        ), .requestPersistedRuntimeRestore)
    }

    func testR9Task003QStaleConnectedRegressionRemainsFresh() {
        XCTAssertEqual(runtimeRestoreEntryDecision(
            reason: .incomingPushColdWake,
            hasJoinedRuntime: true,
            connectionState: .connected
        ), .performFreshResume)
    }

    func testF1ValidCachedCredentialAllowsFastReconnectWithSameSessionIdentity() {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = cachedResponse(sessionId: "session-stable", expiresAt: now.addingTimeInterval(300))
        let descriptor = PttRestoreDescriptor(
            channelId: "stage", channelName: "Stage",
            channelUUID: PushToTalkChannelUUID.make(channelId: "stage"), canPublish: false,
            lastBackendSessionId: "session-stable"
        )
        XCTAssertTrue(canUseFastColdReconnect(cached: response, descriptor: descriptor, now: now))
        XCTAssertEqual(response.sessionId, descriptor.lastBackendSessionId)
    }

    func testF2ExpiredOrMismatchedCredentialRequiresFullResumeFallback() {
        let now = Date(timeIntervalSince1970: 1_000)
        let descriptor = PttRestoreDescriptor(
            channelId: "stage", channelName: "Stage",
            channelUUID: PushToTalkChannelUUID.make(channelId: "stage"), canPublish: false,
            lastBackendSessionId: "session-old"
        )
        XCTAssertFalse(canUseFastColdReconnect(
            cached: cachedResponse(sessionId: "session-old", expiresAt: now.addingTimeInterval(20)),
            descriptor: descriptor, now: now
        ))
        XCTAssertFalse(canUseFastColdReconnect(
            cached: cachedResponse(sessionId: "session-new", expiresAt: now.addingTimeInterval(300)),
            descriptor: descriptor, now: now
        ))
    }

    func testR11R12StableDeviceReadySurvivesSessionRotationAndRejectsUnboundClaim() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(
            leaseId: "lease-a",
            expectedSessionIds: ["session-old"],
            expectedDeviceIds: ["device-stable"]
        )
        let event = PttRxReadyEvent(
            version: 1, type: "rx_ready", channelId: "stage",
            speakerSessionId: "speaker", receiverSessionId: "session-new",
            receiverDeviceId: "device-stable", leaseId: "lease-a", readyAt: 1
        )
        await barrier.accept(
            event, participantIdentity: "session-new", participantDeviceId: "wrong-device"
        )
        await barrier.accept(
            event, participantIdentity: "session-new", participantDeviceId: "device-stable"
        )
        let result = await barrier.wait(leaseId: "lease-a", maximumWaitMilliseconds: 10)
        XCTAssertEqual(result.expectedCount, 1)
        XCTAssertEqual(result.receivedCount, 1)
        XCTAssertFalse(result.timedOut)
    }

    func testReadyIsDeferredUntilMatchingSDKDeviceMetadataArrives() async {
        for metadataArrives in [false, true] {
            let barrier = PttRxReadyBarrier()
            await barrier.prepare(leaseId: "lease", expectedSessionIds: ["old"], expectedDeviceIds: ["device"])
            await barrier.accept(metadataReady(), participantIdentity: "session", participantDeviceId: nil)
            if metadataArrives {
                await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
            }
            let result = await barrier.wait(leaseId: "lease", maximumWaitMilliseconds: 0)
            XCTAssertEqual(result.receivedCount, metadataArrives ? 1 : 0)
            XCTAssertEqual(result.timedOut, !metadataArrives)
        }
    }

    func testReadyMetadataNeverAuthenticatesMissingOrMismatchedSessionClaims() async {
        for identity: String? in [nil, "", "other-session"] {
            let barrier = PttRxReadyBarrier()
            await barrier.prepare(leaseId: "lease", expectedSessionIds: [], expectedDeviceIds: ["device"])
            await barrier.accept(metadataReady(), participantIdentity: identity, participantDeviceId: nil)
            await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
            let result = await barrier.wait(leaseId: "lease", maximumWaitMilliseconds: 0)
            XCTAssertEqual(result.receivedCount, 0)
            XCTAssertTrue(result.timedOut)
        }
    }

    func testReadyMetadataRejectsWrongLeaseDeviceAndContradictoryMetadata() async {
        for condition in ["wrong-lease", "unknown-device", "wrong-metadata"] {
            let barrier = PttRxReadyBarrier()
            await barrier.prepare(leaseId: "lease", expectedSessionIds: [], expectedDeviceIds: ["device"])
            let event = metadataReady(lease: condition == "wrong-lease" ? "other-lease" : "lease",
                                      device: condition == "unknown-device" ? "other-device" : "device")
            await barrier.accept(event, participantIdentity: "session", participantDeviceId: nil)
            if condition == "wrong-metadata" {
                await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "wrong-device")
            }
            await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
            let result = await barrier.wait(leaseId: "lease", maximumWaitMilliseconds: 0)
            XCTAssertEqual(result.receivedCount, 0, condition)
        }
    }

    func testUnrelatedMetadataCannotConsumeAnotherReceiversPendingReady() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(leaseId: "lease", expectedSessionIds: [], expectedDeviceIds: ["device"])
        await barrier.accept(metadataReady(), participantIdentity: "session", participantDeviceId: nil)
        await barrier.reconcileParticipant(participantIdentity: "other-session", participantDeviceId: "device")
        await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
        await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
        let result = await barrier.wait(leaseId: "lease", maximumWaitMilliseconds: 0)
        XCTAssertEqual(result.receivedCount, 1)
        XCTAssertFalse(result.timedOut)
    }

    func testReadyMetadataCannotReviveCancelledOrReplacedBarrier() async {
        for replacement in [false, true] {
            let barrier = PttRxReadyBarrier()
            await barrier.prepare(leaseId: "lease", expectedSessionIds: [], expectedDeviceIds: ["device"])
            await barrier.accept(metadataReady(), participantIdentity: "session", participantDeviceId: nil)
            if replacement {
                await barrier.prepare(leaseId: "new", expectedSessionIds: [], expectedDeviceIds: ["device"])
            } else {
                await barrier.cancel(leaseId: "lease")
            }
            await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
            let result = await barrier.wait(leaseId: replacement ? "new" : "lease", maximumWaitMilliseconds: 0)
            XCTAssertEqual(result.receivedCount, 0)
            XCTAssertEqual(result.cancelled, !replacement)
        }
    }

    func testReadyAndDelayedMetadataCannotPassOriginalDeadline() async {
        for deferred in [false, true] {
            let clock = ReadyMetadataTestClock()
            let barrier = PttRxReadyBarrier(clock: clock)
            await barrier.prepare(leaseId: "lease", expectedSessionIds: [], expectedDeviceIds: ["device"])
            if deferred { await barrier.accept(metadataReady(), participantIdentity: "session", participantDeviceId: nil) }
            clock.advance(milliseconds: 4_000)
            if deferred {
                await barrier.reconcileParticipant(participantIdentity: "session", participantDeviceId: "device")
            } else {
                await barrier.accept(metadataReady(), participantIdentity: "session", participantDeviceId: "device")
            }
            let result = await barrier.wait(leaseId: "lease")
            XCTAssertEqual(result.receivedCount, 0)
            XCTAssertEqual(result.waitMilliseconds, 4_000)
            XCTAssertTrue(result.timedOut)
        }
    }

    private func metadataReady(lease: String = "lease", device: String = "device") -> PttRxReadyEvent {
        PttRxReadyEvent(version: 1, type: "rx_ready", channelId: "stage", speakerSessionId: "speaker",
                       receiverSessionId: "session", receiverDeviceId: device, leaseId: lease, readyAt: 1)
    }

    func testM1MultiRecipientWaitsForFinalAck() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(
            leaseId: "lease-m1", expectedSessionIds: [],
            expectedDeviceIds: ["device-a", "device-b", "device-c"]
        )
        let wait = Task { await barrier.wait(leaseId: "lease-m1", maximumWaitMilliseconds: 4_000) }
        await sendReady(after: 200, suffix: "a", leaseId: "lease-m1", barrier: barrier)
        await sendReady(after: 1_200, suffix: "b", leaseId: "lease-m1", barrier: barrier)
        await sendReady(after: 1_400, suffix: "c", leaseId: "lease-m1", barrier: barrier)
        let result = await wait.value
        XCTAssertEqual(result.receivedCount, 3)
        XCTAssertGreaterThanOrEqual(result.waitMilliseconds, 2_750)
        XCTAssertFalse(result.timedOut)
    }

    func testM2MultiRecipientMissingAckTimesOutWithCounts() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(
            leaseId: "lease-m2", expectedSessionIds: [],
            expectedDeviceIds: ["device-a", "device-b", "device-c"]
        )
        let wait = Task { await barrier.wait(leaseId: "lease-m2", maximumWaitMilliseconds: 4_000) }
        await sendReady(after: 200, suffix: "a", leaseId: "lease-m2", barrier: barrier)
        await sendReady(after: 1_200, suffix: "b", leaseId: "lease-m2", barrier: barrier)
        let result = await wait.value
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.expectedCount, 3)
        XCTAssertEqual(result.receivedCount, 2)
        XCTAssertEqual(result.expectedCount - result.receivedCount, 1)
    }

    func testM3MultiRecipientCompletesImmediatelyAfterFastFinalAck() async {
        let barrier = PttRxReadyBarrier()
        await barrier.prepare(
            leaseId: "lease-m3", expectedSessionIds: [],
            expectedDeviceIds: ["device-a", "device-b", "device-c"]
        )
        let wait = Task { await barrier.wait(leaseId: "lease-m3", maximumWaitMilliseconds: 4_000) }
        await sendReady(after: 40, suffix: "a", leaseId: "lease-m3", barrier: barrier)
        await sendReady(after: 20, suffix: "b", leaseId: "lease-m3", barrier: barrier)
        await sendReady(after: 20, suffix: "c", leaseId: "lease-m3", barrier: barrier)
        let result = await wait.value
        XCTAssertEqual(result.receivedCount, 3)
        XCTAssertLessThan(result.waitMilliseconds, 500)
        XCTAssertFalse(result.timedOut)
    }

    private func sendReady(
        after milliseconds: Int,
        suffix: String,
        leaseId: String,
        barrier: PttRxReadyBarrier
    ) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        let event = PttRxReadyEvent(
            version: 1, type: "rx_ready", channelId: "stage",
            speakerSessionId: "speaker", receiverSessionId: "session-\(suffix)",
            receiverDeviceId: "device-\(suffix)", leaseId: leaseId, readyAt: 1
        )
        await barrier.accept(
            event,
            participantIdentity: "session-\(suffix)",
            participantDeviceId: "device-\(suffix)"
        )
    }

    private func cachedResponse(sessionId: String, expiresAt: Date) -> JoinResponse {
        JoinResponse(
            sessionId: sessionId,
            livekitUrl: "wss://livekit.example",
            token: "redacted-fixture",
            roomName: "stage",
            user: User(
                id: "staff-b", workspaceId: "workspace", name: "Staff B",
                role: .staff, channelIds: ["stage"]
            ),
            channel: Channel(id: "stage", workspaceId: "workspace", name: "Stage"),
            canPublish: true,
            tokenExpiresInSeconds: 300,
            tokenExpiresAt: expiresAt,
            deviceId: "device-stable"
        )
    }
}

private final class ReadyMetadataTestClock: PTTClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { value } }
    func advance(milliseconds: Int) { lock.withLock { value += Double(milliseconds) / 1_000 } }
    func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

private final class ResumeCleanupAPIStub: KOEONAPIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var registered = true
    var cleanupCalls: [String] { lock.withLock { calls } }
    var listening: Bool { lock.withLock { registered } }
    func unregisterPttToken(sessionId: String) async throws {
        lock.withLock { registered = false; calls.append("unregister:\(sessionId)") }
    }
    func leave(sessionId: String) async throws {
        lock.withLock { registered = false; calls.append("leave:\(sessionId)") }
    }
    func fixture() async throws -> FixtureResponse { throw APIClientError.invalidResponse }
    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse { throw APIClientError.invalidResponse }
    var meError: Error? = APIClientError.invalidResponse
    var meResponse: MeResponse?
    var beforeMe: (@Sendable () async -> Void)?
    func me() async throws -> MeResponse {
        await beforeMe?()
        if let meError { throw meError }
        guard let meResponse else { throw APIClientError.invalidResponse }
        return meResponse
    }
    func join(_ request: JoinRequest) async throws -> JoinResponse { throw APIClientError.invalidResponse }
    func resume(_ request: ResumeRequest) async throws -> JoinResponse { throw APIClientError.invalidResponse }
    func acquireFloor(sessionId: String) async throws -> FloorResponse { throw APIClientError.invalidResponse }
    func renewFloor(sessionId: String, leaseId: String) async throws -> FloorResponse { throw APIClientError.invalidResponse }
    func releaseFloor(sessionId: String, leaseId: String) async throws -> FloorReleaseResponse { throw APIClientError.invalidResponse }
    func floorStatus(sessionId: String) async throws -> FloorResponse { throw APIClientError.invalidResponse }
    func registerPttToken(sessionId: String, channelId: String, token: String) async throws { throw APIClientError.invalidResponse }
    func logout() async throws { throw APIClientError.invalidResponse }
}

private final class StartupCredentialStub: DeviceCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "test-existing-device-credential-1234567890"
    private var clears = 0
    var clearCount: Int { lock.withLock { clears } }
    func read() -> String? { lock.withLock { value } }
    func write(_ credential: String) throws { lock.withLock { value = credential } }
    func clear() throws { lock.withLock { clears += 1; value = nil } }
}

private actor StartupMeGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

// Kept in this registered test source so command-line builds exercise the persistence contract.
final class FieldJournalStoreTests: XCTestCase {
    func testBoundedAdmissionResumesAfterCompletionAndReportsLoss() {
        let admission = FieldJournalAdmission(limit: 2)
        XCTAssertTrue(admission.admit()); XCTAssertTrue(admission.admit()); XCTAssertFalse(admission.admit())
        XCTAssertFalse(admission.admit()); XCTAssertEqual(admission.takeDropped(), 2); XCTAssertEqual(admission.takeDropped(), 0)
        admission.finish(); XCTAssertTrue(admission.admit()); admission.finish(); admission.finish()
    }
    private func sandbox(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func export(_ store: FieldJournalStore, _ root: URL, _ now: Int64) throws -> [String: Any] {
        let url = try store.export(to: root.appendingPathComponent("export.json"), now: now)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testRestartRetentionBoundaryAndAppendAfterExport() throws {
        try sandbox { root in
            let logs = root.appendingPathComponent("journal")
            let first = try FieldJournalStore(root: logs, build: "test", installationId: "test", retentionMs: 1000)
            first.append(event: "RX", fields: [:], ids: [:], wallMs: 1000, monoMs: 1)
            first.append(event: "RX_PCM", fields: [:], ids: [:], wallMs: 1001, monoMs: 2)
            let second = try FieldJournalStore(root: logs, build: "test", installationId: "test", retentionMs: 1000)
            second.append(event: "START", fields: [:], ids: [:], wallMs: 2001, monoMs: 0)
            let records = try XCTUnwrap(try export(second, root, 2001)["records"] as? [[String: Any]])
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.first?["event"] as? String, "RX_PCM")
            XCTAssertNotEqual(records[0]["runId"] as? String, records[1]["runId"] as? String)
            second.append(event: "TX", fields: [:], ids: [:], wallMs: 2002, monoMs: 1)
            XCTAssertEqual((try export(second, root, 2002)["records"] as? [Any])?.count, 2)
        }
    }
    func testPrivacyAndDropAccounting() throws {
        try sandbox { root in
            let store = try FieldJournalStore(root: root.appendingPathComponent("journal"), build: "test", installationId: "test")
            store.append(event: "TX", fields: ["token": "secret", "route": "headset-private", "ptt": "TRANSMITTING", "gainDb": 6],
                ids: ["leaseHash": "raw-private-lease", "token": "secret"], wallMs: 1000, monoMs: 10, droppedBefore: 4)
            let result = try export(store, root, 1000)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("raw-private")); XCTAssertFalse(text.contains("headset-private"))
            XCTAssertTrue(text.contains(FieldJournalStore.hash("raw-private-lease")))
            XCTAssertEqual((result["records"] as? [[String: Any]])?.first?["droppedBefore"] as? Int, 4)
        }
    }
    func testCorruptionAndCapacityAreReported() throws {
        try sandbox { root in
            let logs = root.appendingPathComponent("journal")
            let store = try FieldJournalStore(root: logs, build: "test", installationId: "test", maxBytes: 1600, segmentBytes: 500)
            try Data("{broken\n{\"schema\":[],\"wallTimeMs\":{}}\n".utf8).write(to: logs.appendingPathComponent("broken.jsonl"))
            for i in 0..<12 { store.append(event: "RX", fields: [:], ids: [:], wallMs: 1000 + Int64(i), monoMs: Int64(i)) }
            let manifest = try XCTUnwrap(try export(store, root, 1012)["manifest"] as? [String: Any])
            XCTAssertEqual(manifest["corruptDroppedRecordsLifetime"] as? Int, 2)
            XCTAssertGreaterThan(manifest["capacityDroppedRecordsLifetime"] as? Int ?? 0, 0)
            let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "jsonl" }
            XCTAssertLessThanOrEqual(try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }, 1600)
        }
    }
    func testBackwardClockExcludesFutureAndMarksDiscontinuity() throws {
        try sandbox { root in
            let store = try FieldJournalStore(root: root.appendingPathComponent("journal"), build: "test", installationId: "test")
            store.append(event: "START", fields: [:], ids: [:], wallMs: 100000, monoMs: 100)
            store.append(event: "RX", fields: [:], ids: [:], wallMs: 1000, monoMs: 101)
            let result = try export(store, root, 1000)
            let records = try XCTUnwrap(result["records"] as? [[String: Any]])
            XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0]["clockDiscontinuity"] as? Bool, true)
            XCTAssertEqual((result["manifest"] as? [String: Any])?["futureClockRecordsExcluded"] as? Int, 1)
        }
    }
}

final class FieldJournalRxPcmGateTests: XCTestCase {
    func testRepeatedAndLateSnapshotsDoNotRecountFirstPcm() {
        var gate = FieldJournalRxPcmGate()
        XCTAssertFalse(gate.accept(runtime: 2, generation: 0))
        XCTAssertTrue(gate.accept(runtime: 2, generation: 13))
        // A queued nil snapshot followed by the same first-PCM snapshot is not a new receive.
        XCTAssertFalse(gate.accept(runtime: 2, generation: 13))
        XCTAssertTrue(gate.accept(runtime: 2, generation: 16))
        XCTAssertFalse(gate.accept(runtime: 2, generation: 13))
        // A new runtime restarts RX generations; old runtime callbacks remain fenced.
        XCTAssertTrue(gate.accept(runtime: 3, generation: 1))
        XCTAssertFalse(gate.accept(runtime: 2, generation: 19))
        XCTAssertFalse(gate.accept(runtime: 3, generation: 1))
    }
}
