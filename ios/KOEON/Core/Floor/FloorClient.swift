import Foundation

protocol FloorControlling: Sendable {
    func acquire() async throws -> FloorResponse
    func renew(leaseId: String) async throws -> FloorResponse
    func release(leaseId: String) async throws
}

struct FloorClient: FloorControlling, Sendable {
    let sessionId: String
    let api: any KOEONAPIClientProtocol

    func acquire() async throws -> FloorResponse {
        try await api.acquireFloor(sessionId: sessionId)
    }

    func renew(leaseId: String) async throws -> FloorResponse {
        try await api.renewFloor(sessionId: sessionId, leaseId: leaseId)
    }

    func release(leaseId: String) async throws {
        _ = try await api.releaseFloor(sessionId: sessionId, leaseId: leaseId)
    }
}
