import XCTest
@testable import KOEON

final class BackendContractTests: XCTestCase {
    func testActionButtonRestoreRequiresPreviouslyValidatedSameUserAndChannel() {
        var runtime = ActionButtonValidatedRuntime()
        XCTAssertFalse(runtime.permits(channel: "channel-a", user: "user-a"))
        runtime.validate(channel: "channel-a", user: "user-a")
        XCTAssertTrue(runtime.permits(channel: "channel-a", user: "user-a"))
        XCTAssertFalse(runtime.permits(channel: "channel-b", user: "user-a"))
        XCTAssertFalse(runtime.permits(channel: "channel-a", user: "user-b"))
        runtime.clear()
        XCTAssertFalse(runtime.permits(channel: "channel-a", user: "user-a"))
        runtime.validate(channel: "channel-b", user: "user-b")
        XCTAssertFalse(runtime.permits(channel: "channel-a", user: "user-a"))
        XCTAssertTrue(runtime.permits(channel: "channel-b", user: "user-b"))
    }

    func testActionButtonInvocationExpiresAtEightSecondsAndRejectsChangedScope() {
        var gate = ActionButtonInvocationGate()
        let token = gate.begin(channel: "channel-a", user: "user-a", now: 100)
        XCTAssertTrue(gate.permits(token, channel: "channel-a", user: "user-a", now: 107.99))
        XCTAssertFalse(gate.permits(token, channel: "channel-a", user: "user-a", now: 108))
        XCTAssertFalse(gate.permits(token, channel: "channel-b", user: "user-a", now: 101))
        XCTAssertFalse(gate.permits(token, channel: "channel-a", user: "user-b", now: 101))
    }

    func testActionButtonInvocationCancelAndLateCompletionCannotAffectNextInvocation() {
        var gate = ActionButtonInvocationGate()
        let old = gate.begin(channel: "channel-a", user: "user-a", now: 10)
        gate.cancel()
        XCTAssertFalse(gate.permits(old, channel: "channel-a", user: "user-a", now: 11))
        let next = gate.begin(channel: "channel-a", user: "user-a", now: 11)
        gate.finish(old)
        XCTAssertTrue(gate.permits(next, channel: "channel-a", user: "user-a", now: 12))
        gate.finish(next)
        XCTAssertFalse(gate.active)
    }

    func testActionButtonInvocationAllowsOnlyOneRecoveryForItsOwnGeneration() {
        var gate = ActionButtonInvocationGate()
        let first = gate.begin(channel: "channel-a", user: "user-a", now: 10)
        XCTAssertTrue(gate.claimRecovery(first))
        XCTAssertFalse(gate.claimRecovery(first))
        gate.cancel()
        let next = gate.begin(channel: "channel-a", user: "user-a", now: 11)
        XCTAssertFalse(gate.claimRecovery(first))
        XCTAssertTrue(gate.claimRecovery(next))
    }

    func testActionButtonRecoveryDoesNotTrustStaleConnectedSnapshot() {
        XCTAssertEqual(runtimeRestoreEntryDecision(reason: .actionButtonRecovery,
            hasJoinedRuntime: true, connectionState: .connected), .performFreshResume)
        XCTAssertEqual(runtimeRestoreEntryDecision(reason: .foregroundRecovery,
            hasJoinedRuntime: true, connectionState: .connected), .useConnectedRuntime)
    }

    func testRuntimeConfigurationAcceptsValidHTTPSURL() throws {
        let url = try XCTUnwrap(RuntimeConfiguration.apiBaseURL(from: [
            RuntimeConfiguration.apiBaseURLInfoKey: "https://api.example.test/v1",
        ]))
        XCTAssertEqual(url.absoluteString, "https://api.example.test/v1")
    }

