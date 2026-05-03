import CryptoKit
import Foundation
import Security

public protocol CompanionKeyStoring {
    var iphoneDeviceId: String { get }

    func sign(_ payload: Data) throws -> Data
    func publicKeyX963Representation() throws -> Data
}

public enum CompanionKeyStoreError: Error, Equatable {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidStoredDeviceId
    case invalidStoredPrivateKey
}

public final class CompanionKeyStore: CompanionKeyStoring {
    private enum Account {
        static let iphoneDeviceId = "iphoneDeviceId"
        static let signingPrivateKey = "p256SigningPrivateKey.rawRepresentation"
    }

    public let iphoneDeviceId: String

    private let configuration: FacePassCompanionConfiguration

    public init(configuration: FacePassCompanionConfiguration = .default) throws {
        self.configuration = configuration
        self.iphoneDeviceId = try Self.loadOrCreateDeviceId(configuration: configuration)
        _ = try Self.loadOrCreatePrivateKey(configuration: configuration)
    }

    public func sign(_ payload: Data) throws -> Data {
        let privateKey = try Self.loadOrCreatePrivateKey(configuration: configuration)
        return try privateKey.signature(for: payload).derRepresentation
    }

    public func publicKeyX963Representation() throws -> Data {
        let privateKey = try Self.loadOrCreatePrivateKey(configuration: configuration)
        return privateKey.publicKey.x963Representation
    }

    public func publicKeyX963Base64() throws -> String {
        try publicKeyX963Representation().base64EncodedString()
    }

    private static func loadOrCreateDeviceId(configuration: FacePassCompanionConfiguration) throws -> String {
        if let data = try readData(account: Account.iphoneDeviceId, configuration: configuration) {
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw CompanionKeyStoreError.invalidStoredDeviceId
            }
            return value
        }

        let value = UUID().uuidString
        try saveData(Data(value.utf8), account: Account.iphoneDeviceId, configuration: configuration)
        return value
    }

    private static func loadOrCreatePrivateKey(
        configuration: FacePassCompanionConfiguration
    ) throws -> P256.Signing.PrivateKey {
        if let data = try readData(account: Account.signingPrivateKey, configuration: configuration) {
            do {
                return try P256.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw CompanionKeyStoreError.invalidStoredPrivateKey
            }
        }

        // Baseline stores CryptoKit P-256 raw key material in Keychain only. A Secure
        // Enclave implementation can be layered behind CompanionKeyStoring after the
        // required entitlement and manual device validation are complete.
        let privateKey = P256.Signing.PrivateKey()
        try saveData(privateKey.rawRepresentation, account: Account.signingPrivateKey, configuration: configuration)
        return privateKey
    }

    private static func readData(
        account: String,
        configuration: FacePassCompanionConfiguration
    ) throws -> Data? {
        var query = keychainQuery(account: account, configuration: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CompanionKeyStoreError.keychainReadFailed(status)
        }
        guard let data = result as? Data else {
            throw CompanionKeyStoreError.keychainReadFailed(errSecInternalError)
        }
        return data
    }

    private static func saveData(
        _ data: Data,
        account: String,
        configuration: FacePassCompanionConfiguration
    ) throws {
        var query = keychainQuery(account: account, configuration: configuration)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = keychainQuery(account: account, configuration: configuration)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CompanionKeyStoreError.keychainWriteFailed(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw CompanionKeyStoreError.keychainWriteFailed(status)
        }
    }

    private static func keychainQuery(
        account: String,
        configuration: FacePassCompanionConfiguration
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.keychainService,
            kSecAttrAccount as String: account
        ]

        if let accessGroup = configuration.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}
