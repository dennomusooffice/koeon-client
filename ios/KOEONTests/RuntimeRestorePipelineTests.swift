import XCTest
@testable import KOEON

@MainActor
final class RuntimeRestorePipelineTests: XCTestCase {
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
                onFreshSessionReceived: { _ in },
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
            onFreshSessionReceived: { _ in },
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
