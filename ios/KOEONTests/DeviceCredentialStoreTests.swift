import XCTest
@testable import KOEON

final class DeviceCredentialStoreTests: XCTestCase {
    func testCredentialLifecycleUsesKeychainAbstraction() throws {
        let store = FakeCredentialStore()
        XCTAssertNil(store.read())
        try store.write("secure-device-credential-value-123456789")
        XCTAssertEqual(store.read(), "secure-device-credential-value-123456789")
        try store.clear()
        XCTAssertNil(store.read())
    }

    func testIPhoneDisplayNameIsPersistentAndUnambiguous() {
        let suite = "DeviceDisplayNameTests.iPhone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PersistentDeviceDisplayNameStore(defaults: defaults, platform: .iPhone) { $0 - 1 }.getOrCreate()
        let second = PersistentDeviceDisplayNameStore(defaults: defaults, platform: .iPhone) { _ in 0 }.getOrCreate()
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("IPH-"))
        XCTAssertEqual(first.count, 10)
        XCTAssertNil(String(first.suffix(6)).range(of: "[01IO]", options: .regularExpression))
    }

    func testIPadDisplayNameUsesIPDPrefix() {
        let suite = "DeviceDisplayNameTests.iPad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let name = PersistentDeviceDisplayNameStore(defaults: defaults, platform: .iPad) { _ in 0 }.getOrCreate()
        XCTAssertTrue(name.hasPrefix("IPD-"))
        XCTAssertTrue(PersistentDeviceDisplayNameStore.isValid(name))
    }
}

private final class FakeCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private var value: String?
    func read() -> String? { value }
    func write(_ credential: String) throws { value = credential }
    func clear() throws { value = nil }
}
