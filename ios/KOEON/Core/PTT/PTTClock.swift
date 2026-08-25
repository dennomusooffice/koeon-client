import Foundation

protocol PTTClock: Sendable {
    var now: Date { get }
    func sleep(milliseconds: Int) async throws
}

struct SystemPTTClock: PTTClock {
    var now: Date { Date() }

    func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
