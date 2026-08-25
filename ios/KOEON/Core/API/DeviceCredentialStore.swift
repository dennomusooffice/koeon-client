import Foundation
import Security
import UIKit

protocol DeviceCredentialStoring: Sendable {
    func read() -> String?
    func write(_ credential: String) throws
    func clear() throws
}

enum DeviceCredentialStoreError: Error { case keychain(OSStatus) }

final class KeychainDeviceCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private let service = "org.example.koeon.device-credential"
    private let account = "current-device"

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ credential: String) throws {
        guard credential.count >= 32 else { return }
        try? clear()
        var query = baseQuery
        query[kSecValueData as String] = Data(credential.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceCredentialStoreError.keychain(status) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum DeviceDisplayPlatform {
    case iPhone
    case iPad

    var prefix: String {
        switch self {
        case .iPhone: "IPH"
        case .iPad: "IPD"
        }
    }
}

protocol DeviceDisplayNameStoring {
    func getOrCreate() -> String
}

final class PersistentDeviceDisplayNameStore: DeviceDisplayNameStoring {
    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let storageKey = "koeon.deviceDisplayName.v1"

    private let defaults: UserDefaults
    private let platform: DeviceDisplayPlatform
    private let randomIndex: (Int) -> Int

    init(
        defaults: UserDefaults = .standard,
        platform: DeviceDisplayPlatform = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
        randomIndex: @escaping (Int) -> Int = { Int.random(in: 0 ..< $0) }
    ) {
        self.defaults = defaults
        self.platform = platform
        self.randomIndex = randomIndex
    }

    func getOrCreate() -> String {
        if let existing = defaults.string(forKey: Self.storageKey), Self.isValid(existing) {
            return existing
        }
        let suffix = String((0..<6).map { _ in Self.alphabet[randomIndex(Self.alphabet.count)] })
        let generated = "\(platform.prefix)-\(suffix)"
        defaults.set(generated, forKey: Self.storageKey)
        return generated
    }

    static func isValid(_ value: String) -> Bool {
        value.range(of: "^(IPH|IPD)-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$", options: .regularExpression) != nil
    }
}
