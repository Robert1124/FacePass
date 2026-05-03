import Foundation

public final class ManualFillController {
    private let vault: PasswordVaultProviding
    private let autofillService: PasswordAutofillService
    private let account: String

    public init(
        vault: PasswordVaultProviding = PasswordVault(),
        autofillService: PasswordAutofillService = AccessibilityAutofillService(),
        account: String = defaultPasswordAccountIdentifier
    ) {
        self.vault = vault
        self.autofillService = autofillService
        self.account = account
    }

    public func fillFocusedPasswordField() -> ManualFillResult {
        fillFocusedAuthorizationPromptPasswordField()
    }

    public func focusedAuthorizationPromptStatus() -> AuthorizationPromptPasswordFieldStatus {
        guard autofillService.isAccessibilityTrusted else {
            return .accessibilityPermissionDenied
        }

        return autofillService.focusedAuthorizationPromptStatus()
    }

    public func authorizationPromptCandidateDiagnosticSummary() -> String? {
        autofillService.authorizationPromptCandidateDiagnosticSummary()
    }

    public func fillFocusedAuthorizationPromptPasswordField() -> ManualFillResult {
        guard autofillService.isAccessibilityTrusted else {
            return .accessibilityPermissionDenied
        }

        let promptStatus = autofillService.focusedAuthorizationPromptStatus()
        guard promptStatus == .available else {
            return ManualFillResult(promptStatus)
        }

        do {
            guard let password = try vault.password(forAccount: account),
                  !password.isEmpty else {
                return .missingPassword
            }

            switch autofillService.fillFocusedAuthorizationPasswordField(with: password) {
            case .filled:
                return .filled
            case .accessibilityPermissionDenied:
                return .accessibilityPermissionDenied
            case .noFocusedPasswordField:
                return .noFocusedPasswordField
            case .focusedPasswordFieldUnavailable:
                return .focusedPasswordFieldUnavailable
            case .multipleApprovedPasswordFields:
                return .multipleApprovedPasswordFields
            }
        } catch {
            return .passwordReadFailed
        }
    }
}

public enum ManualFillResult: Equatable, CustomStringConvertible {
    case filled
    case missingPassword
    case accessibilityPermissionDenied
    case noFocusedPasswordField
    case focusedPasswordFieldUnavailable
    case multipleApprovedPasswordFields
    case passwordReadFailed
    case recognitionRejected
    case localRecognitionDisabled

    public var description: String {
        switch self {
        case .filled:
            "Authorization password filled."
        case .missingPassword:
            "No password is configured."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required before filling."
        case .noFocusedPasswordField:
            "No approved macOS administrator/System Settings authorization prompt or Apple Passwords unlock prompt was found."
        case .focusedPasswordFieldUnavailable:
            "The approved authorization password field is unavailable."
        case .multipleApprovedPasswordFields:
            "Multiple approved authorization password fields were found."
        case .passwordReadFailed:
            "Unable to read password."
        case .recognitionRejected:
            "Local FacePass recognition did not approve authorization fill."
        case .localRecognitionDisabled:
            "Local FacePass recognition is disabled by the selected unlock provider mode."
        }
    }

    init(_ promptStatus: AuthorizationPromptPasswordFieldStatus) {
        switch promptStatus {
        case .available:
            self = .filled
        case .accessibilityPermissionDenied:
            self = .accessibilityPermissionDenied
        case .noFocusedPasswordField:
            self = .noFocusedPasswordField
        case .focusedPasswordFieldUnavailable:
            self = .focusedPasswordFieldUnavailable
        case .multipleApprovedPasswordFields:
            self = .multipleApprovedPasswordFields
        }
    }
}
