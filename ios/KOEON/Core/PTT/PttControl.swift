import Foundation

let pttControlTopic = "koeon.ptt.control"
let pttControlFastStartTopic = "koeon.ptt.control.fast-start.v1"
let pttControlVersion = 1
let pttRxReadyTopic = "koeon.ptt.rx-ready.v1"
let pttRxReadyVersion = 1
let rxReadySingleMaxWaitMilliseconds = 4_000
let rxReadyMultiAbsoluteMaxMilliseconds = 4_000

struct PttControlEvent: Codable, Equatable, Sendable {
    let version: Int
    let type: String
    let channelId: String
    let speakerUserId: String
    let sessionId: String
    let leaseId: String
    let sequence: Int64
    let sentAt: Int64
    var bufferedGenerationId: String? = nil
}

struct PttRxReadyEvent: Codable, Equatable, Sendable {
    let version: Int
    let type: String
    let channelId: String
    let speakerSessionId: String
    let receiverSessionId: String
    var receiverDeviceId: String? = nil
    let leaseId: String
    let readyAt: Int64
}

struct PttRxReadyWaitResult: Equatable, Sendable {
    let expectedCount: Int
    let receivedCount: Int
    let lateCount: Int
    let waitMilliseconds: Int
    let timedOut: Bool
    let firstReadyAt: Date?
    let allReadyAt: Date?
}

struct PttStartPublishDiagnostics: Equatable, Sendable {
    var fastStartedAt: Date? = nil
    var fastCompletedAt: Date? = nil
    var fastMilliseconds: Int? = nil
    var reliableStartedAt: Date? = nil
    var reliableCompletedAt: Date? = nil
    var reliableMilliseconds: Int? = nil
}

@MainActor
protocol PttControlPublishing: AnyObject {
    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics
    func publishBufferedStart(leaseId: String, generationId: String) async throws -> PttStartPublishDiagnostics
    func publishEnd(leaseId: String) async throws
    func prepareRxReady(leaseId: String, expectedSessionIds: [String]) async
    func prepareRxReady(leaseId: String, expectedSessionIds: [String], expectedDeviceIds: [String]) async
    func awaitRxReady(leaseId: String, maximumWaitMilliseconds: Int?) async -> PttRxReadyWaitResult
    func cancelRxReady(leaseId: String) async
    func publishRxReady(speakerSessionId: String, leaseId: String) async throws
}

extension PttControlPublishing {
    func publishBufferedStart(leaseId: String, generationId: String) async throws -> PttStartPublishDiagnostics {
        try await publishStart(leaseId: leaseId)
    }
    func prepareRxReady(leaseId: String, expectedSessionIds: [String]) async {}
    func prepareRxReady(leaseId: String, expectedSessionIds: [String], expectedDeviceIds: [String]) async {
        await prepareRxReady(leaseId: leaseId, expectedSessionIds: expectedSessionIds)
    }
    func awaitRxReady(leaseId: String, maximumWaitMilliseconds: Int? = nil) async -> PttRxReadyWaitResult {
        PttRxReadyWaitResult(expectedCount: 0, receivedCount: 0, lateCount: 0, waitMilliseconds: 0, timedOut: false, firstReadyAt: nil, allReadyAt: nil)
    }
    func cancelRxReady(leaseId: String) async {}
    func publishRxReady(speakerSessionId: String, leaseId: String) async throws {}
}

@MainActor
final class NoopPttControlPublisher: PttControlPublishing {
    func publishStart(leaseId: String) async throws -> PttStartPublishDiagnostics { .init() }
    func publishEnd(leaseId: String) async throws {}
}

enum PttControlCodec {
    static func decode(_ data: Data) -> PttControlEvent? {
        guard let event = try? JSONDecoder().decode(PttControlEvent.self, from: data),
              event.version == pttControlVersion,
              event.type == "start" || event.type == "end",
              !event.channelId.isEmpty,
              !event.speakerUserId.isEmpty,
              !event.sessionId.isEmpty,
              !event.leaseId.isEmpty,
              event.sequence >= 0 else { return nil }
        return event
    }
}

