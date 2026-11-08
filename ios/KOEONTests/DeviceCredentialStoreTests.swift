import XCTest
@testable import KOEON

final class FieldDiagnosticSnapshotFileTests: XCTestCase {
    func testExportReplacesOnlyLatestSnapshot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = Data("{\"sequence\":1}".utf8)
        let second = Data("{\"sequence\":2}".utf8)
        let url = try FieldDiagnosticSnapshotFile.write(first, cachesDirectory: base)
        XCTAssertEqual(try Data(contentsOf: url), first)
        XCTAssertEqual(try FieldDiagnosticSnapshotFile.write(second, cachesDirectory: base), url)
        XCTAssertEqual(try Data(contentsOf: url), second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path),
                       ["field-diagnostic-latest.json"])
    }

    func testUnavailableDestinationReportsFailure() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("occupied".utf8).write(to: file)
        XCTAssertThrowsError(try FieldDiagnosticSnapshotFile.write(Data("{}".utf8), cachesDirectory: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "occupied")
    }
}

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
