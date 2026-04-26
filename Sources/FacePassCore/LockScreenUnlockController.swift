import ApplicationServices
import Foundation

public protocol LockScreenStateProviding {
    var isSessionLocked: Bool { get }
}

public struct SystemLockScreenStateProvider: LockScreenStateProviding {
    private static let lockedSessionKey = "CGSSessionScreenIsLocked"

    private let sessionDictionaryProvider: SessionDictionaryProviding

    public init() {
        self.init(sessionDictionaryProvider: SystemSessionDictionaryProvider())
    }

    init(sessionDictionaryProvider: SessionDictionaryProviding) {
        self.sessionDictionaryProvider = sessionDictionaryProvider
    }

    public var isSessionLocked: Bool {
        guard let sessionDictionary = sessionDictionaryProvider.currentSessionDictionary(),
              let lockedValue = sessionDictionary[Self.lockedSessionKey] else {
            return false
        }

        if let isLocked = lockedValue as? Bool {
            return isLocked
        }

        if let lockedNumber = lockedValue as? NSNumber {
            return lockedNumber.boolValue
        }

        return false
    }
}

public protocol LockScreenPasswordTyping {
    func typePasswordAndSubmit(_ password: String) -> Bool
}

public struct SystemLockScreenPasswordTyper: LockScreenPasswordTyping {
    private let keyboardEventPoster: LockScreenKeyboardEventPosting

    public init() {
        self.init(keyboardEventPoster: SystemLockScreenKeyboardEventPoster())
    }

    init(keyboardEventPoster: LockScreenKeyboardEventPosting) {
        self.keyboardEventPoster = keyboardEventPoster
    }

    public func typePasswordAndSubmit(_ password: String) -> Bool {
        guard !password.isEmpty else {
            return false
        }

        return keyboardEventPoster.postUnicodeString(password) &&
            keyboardEventPoster.postReturnKey()
    }
}

public final class LockScreenUnlockController {
    private let stateProvider: LockScreenStateProviding
    private let passwordVault: PasswordVaultProviding
    private let passwordTyper: LockScreenPasswordTyping
    private let account: String

    public init(
        stateProvider: LockScreenStateProviding = SystemLockScreenStateProvider(),
        passwordVault: PasswordVaultProviding = PasswordVault(),
        passwordTyper: LockScreenPasswordTyping = SystemLockScreenPasswordTyper(),
        account: String = defaultPasswordAccountIdentifier
    ) {
        self.stateProvider = stateProvider
        self.passwordVault = passwordVault
        self.passwordTyper = passwordTyper
        self.account = account
    }

    public func attemptUnlock(
        isEnabled: Bool,
        isAccessibilityTrusted: Bool
    ) -> LockScreenUnlockResult {
        guard isEnabled else {
            return .disabled
        }

        guard isAccessibilityTrusted else {
            return .accessibilityPermissionDenied
        }

        guard stateProvider.isSessionLocked else {
            return .sessionNotLocked
        }

        do {
            guard let password = try passwordVault.password(forAccount: account),
                  !password.isEmpty else {
                return .missingPassword
            }

            return passwordTyper.typePasswordAndSubmit(password)
                ? .typedPasswordAndSubmitted
                : .typingFailed
        } catch {
            return .passwordReadFailed
        }
    }
}

public enum LockScreenUnlockResult: Equatable, CustomStringConvertible {
    case typedPasswordAndSubmitted
    case disabled
    case accessibilityPermissionDenied
    case sessionNotLocked
    case missingPassword
    case passwordReadFailed
    case typingFailed

    public var description: String {
        switch self {
        case .typedPasswordAndSubmitted:
            "Saved password typed for the locked session and Return was sent."
        case .disabled:
            "Lock-screen unlock is off."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required before the lock-screen path can run."
        case .sessionNotLocked:
            "macOS is not currently locked."
        case .missingPassword:
            "No password is configured."
        case .passwordReadFailed:
            "Unable to read password."
        case .typingFailed:
            "Lock-screen typing could not be completed."
        }
    }
}

protocol SessionDictionaryProviding {
    func currentSessionDictionary() -> [String: Any]?
}

private struct SystemSessionDictionaryProvider: SessionDictionaryProviding {
    func currentSessionDictionary() -> [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }
}

protocol LockScreenKeyboardEventPosting {
    func postUnicodeString(_ string: String) -> Bool
    func postReturnKey() -> Bool
}

private struct SystemLockScreenKeyboardEventPoster: LockScreenKeyboardEventPosting {
    func postUnicodeString(_ string: String) -> Bool {
        let unicodeScalars = Array(string.utf16)
        guard !unicodeScalars.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
        keyUp.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func postReturnKey() -> Bool {
        postVirtualKey(36)
    }

    private func postVirtualKey(_ keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
