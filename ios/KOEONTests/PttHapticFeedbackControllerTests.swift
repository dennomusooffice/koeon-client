import XCTest
@testable import KOEON

@MainActor
final class PttHapticFeedbackControllerTests: XCTestCase {
    func testPressHapticPrecedesFloorAcquire() {
        var events: [String] = []
        let performer = FakeHapticPerformer(onPress: { events.append("haptic") })
        let controller = PttHapticFeedbackController(performer: performer)

        XCTAssertTrue(controller.press(eligible: true))
        events.append("floor")

        XCTAssertEqual(events, ["haptic", "floor"])
    }

    func testBusyInputGetsOnePressAndDuplicateIsSuppressed() {
        let performer = FakeHapticPerformer()
        let controller = PttHapticFeedbackController(performer: performer)

        XCTAssertTrue(controller.press(eligible: true))
        XCTAssertFalse(controller.press(eligible: true))
        XCTAssertEqual(performer.pressCount, 1)
        XCTAssertEqual(controller.snapshot.lastResult, .skippedDuplicate)
    }

    func testReleaseHapticAndVisualState() {
        let performer = FakeHapticPerformer()
        var snapshots: [HapticSnapshot] = []
        let controller = PttHapticFeedbackController(
            performer: performer,
            now: { Date(timeIntervalSince1970: 123) },
            onUpdate: { snapshots.append($0) }
        )

        controller.press(eligible: true)
        XCTAssertTrue(controller.release())
        XCTAssertFalse(controller.release())

        XCTAssertEqual(performer.releaseCount, 1)
        XCTAssertEqual(snapshots.map(\.inputPressed), [true, false, false])
    }

    func testListenerDoesNotEmitHaptic() {
        let performer = FakeHapticPerformer()
        let controller = PttHapticFeedbackController(performer: performer)

        XCTAssertFalse(controller.press(eligible: false))
        XCTAssertEqual(performer.pressCount, 0)
        XCTAssertFalse(controller.snapshot.inputPressed)
    }

    func testUnsupportedDisabledAndFailureDoNotRejectEligibleInput() {
        let unsupported = PttHapticFeedbackController(performer: FakeHapticPerformer(supported: false))
        let disabled = PttHapticFeedbackController(performer: FakeHapticPerformer(enabled: false))
        let failed = PttHapticFeedbackController(performer: FakeHapticPerformer(shouldFail: true))

        XCTAssertTrue(unsupported.press(eligible: true))
        XCTAssertEqual(unsupported.snapshot.lastResult, .unsupported)
        XCTAssertTrue(disabled.press(eligible: true))
        XCTAssertEqual(disabled.snapshot.lastResult, .disabled)
        XCTAssertTrue(failed.press(eligible: true))
        XCTAssertEqual(failed.snapshot.lastResult, .failed)
    }
}

@MainActor
private final class FakeHapticPerformer: PttHapticPerforming {
    let supported: Bool
    let enabled: Bool
    private let shouldFail: Bool
    private let onPress: () -> Void
    private(set) var pressCount = 0
    private(set) var releaseCount = 0

    init(
        supported: Bool = true,
        enabled: Bool = true,
        shouldFail: Bool = false,
        onPress: @escaping () -> Void = {}
    ) {
        self.supported = supported
        self.enabled = enabled
        self.shouldFail = shouldFail
        self.onPress = onPress
    }

    func prepare() {}

    func performPress() throws -> Bool {
        pressCount += 1
        onPress()
        if shouldFail { throw TestFailure.unavailable }
        return true
    }

    func performRelease() throws -> Bool {
        releaseCount += 1
        if shouldFail { throw TestFailure.unavailable }
        return true
    }

    private enum TestFailure: Error {
        case unavailable
    }
}
