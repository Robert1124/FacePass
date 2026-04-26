import Foundation
import XCTest
@testable import FacePassCore

final class LockScreenUnlockControllerTests: XCTestCase {
    func testDisabledOptInReturnsDisabledWithoutReadingOrTyping() {
        let vault = SpyPasswordVault(storedPassword: testPassword())
        let typer = RecordingLockScreenPasswordTyper()
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: false, isAccessibilityTrusted: true)

        XCTAssertEqual(result, .disabled)
        XCTAssertTrue(vault.events.isEmpty)
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testAccessibilityDeniedReturnsPermissionFailureWithoutReadingOrTyping() {
        let vault = SpyPasswordVault(storedPassword: testPassword())
        let typer = RecordingLockScreenPasswordTyper()
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: true, isAccessibilityTrusted: false)

        XCTAssertEqual(result, .accessibilityPermissionDenied)
        XCTAssertTrue(vault.events.isEmpty)
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testUnlockedSessionReturnsSessionNotLockedWithoutReadingOrTyping() {
        let vault = SpyPasswordVault(storedPassword: testPassword())
        let typer = RecordingLockScreenPasswordTyper()
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: true, isAccessibilityTrusted: true)

        XCTAssertEqual(result, .sessionNotLocked)
        XCTAssertTrue(vault.events.isEmpty)
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testMissingPasswordReturnsMissingPasswordWithoutTyping() {
        let vault = SpyPasswordVault(storedPassword: nil)
        let typer = RecordingLockScreenPasswordTyper()
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: true, isAccessibilityTrusted: true)

        XCTAssertEqual(result, .missingPassword)
        XCTAssertEqual(vault.events, [.readPassword(account: "lock-screen-account")])
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testPasswordReadFailureDoesNotExposeUnderlyingErrorText() {
        let secret = testPassword()
        let vault = SpyPasswordVault(readError: TestVaultError(message: secret))
        let typer = RecordingLockScreenPasswordTyper()
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: true, isAccessibilityTrusted: true)

        XCTAssertEqual(result, .passwordReadFailed)
        XCTAssertEqual(vault.events, [.readPassword(account: "lock-screen-account")])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertFalse(result.description.contains(secret))
        XCTAssertFalse(String(describing: result).contains(secret))
    }

    func testTypingFailureDoesNotExposePassword() {
        let secret = testPassword()
        let vault = SpyPasswordVault(storedPassword: secret)
        let typer = RecordingLockScreenPasswordTyper(shouldSucceed: false)
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: true, isAccessibilityTrusted: true)

        XCTAssertEqual(result, .typingFailed)
        XCTAssertEqual(vault.events, [.readPassword(account: "lock-screen-account")])
        XCTAssertEqual(typer.events, [.typedPasswordAndSubmit(passwordLength: secret.count)])
        XCTAssertTrue(typer.didReceiveExpectedPassword(secret))
        XCTAssertFalse(result.description.contains(secret))
    }

    func testSuccessTypesPasswordAndSubmitWithoutRecordingSecretValue() {
        let secret = testPassword()
        let vault = SpyPasswordVault(storedPassword: secret)
        let typer = RecordingLockScreenPasswordTyper()
        let controller = LockScreenUnlockController(
            stateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            passwordVault: vault,
            passwordTyper: typer,
            account: "lock-screen-account"
        )

        let result = controller.attemptUnlock(isEnabled: true, isAccessibilityTrusted: true)

        XCTAssertEqual(result, .typedPasswordAndSubmitted)
        XCTAssertEqual(vault.events, [.readPassword(account: "lock-screen-account")])
        XCTAssertEqual(typer.events, [.typedPasswordAndSubmit(passwordLength: secret.count)])
        XCTAssertTrue(typer.didReceiveExpectedPassword(secret))
    }

    func testSystemLockScreenStateProviderHandlesCommonSessionDictionaryShapes() {
        XCTAssertTrue(
            SystemLockScreenStateProvider(
                sessionDictionaryProvider: StubSessionDictionaryProvider(
                    currentDictionary: ["CGSSessionScreenIsLocked": true]
                )
            ).isSessionLocked
        )
        XCTAssertFalse(
            SystemLockScreenStateProvider(
                sessionDictionaryProvider: StubSessionDictionaryProvider(
                    currentDictionary: ["CGSSessionScreenIsLocked": false]
                )
            ).isSessionLocked
        )
        XCTAssertTrue(
            SystemLockScreenStateProvider(
                sessionDictionaryProvider: StubSessionDictionaryProvider(
                    currentDictionary: ["CGSSessionScreenIsLocked": NSNumber(value: true)]
                )
            ).isSessionLocked
        )
        XCTAssertFalse(
            SystemLockScreenStateProvider(
                sessionDictionaryProvider: StubSessionDictionaryProvider(
                    currentDictionary: ["CGSSessionScreenIsLocked": NSNumber(value: false)]
                )
            ).isSessionLocked
        )
        XCTAssertFalse(
            SystemLockScreenStateProvider(
                sessionDictionaryProvider: StubSessionDictionaryProvider(currentDictionary: [:])
            ).isSessionLocked
        )
        XCTAssertFalse(
            SystemLockScreenStateProvider(
                sessionDictionaryProvider: StubSessionDictionaryProvider(currentDictionary: nil)
            ).isSessionLocked
        )
    }

    private func testPassword() -> String {
        "lock-screen-test-secret-\(UUID().uuidString)"
    }
}

struct StubLockScreenStateProvider: LockScreenStateProviding {
    let isSessionLocked: Bool
}

final class RecordingLockScreenPasswordTyper: LockScreenPasswordTyping {
    private let shouldSucceed: Bool
    private var lastPassword: String?
    private(set) var events: [LockScreenTypingEvent] = []

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func typePasswordAndSubmit(_ password: String) -> Bool {
        lastPassword = password
        events.append(.typedPasswordAndSubmit(passwordLength: password.count))
        return shouldSucceed
    }

    func didReceiveExpectedPassword(_ expectedPassword: String) -> Bool {
        lastPassword == expectedPassword
    }
}

enum LockScreenTypingEvent: Equatable {
    case typedPasswordAndSubmit(passwordLength: Int)
}

struct StubSessionDictionaryProvider: SessionDictionaryProviding {
    let currentDictionary: [String: Any]?

    func currentSessionDictionary() -> [String: Any]? {
        currentDictionary
    }
}
