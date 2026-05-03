import CryptoKit
import Foundation
import Security

public struct MacDeviceIdentity: Equatable {
    public let macDeviceId: String
    public let publicKeyX963Representation: Data
    public let publicKeyFingerprint: String

    public init(
        macDeviceId: String,
        publicKeyX963Representation: Data,
        publicKeyFingerprint: String
    ) {
        self.macDeviceId = macDeviceId
        self.publicKeyX963Representation = publicKeyX963Representation
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

public enum MacDeviceIdentityStoreError: Error, Equatable, CustomStringConvertible {
    case invalidStoredIdentity
    case keychainFailure(OSStatus)

    public var description: String {
        switch self {
        case .invalidStoredIdentity:
            "Stored Mac StandBy Unlock identity is invalid."
        case .keychainFailure:
            "Mac StandBy Unlock identity Keychain operation failed."
        }
    }
}

public final class MacDeviceIdentityStore {
    public static let defaultService = "com.facepass.standby-mac-identity"

    private enum Account {
        static let identity = "identity"
    }

    private struct StoredIdentity: Codable {
        let macDeviceId: String
        let privateKeyRawRepresentation: Data
    }

    private let service: String

    public init(service: String = MacDeviceIdentityStore.defaultService) {
        self.service = service
    }

    public func loadOrCreateIdentity() throws -> MacDeviceIdentity {
        if let storedIdentity = try loadStoredIdentity() {
            return try makeIdentity(from: storedIdentity)
        }

        let privateKey = P256.Signing.PrivateKey()
        let storedIdentity = StoredIdentity(
            macDeviceId: "mac-\(UUID().uuidString)",
            privateKeyRawRepresentation: privateKey.rawRepresentation
        )
        try saveStoredIdentity(storedIdentity)
        return try makeIdentity(from: storedIdentity)
    }

    private func loadStoredIdentity() throws -> StoredIdentity? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw MacDeviceIdentityStoreError.invalidStoredIdentity
            }
            do {
                return try JSONDecoder().decode(StoredIdentity.self, from: data)
            } catch {
                throw MacDeviceIdentityStoreError.invalidStoredIdentity
            }
        case errSecItemNotFound:
            return nil
        default:
            throw MacDeviceIdentityStoreError.keychainFailure(status)
        }
    }

    private func saveStoredIdentity(_ identity: StoredIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw MacDeviceIdentityStoreError.keychainFailure(updateStatus)
            }
        default:
            throw MacDeviceIdentityStoreError.keychainFailure(status)
        }
    }

    private func makeIdentity(from storedIdentity: StoredIdentity) throws -> MacDeviceIdentity {
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: storedIdentity.privateKeyRawRepresentation)
        } catch {
            throw MacDeviceIdentityStoreError.invalidStoredIdentity
        }

        let publicKey = privateKey.publicKey.x963Representation
        return MacDeviceIdentity(
            macDeviceId: storedIdentity.macDeviceId,
            publicKeyX963Representation: publicKey,
            publicKeyFingerprint: Self.fingerprint(forPublicKeyX963Representation: publicKey)
        )
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Account.identity,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    public static func fingerprint(forPublicKeyX963Representation publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return "SHA256:\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}