    func testRuntimeConfigurationFailsClosedWhenValueIsMissing() {
        XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [:]))
    }

    func testRuntimeConfigurationFailsClosedWhenValueIsEmpty() {
        XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [
            RuntimeConfiguration.apiBaseURLInfoKey: "  ",
        ]))
    }

    func testRuntimeConfigurationRejectsUnresolvedBuildSetting() {
        XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [
            RuntimeConfiguration.apiBaseURLInfoKey: "$(KOEON_API_BASE_URL)",
        ]))
    }

    func testRuntimeConfigurationRejectsPublicPlaceholder() {
        XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [
            RuntimeConfiguration.apiBaseURLInfoKey: "https://example.invalid",
        ]))
    }

    func testRuntimeConfigurationRejectsMalformedURL() {
        XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [
            RuntimeConfiguration.apiBaseURLInfoKey: "not a url",
        ]))
    }

    func testRuntimeConfigurationRejectsNonHTTPSURL() {
        XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [
            RuntimeConfiguration.apiBaseURLInfoKey: "http://api.example.test",
        ]))
    }

    func testRuntimeConfigurationRejectsCredentialQueryAndFragmentData() {
        for value in [
            "https://user@example.test",
            "https://api.example.test?mode=test",
            "https://api.example.test#section",
        ] {
            XCTAssertNil(RuntimeConfiguration.apiBaseURL(from: [
                RuntimeConfiguration.apiBaseURLInfoKey: value,
            ]))
        }
    }

    func testAPIClientDefaultPathConsumesRuntimeConfiguration() throws {
        let client = KOEONAPIClient(runtimeInfoDictionary: [
            RuntimeConfiguration.apiBaseURLInfoKey: "https://api.example.test/v1",
        ])
        XCTAssertEqual(client.configuredBaseURL, URL(string: "https://api.example.test/v1"))
    }

    func testFieldDiagnosticSchemaIsCrossPlatformV2() {
        XCTAssertEqual(fieldDiagnosticSchema, "koeon.field-diagnostic.v2")
    }
    func testSelfOriginatedIncomingPushIsRejectedBySessionIdentity() {
        let event = PttIncomingEvent(
            channelId: "stage", speakerUserId: "staff-a", speakerSessionId: "session-current",
            speakerDisplayName: "Staff A", leaseId: "lease-a", acquiredAt: Date()
        )
        XCTAssertTrue(isSelfOriginatedIncomingPush(event, currentSessionId: "session-current"))
        XCTAssertFalse(isSelfOriginatedIncomingPush(event, currentSessionId: "session-remote"))
        XCTAssertFalse(isSelfOriginatedIncomingPush(event, currentSessionId: nil))
    }
    func testJoinRequestUsesAuthenticatedIdentityContract() throws {
        let data = try JSONEncoder().encode(JoinRequest(
            channelId: "stage",
            wantsToPublish: true
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["channelId", "wantsToPublish", "rxReadyProtocolVersion"]))
        XCTAssertEqual(json["channelId"] as? String, "stage")
        XCTAssertEqual(json["wantsToPublish"] as? Bool, true)
        XCTAssertEqual(json["rxReadyProtocolVersion"] as? Int, 1)
    }

    func testResumeRequestUsesOneAuthenticatedColdRestoreContract() throws {
        let data = try JSONEncoder().encode(ResumeRequest(
            channelId: "stage", previousSessionId: "old-session"
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["channelId"] as? String, "stage")
        XCTAssertEqual(json["previousSessionId"] as? String, "old-session")
        XCTAssertEqual(json["rxReadyProtocolVersion"] as? Int, 1)
        XCTAssertEqual(Set(json.keys), Set(["channelId", "previousSessionId", "rxReadyProtocolVersion"]))
    }

    func testSignedParticipantCapabilityRequiresExplicitVersionAndStableDevice() {
        XCTAssertEqual(
            rxReadyCapableDeviceId(metadata: #"{"deviceId":"device-a","rxReadyProtocolVersion":1}"#),
            "device-a"
        )
        XCTAssertNil(rxReadyCapableDeviceId(metadata: #"{"deviceId":"legacy"}"#))
        XCTAssertNil(rxReadyCapableDeviceId(metadata: #"{"deviceId":"future","rxReadyProtocolVersion":2}"#))
    }

    func testRenewRequestUsesSessionAndLeaseOnly() throws {
        let data = try JSONEncoder().encode(LeaseRequest(sessionId: "session-a", leaseId: "lease-a"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["sessionId", "leaseId"]))
    }

    func testListenerPolicyAlwaysRequestsSubscriberOnlyToken() {
        XCTAssertFalse(KOEONRole.listener.canPublish)
        XCTAssertTrue(KOEONRole.staff.canPublish)
        XCTAssertTrue(KOEONRole.admin.canPublish)
        let request = JoinRequest(channelId: "hq", wantsToPublish: KOEONRole.listener.canPublish)
        XCTAssertFalse(request.wantsToPublish)
    }

    func testFloorResponseDecodesExistingSchema() throws {
        let json = #"{"outcome":"renewed","owner":{"id":"staff-a","name":"Staff A"},"leaseId":"lease-a","acquiredAt":"2026-08-13T01:00:00Z","leaseExpiresAt":"2026-08-13T01:00:03Z","maxTxExpiresAt":"2026-08-13T01:01:00Z","lastRenewedAt":"2026-08-13T01:00:01Z","isOwner":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(FloorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.outcome, .renewed)
        XCTAssertEqual(response.leaseId, "lease-a")
        XCTAssertTrue(response.isOwner)
        XCTAssertNil(response.rxReadyExpectedSessionIds)
    }

    func testFloorGrantDecodesExpectedReceiverSessionsWithoutTokens() throws {
        let json = #"{"outcome":"granted","owner":{"id":"staff-a","name":"Staff A"},"leaseId":"lease-a","acquiredAt":"2026-08-16T01:00:00Z","leaseExpiresAt":"2026-08-16T01:00:03Z","maxTxExpiresAt":"2026-08-16T01:01:00Z","lastRenewedAt":"2026-08-16T01:00:00Z","isOwner":true,"rxReadyExpectedSessionIds":["ios-session-b"]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(FloorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.rxReadyExpectedSessionIds, ["ios-session-b"])
    }

    func testPttTokenRegistrationUsesSessionBoundContractWithoutPersistedSecrets() throws {
        let request = PttTokenRegistrationRequest(
            sessionId: "session-a",
            channelId: "stage",
            token: String(repeating: "ab", count: 32)
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["sessionId", "channelId", "platform", "token"]))
        XCTAssertEqual(json["platform"] as? String, "ios")
    }

    func testTemporaryCodeEnrollmentUsesExplicitIOSPlatformAndNoToken() throws {
        let request = EnrollmentRequest(
            code: "ABCDE23456",
            deviceName: "iPhone",
            osVersion: "26.0",
            appVersion: "1.0"
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "ABCDE23456")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertNil(json["token"])
    }

    func testPttChannelUUIDIsDeterministicAndChannelSpecific() {
        let first = PushToTalkChannelUUID.make(channelId: "stage")
        XCTAssertEqual(first, PushToTalkChannelUUID.make(channelId: "stage"))
        XCTAssertNotEqual(first, PushToTalkChannelUUID.make(channelId: "operations"))
        XCTAssertEqual((first.uuid.6 & 0xF0), 0x50)
        XCTAssertEqual((first.uuid.8 & 0xC0), 0x80)
    }

    func testIncomingPttPayloadV2DoesNotRequireLocalKnownUsers() throws {
        let acquiredAt = ISO8601DateFormatter().string(from: Date())
        let event = try XCTUnwrap(PttIncomingPayloadValidator.validate([
            "aps": [:],
            "version": 2,
            "event": "floor_acquired",
            "channelId": "stage",
            "speakerUserId": "staff-a",
            "speakerSessionId": "session-a",
            "speakerDisplayName": "Staff A",
            "leaseId": "lease-a",
            "acquiredAt": acquiredAt,
        ], expectedChannelId: "stage"))
        XCTAssertEqual(event.speakerDisplayName, "Staff A")
        XCTAssertEqual(event.speakerSessionId, "session-a")
    }

    func testIncomingPttPayloadV2RejectsMismatchAndUnsafeSpeaker() {
        let base: [String: Any] = [
            "aps": [:], "version": 2, "event": "floor_acquired", "channelId": "stage",
            "speakerUserId": "staff-a", "speakerSessionId": "session-a",
            "speakerDisplayName": "Staff A", "leaseId": "lease-a",
            "acquiredAt": ISO8601DateFormatter().string(from: Date()),
        ]
        XCTAssertNil(PttIncomingPayloadValidator.validate(base, expectedChannelId: "operations"))
        var unsafe = base
        unsafe["speakerDisplayName"] = "Staff\nA"
        XCTAssertNil(PttIncomingPayloadValidator.validate(unsafe, expectedChannelId: "stage"))
        var missingLease = base
        missingLease.removeValue(forKey: "leaseId")
        XCTAssertNil(PttIncomingPayloadValidator.validate(missingLease, expectedChannelId: "stage"))
    }

    func testIncomingReplayProtectorRejectsDuplicateAndStaleEvents() {
        let protector = PttIncomingReplayProtector()
        let first = PttIncomingEvent(
            channelId: "stage", speakerUserId: "staff-a", speakerSessionId: "session-a",
            speakerDisplayName: "Staff A", leaseId: "lease-a", acquiredAt: Date()
        )
        XCTAssertTrue(protector.accept(first))
        XCTAssertFalse(protector.accept(first))
        XCTAssertFalse(protector.accept(PttIncomingEvent(
            channelId: "stage", speakerUserId: "staff-b", speakerSessionId: "session-b",
            speakerDisplayName: "Staff B", leaseId: "lease-b", acquiredAt: first.acquiredAt.addingTimeInterval(-1)
        )))
    }

    func testRestoreDescriptorPersistsOnlySafeChannelContext() throws {
        let suite = "KOEONTests.restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let descriptor = PttRestoreDescriptor(
            channelId: "stage",
            channelName: "02 ステージ",
            channelUUID: PushToTalkChannelUUID.make(channelId: "stage"),
            canPublish: true,
            lastBackendSessionId: "session-cleanup-only"
        )
        descriptor.persist(to: defaults)
        XCTAssertEqual(PttRestoreDescriptor.load(from: defaults), descriptor)
        let encoded = try XCTUnwrap(defaults.data(forKey: PttRestoreDescriptor.defaultsKey))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("livekit"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("token"))
    }

    func testRestoredPttChannelRequiresMatchingDescriptorAndCredential() {
        let uuid = PushToTalkChannelUUID.make(channelId: "stage")
        let descriptor = PttRestoreDescriptor(
            channelId: "stage", channelName: "02 ステージ", channelUUID: uuid,
            canPublish: true, lastBackendSessionId: nil
        )
        XCTAssertTrue(shouldPreserveRestoredPttChannel(
            restoredUUID: uuid, descriptor: descriptor, credentialAvailable: true
        ))
        XCTAssertFalse(shouldPreserveRestoredPttChannel(
            restoredUUID: uuid, descriptor: descriptor, credentialAvailable: false
        ))
        XCTAssertFalse(shouldPreserveRestoredPttChannel(
            restoredUUID: PushToTalkChannelUUID.make(channelId: "operations"),
            descriptor: descriptor,
            credentialAvailable: true
        ))
    }

    func testAccessoryEventsRequireExplicitSettingPublishRoleAndJoinedChannel() {
        XCTAssertTrue(shouldEnablePttAccessoryEvents(
            settingEnabled: true, canPublish: true, frameworkState: .joined
        ))
        XCTAssertFalse(shouldEnablePttAccessoryEvents(
            settingEnabled: false, canPublish: true, frameworkState: .joined
        ))
        XCTAssertFalse(shouldEnablePttAccessoryEvents(
            settingEnabled: true, canPublish: false, frameworkState: .joined
        ))
        XCTAssertFalse(shouldEnablePttAccessoryEvents(
            settingEnabled: true, canPublish: true, frameworkState: .ready
        ))
    }

    func testRouteLossStopsTxButPreservesRxOnlyState() {
        XCTAssertTrue(shouldSafetyStopForRouteChange(
            lostExternalInputRoute: true, pttState: .transmitting
        ))
        XCTAssertTrue(shouldSafetyStopForRouteChange(
            lostExternalInputRoute: true, pttState: .requestingFloor
        ))
        XCTAssertFalse(shouldSafetyStopForRouteChange(
            lostExternalInputRoute: true, pttState: .idle
        ))
        XCTAssertFalse(shouldSafetyStopForRouteChange(
            lostExternalInputRoute: false, pttState: .transmitting
        ))
    }

    func testBackgroundCleanupPolicyCoversAccessoryAndBackgroundEnd() {
        XCTAssertTrue(shouldUseBoundedBackgroundCleanup(
            transmitSource: "handsfreeButton", appLifecycleState: "active"
        ))
        XCTAssertTrue(shouldUseBoundedBackgroundCleanup(
            transmitSource: "developerRequest", appLifecycleState: "background"
        ))
        XCTAssertFalse(shouldUseBoundedBackgroundCleanup(
            transmitSource: "developerRequest", appLifecycleState: "active"
        ))
    }

    func testRuntimeRestoreOnlyTearsDownForTerminalIdentityErrors() {
        XCTAssertTrue(isTerminalRuntimeRestoreError(APIClientError.http(401, "unauthorized")))
        XCTAssertTrue(isTerminalRuntimeRestoreError(APIClientError.http(403, "disabled")))
        XCTAssertTrue(isTerminalRuntimeRestoreError(APIClientError.http(404, "membership removed")))
        XCTAssertFalse(isTerminalRuntimeRestoreError(APIClientError.http(500, "temporary")))
        XCTAssertFalse(isTerminalRuntimeRestoreError(URLError(.notConnectedToInternet)))
    }

    func testForegroundWithoutJoinedRuntimeDoesNotRequestRecovery() {
        XCTAssertEqual(
            foregroundRuntimeRecoveryAction(hasJoinedRuntime: false, connectionState: .disconnected),
            .noJoinedRuntime
        )
    }

    func testForegroundConnectedRuntimeDoesNotRejoin() {
        XCTAssertEqual(
            foregroundRuntimeRecoveryAction(hasJoinedRuntime: true, connectionState: .connected),
            .keepConnectedRuntime
        )
        XCTAssertEqual(
            foregroundRuntimeRecoveryAction(hasJoinedRuntime: true, connectionState: .reconnecting),
            .awaitExistingReconnect
        )
        XCTAssertEqual(
            foregroundRuntimeRecoveryAction(hasJoinedRuntime: true, connectionState: .connecting),
            .awaitExistingReconnect
        )
    }

    func testForegroundDisconnectedRuntimeRequestsPersistedRestore() {
        XCTAssertEqual(
            foregroundRuntimeRecoveryAction(hasJoinedRuntime: true, connectionState: .disconnected),
            .requestPersistedRuntimeRestore
        )
    }

    func testAudioPublishProfileDefaultsAndPersistence() throws {
        let suiteName = "BackendContractTests.audioPublishProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AudioPublishProfile.load(from: defaults), .speech24k)
        AudioPublishProfile.telephone12k.persist(to: defaults)
        XCTAssertEqual(AudioPublishProfile.load(from: defaults), .telephone12k)
        AudioPublishProfile.highQuality48k.persist(to: defaults)
        XCTAssertEqual(AudioPublishProfile.load(from: defaults), .highQuality48k)
        defaults.set("INVALID", forKey: AudioPublishProfile.persistenceKey)
        XCTAssertEqual(AudioPublishProfile.load(from: defaults), .speech24k)
    }

    func testAudioPublishProfileLiveKitBitrateMapping() {
        XCTAssertEqual(AudioPublishProfile.telephone12k.maxBitrate, 12_000)
        XCTAssertEqual(AudioPublishProfile.speech24k.maxBitrate, 24_000)
        XCTAssertEqual(AudioPublishProfile.highQuality48k.maxBitrate, 48_000)
    }

    func testSelectedProfileDoesNotReplaceAppliedRoomUntilPowerCycle() {
        XCTAssertEqual(
            audioPublishProfileForConnection(selected: .telephone12k, applied: .speech24k),
            .speech24k
        )
        XCTAssertEqual(
            audioPublishProfileForConnection(selected: .telephone12k, applied: nil),
            .telephone12k
        )
    }

    func testAuthorizedAccessoryBeginCanStartWithoutAnAppPress() {
        var gate = PttRequestGate()
        let allowed = shouldAcceptExternalPttBegin(source: "handsfreeButton", headsetEnabled: true, eligible: true)
        XCTAssertEqual(gate.didBegin(acceptExternalBegin: allowed), [.beginFloor])
        XCTAssertEqual(gate.state, .transmitting)
        XCTAssertEqual(gate.didEnd(), [.finishFloor])
        XCTAssertEqual(gate.state, .rearming)
        XCTAssertEqual(gate.finishRearming(), [])
        XCTAssertEqual(gate.state, .idle)
    }

    func testExternalBeginRequiresKnownSourceAndExplicitEligibility() {
        for source in ["unknown", "developerRequest", "unexpected"] {
            XCTAssertFalse(shouldAcceptExternalPttBegin(source: source, headsetEnabled: true, eligible: true))
        }
        XCTAssertFalse(shouldAcceptExternalPttBegin(source: "handsfreeButton", headsetEnabled: false, eligible: true))
        XCTAssertFalse(shouldAcceptExternalPttBegin(source: "handsfreeButton", headsetEnabled: true, eligible: false))
        XCTAssertFalse(shouldAcceptExternalPttBegin(source: "userRequest", headsetEnabled: true, eligible: false))
        XCTAssertTrue(shouldAcceptExternalPttBegin(source: "userRequest", headsetEnabled: false, eligible: true))
        var gate = PttRequestGate()
        XCTAssertEqual(gate.didBegin(acceptExternalBegin: false), [.stopSystemTransmission])
        XCTAssertFalse(gate.floorStarted)
    }

    func testExternalBeginCannotBypassCancellationOrRearming() {
        var cancelled = PttRequestGate()
        _ = cancelled.pressDown()
        _ = cancelled.pressUp()
        XCTAssertEqual(cancelled.didBegin(acceptExternalBegin: true), [.stopSystemTransmission])
        XCTAssertFalse(cancelled.floorStarted)
        var rearming = PttRequestGate()
        _ = rearming.didEnd()
        XCTAssertEqual(rearming.didBegin(acceptExternalBegin: true), [.stopSystemTransmission])
        XCTAssertFalse(rearming.floorStarted)
    }

    func testActionButtonRequiresOptInAndReadySession() {
        XCTAssertEqual(actionButtonPttDecision(enabled: false, state: .idle, eligible: true), .disabled)
        XCTAssertEqual(actionButtonPttDecision(enabled: true, state: .idle, eligible: false), .unavailable)
        XCTAssertEqual(actionButtonPttDecision(enabled: true, state: .idle, eligible: true), .startRequested)
    }

    func testActionButtonSecondInvocationCancelsPendingBeginEvenWhenReadinessIsLost() {
        var gate = PttRequestGate()
        XCTAssertEqual(gate.pressDown(), [.requestBegin])
        XCTAssertEqual(actionButtonPttDecision(enabled: true, state: gate.state, eligible: false), .stopRequested)
        _ = gate.pressUp()
        XCTAssertTrue(gate.releaseRequestedBeforeBegin)
        XCTAssertEqual(gate.didBegin(), [.stopSystemTransmission])
        XCTAssertFalse(gate.floorStarted, "Late Apple begin must not start a cancelled Floor request")
    }

    func testActionButtonReleaseDoesNotQueueAnotherTransmission() {
        var gate = PttRequestGate()
        _ = gate.pressDown()
        _ = gate.didBegin()
        XCTAssertEqual(actionButtonPttDecision(enabled: true, state: gate.state, eligible: false), .stopRequested)
        _ = gate.pressUp()
        for _ in 0..<10 {
            XCTAssertEqual(actionButtonPttDecision(enabled: true, state: gate.state, eligible: true), .settling)
        }
        _ = gate.didEnd()
        XCTAssertEqual(actionButtonPttDecision(enabled: true, state: gate.state, eligible: true), .settling)
        XCTAssertTrue(gate.finishRearming().isEmpty)
        XCTAssertEqual(gate.state, .idle)
    }

    func testAppPttTouchEdgeAcceptsOneDownAndOneUpPerPhysicalHold() {
        var gate = AppPttTouchEdgeGate()
        XCTAssertTrue(gate.changed())
        XCTAssertFalse(gate.changed())
        XCTAssertFalse(gate.changed())
        XCTAssertTrue(gate.ended())
        XCTAssertFalse(gate.ended())
    }

    func testDuplicateAppTouchDownRequestsBeginOnceWithoutBusyAction() {
        var touchGate = AppPttTouchEdgeGate()
        var requestGate = PttRequestGate()
        var actions: [PttRequestGateAction] = []

        for _ in 0 ..< 3 {
            if touchGate.changed() {
                actions.append(contentsOf: requestGate.pressDown())
            }
        }

        XCTAssertEqual(actions.filter { $0 == .requestBegin }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .busy }.count, 0)
    }

    func testIndependentAppPttPressesRemainIndependentAttempts() {
        var gate = AppPttTouchEdgeGate()
        for _ in 0 ..< 3 {
            XCTAssertTrue(gate.changed())
            XCTAssertTrue(gate.ended())
        }
    }
}
