import Foundation
import UIKit

enum HapticType: String, Equatable, Sendable {
    case press
    case release
}

enum HapticResult: String, Equatable, Sendable {
    case played
    case unsupported
    case disabled
    case failed
    case skippedDuplicate = "skipped_duplicate"
    case notPlayed = "not_played"
}

struct HapticSnapshot: Sendable {
    var supported = false
    var enabled = false
    var inputPressed = false
    var lastType: HapticType?
    var lastAt: Date?
    var lastResult: HapticResult = .notPlayed
}

@MainActor
protocol PttHapticPerforming: AnyObject {
    var supported: Bool { get }
    var enabled: Bool { get }
    func prepare()
    func performPress() throws -> Bool
    func performRelease() throws -> Bool
}

@MainActor
final class UIKitPttHapticPerformer: PttHapticPerforming {
    private let pressGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let releaseGenerator = UIImpactFeedbackGenerator(style: .light)

    let supported = true
    let enabled = true

    func prepare() {
        pressGenerator.prepare()
        releaseGenerator.prepare()
    }

    func performPress() throws -> Bool {
        pressGenerator.impactOccurred()
        pressGenerator.prepare()
        return true
    }

    func performRelease() throws -> Bool {
        releaseGenerator.impactOccurred(intensity: 0.55)
        releaseGenerator.prepare()
        return true
    }
}

/// Input feedback only: the result never controls Floor, Cue, or microphone state.
@MainActor
final class PttHapticFeedbackController {
    private let performer: any PttHapticPerforming
    private let now: () -> Date
    private let onUpdate: (HapticSnapshot) -> Void
    private var inputPressed = false
    private(set) var snapshot: HapticSnapshot

    init(
        performer: any PttHapticPerforming,
        now: @escaping () -> Date = Date.init,
        onUpdate: @escaping (HapticSnapshot) -> Void = { _ in }
    ) {
        self.performer = performer
        self.now = now
        self.onUpdate = onUpdate
        snapshot = HapticSnapshot(supported: performer.supported, enabled: performer.enabled)
    }

    func prepare() {
        try? prepareSafely()
        emit(snapshot)
    }

    @discardableResult
    func press(eligible: Bool) -> Bool {
        guard eligible else { return false }
        guard !inputPressed else {
            record(type: .press, result: .skippedDuplicate)
            return false
        }
        inputPressed = true
        play(type: .press) { try performer.performPress() }
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard inputPressed else {
            record(type: .release, result: .skippedDuplicate)
            return false
        }
        inputPressed = false
        play(type: .release) { try performer.performRelease() }
        return true
    }

    func cancel() {
        guard inputPressed else { return }
        inputPressed = false
        var next = snapshot
        next.inputPressed = false
        emit(next)
    }

    private func prepareSafely() throws {
        performer.prepare()
    }

    private func play(type: HapticType, action: () throws -> Bool) {
        let result: HapticResult
        if !performer.supported {
            result = .unsupported
        } else if !performer.enabled {
            result = .disabled
        } else {
            do {
                result = try action() ? .played : .failed
            } catch {
                result = .failed
            }
        }
        record(type: type, result: result)
    }

    private func record(type: HapticType, result: HapticResult) {
        var next = snapshot
        next.supported = performer.supported
        next.enabled = performer.enabled
        next.inputPressed = inputPressed
        next.lastType = type
        next.lastAt = now()
        next.lastResult = result
        emit(next)
    }

    private func emit(_ value: HapticSnapshot) {
        snapshot = value
        onUpdate(value)
    }
}
