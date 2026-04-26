import Foundation

public let defaultPasswordAccountIdentifier = "default-login-password"

public final class PasswordSettingsController {
    public private(set) var state: PasswordConfigurationState

    private let vault: PasswordVaultProviding
    private let account: String

    public init(
        vault: PasswordVaultProviding = PasswordVault(),
        account: String = defaultPasswordAccountIdentifier
    ) {
        self.vault = vault
        self.account = account
        self.state = PasswordConfigurationState(isPasswordConfigured: false)
        refreshStatus()
    }

    public func savePassword(_ password: String) throws {
        guard !password.isEmpty else {
            state = state.with(lastError: "Password cannot be empty.")
            throw PasswordSettingsError.emptyPassword
        }

        do {
            try vault.savePassword(password, forAccount: account)
            refreshStatus(preservingPreflightStatus: false)
            state = state.with(lastError: nil, keychainPreflightStatus: nil)
        } catch {
            state = state.with(lastError: "Unable to save password.")
            throw PasswordSettingsError.saveFailed
        }
    }

    public func deletePassword() throws {
        do {
            try vault.deletePassword(forAccount: account)
            refreshStatus(preservingPreflightStatus: false)
            state = state.with(lastError: nil, keychainPreflightStatus: nil)
        } catch {
            state = state.with(lastError: "Unable to delete password.")
            throw PasswordSettingsError.deleteFailed
        }
    }

    @discardableResult
    public func preflightKeychainPasswordAccess() -> KeychainPasswordPreflightStatus {
        do {
            guard let password = try vault.password(forAccount: account),
                  !password.isEmpty else {
                state = PasswordConfigurationState(
                    isPasswordConfigured: false,
                    lastError: nil,
                    keychainPreflightStatus: .notConfigured
                )
                return .notConfigured
            }

            // User-triggered preflight only verifies Keychain access; the value is never surfaced or retained.
            state = PasswordConfigurationState(
                isPasswordConfigured: true,
                lastError: nil,
                keychainPreflightStatus: .verified
            )
            return .verified
        } catch {
            state = state.with(lastError: nil, keychainPreflightStatus: .readFailed)
            return .readFailed
        }
    }

    public func refreshStatus() {
        refreshStatus(preservingPreflightStatus: true)
    }

    private func refreshStatus(preservingPreflightStatus: Bool) {
        let preflightStatus = preservingPreflightStatus ? state.keychainPreflightStatus : nil
        do {
            let isPasswordConfigured = try vault.hasPassword(forAccount: account)
            state = PasswordConfigurationState(
                isPasswordConfigured: isPasswordConfigured,
                lastError: nil,
                keychainPreflightStatus: isPasswordConfigured ? preflightStatus : nil
            )
        } catch {
            state = PasswordConfigurationState(
                isPasswordConfigured: false,
                lastError: "Unable to read password status.",
                keychainPreflightStatus: nil
            )
        }
    }
}

public struct PasswordConfigurationState: Equatable, CustomStringConvertible {
    public let isPasswordConfigured: Bool
    public let lastError: String?
    public let keychainPreflightStatus: KeychainPasswordPreflightStatus?

    public init(
        isPasswordConfigured: Bool,
        lastError: String? = nil,
        keychainPreflightStatus: KeychainPasswordPreflightStatus? = nil
    ) {
        self.isPasswordConfigured = isPasswordConfigured
        self.lastError = lastError
        self.keychainPreflightStatus = keychainPreflightStatus
    }

    public var passwordPreview: String? {
        nil
    }

    public var description: String {
        "PasswordConfigurationState(isPasswordConfigured: \(isPasswordConfigured), lastError: \(lastError ?? "nil"), keychainPreflightStatus: \(keychainPreflightStatus?.description ?? "nil"))"
    }

    fileprivate func with(
        lastError: String?,
        keychainPreflightStatus: KeychainPasswordPreflightStatus? = nil
    ) -> PasswordConfigurationState {
        PasswordConfigurationState(
            isPasswordConfigured: isPasswordConfigured,
            lastError: lastError,
            keychainPreflightStatus: keychainPreflightStatus
        )
    }
}

public enum KeychainPasswordPreflightStatus: Equatable, CustomStringConvertible {
    case verified
    case notConfigured
    case readFailed

    public var description: String {
        switch self {
        case .verified:
            "Keychain password access verified for this unlocked session."
        case .notConfigured:
            "No Keychain password is configured."
        case .readFailed:
            "Keychain password access was not verified. Approve the macOS Keychain prompt if it appears, then try again."
        }
    }
}

public enum PasswordSettingsError: Error, Equatable, CustomStringConvertible {
    case emptyPassword
    case saveFailed
    case deleteFailed

    public var description: String {
        switch self {
        case .emptyPassword:
            "Password cannot be empty."
        case .saveFailed:
            "Unable to save password."
        case .deleteFailed:
            "Unable to delete password."
        }
    }
}