enum PttRxReadyCodec {
    static func decode(_ data: Data) -> PttRxReadyEvent? {
        guard let event = try? JSONDecoder().decode(PttRxReadyEvent.self, from: data),
              event.version == pttRxReadyVersion, event.type == "rx_ready",
              !event.channelId.isEmpty, !event.speakerSessionId.isEmpty,
              !event.receiverSessionId.isEmpty, !event.leaseId.isEmpty,
              event.readyAt >= 0 else { return nil }
        return event
    }
}

actor PttRxReadyBarrier {
    private struct Arm {
        let leaseId: String
        let expected: Set<String>
        let expectedDevices: Set<String>
        let startedAt: Date
        var received: Set<String> = []
        var firstAt: Date?
        var allAt: Date?
        var cancelled = false
    }
    private var arm: Arm?
    private var lateCount = 0

    func prepare(leaseId: String, expectedSessionIds: [String], expectedDeviceIds: [String] = []) {
        arm = Arm(leaseId: leaseId, expected: Set(expectedSessionIds.filter { !$0.isEmpty }), expectedDevices: Set(expectedDeviceIds.filter { !$0.isEmpty }), startedAt: Date())
        lateCount = 0
    }

    func accept(_ event: PttRxReadyEvent, participantIdentity: String?, participantDeviceId: String? = nil) {
        guard var current = arm,
              !current.cancelled,
              current.leaseId == event.leaseId,
              participantIdentity == event.receiverSessionId else {
            lateCount += 1
            return
        }
        let readyIdentity: String
        if !current.expectedDevices.isEmpty {
            guard let receiverDeviceId = event.receiverDeviceId,
                  receiverDeviceId == participantDeviceId,
                  current.expectedDevices.contains(receiverDeviceId) else {
                lateCount += 1
                return
            }
            readyIdentity = receiverDeviceId
        } else {
            guard current.expected.contains(event.receiverSessionId) else {
                lateCount += 1
                return
            }
            readyIdentity = event.receiverSessionId
        }
        guard current.received.insert(readyIdentity).inserted else { return }
        let now = Date()
        current.firstAt = current.firstAt ?? now
        let expected = current.expectedDevices.isEmpty ? current.expected : current.expectedDevices
        if current.received == expected { current.allAt = now }
        arm = current
    }

    func wait(leaseId: String, maximumWaitMilliseconds: Int? = nil) async -> PttRxReadyWaitResult {
        guard let initial = arm, initial.leaseId == leaseId else { return Self.empty }
        let initialExpected = initial.expectedDevices.isEmpty ? initial.expected : initial.expectedDevices
        if initialExpected.isEmpty { arm = nil; return Self.empty }
        let policyMaximum = initialExpected.count == 1 ? rxReadySingleMaxWaitMilliseconds : rxReadyMultiAbsoluteMaxMilliseconds
        let maximum = maximumWaitMilliseconds.map { min(max(0, $0), policyMaximum) } ?? policyMaximum
        while true {
            guard let current = arm, current.leaseId == leaseId else { return Self.empty }
            let elapsed = max(0, Int(Date().timeIntervalSince(current.startedAt) * 1_000))
            let expected = current.expectedDevices.isEmpty ? current.expected : current.expectedDevices
            let all = current.received == expected
            let timedOut = elapsed >= maximum
            if current.cancelled || all || timedOut {
                let result = PttRxReadyWaitResult(
                    expectedCount: expected.count,
                    receivedCount: current.received.count,
                    lateCount: lateCount,
                    waitMilliseconds: min(elapsed, maximum),
                    timedOut: timedOut && !all,
                    firstReadyAt: current.firstAt,
                    allReadyAt: current.allAt
                )
                arm = nil
                return result
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func cancel(leaseId: String) {
        guard var current = arm, current.leaseId == leaseId else { return }
        current.cancelled = true
        arm = current
    }

    private static let empty = PttRxReadyWaitResult(expectedCount: 0, receivedCount: 0, lateCount: 0, waitMilliseconds: 0, timedOut: false, firstReadyAt: nil, allReadyAt: nil)
}
