import Foundation
import Security

public struct PasswordVault {
    private let service: String
    private let secItemClient: SecItemClient

    public init(service: String = "com.facepass.password-vault") {
        self.init(service: service, secItemClient: SystemSecItemClient())
    }

    init(service: String, secItemClient: SecItemClient) {
        self.service = service
        self.secItemClient = secItemClient
    }

    public func savePassword(_ password: String, forAccount account: String) throws {
        let passwordData = Data(password.utf8)
        var query = baseQuery(forAccount: account)
        query[kSecValueData as String] = passwordData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = secItemClient.add(query as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            try updatePassword(password, forAccount: account)
        default:
            throw PasswordVaultError.keychainFailure(operation: .save, status: status)
        }
    }

    public func password(forAccount account: String) throws -> String? {
        var query = baseQuery(forAccount: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = secItemClient.copyMatching(query as CFDictionary, result: &result)

        switch status {
        case errSecSuccess:
            guard let passwordData = result as? Data,
                  let password = String(data: passwordData, encoding: .utf8) else {
                throw PasswordVaultError.invalidStoredPasswordData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw PasswordVaultError.keychainFailure(operation: .read, status: status)
        }
    }

    public func hasPassword(forAccount account: String) throws -> Bool {
        var query = baseQuery(forAccount: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true

        let status = secItemClient.copyMatching(query as CFDictionary, result: nil)

        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw PasswordVaultError.keychainFailure(operation: .read, status: status)
        }
    }

    public func updatePassword(_ password: String, forAccount account: String) throws {
        let query = baseQuery(forAccount: account)
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: Data(password.utf8)
        ]

        let status = secItemClient.update(
            query as CFDictionary,
            attributesToUpdate: attributesToUpdate as CFDictionary
        )

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw PasswordVaultError.passwordNotFound
        default:
            throw PasswordVaultError.keychainFailure(operation: .update, status: status)
        }
    }

    public func deletePassword(forAccount account: String) throws {
        let status = secItemClient.delete(baseQuery(forAccount: account) as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw PasswordVaultError.keychainFailure(operation: .delete, status: status)
        }
    }

    private func baseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public protocol PasswordVaultProviding {
    func savePassword(_ password: String, forAccount account: String) throws
    func password(forAccount account: String) throws -> String?
    func hasPassword(forAccount account: String) throws -> Bool
    func deletePassword(forAccount account: String) throws
}

extension PasswordVault: PasswordVaultProviding {}

public enum PasswordVaultError: Error, Equatable, CustomStringConvertible {
    case passwordNotFound
    case invalidStoredPasswordData
    case keychainFailure(operation: PasswordVaultOperation, status: OSStatus)

    public var description: String {
        switch self {
        case .passwordNotFound:
            "Password not found in Keychain."
        case .invalidStoredPasswordData:
            "Stored Keychain item is not valid password data."
        case let .keychainFailure(operation, status):
            "Keychain \(operation.rawValue) failed with status \(status)."
        }
    }
}

public enum PasswordVaultOperation: String, Equatable {
    case save
    case read
    case update
    case delete
}

protocol SecItemClient {
    func add(_ query: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemSecItemClient: SecItemClient {
    func add(_ query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}
