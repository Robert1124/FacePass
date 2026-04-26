import XCTest
@testable import FacePassCore

final class ManualFillControllerTests: XCTestCase {
    func testManualFillDeniedWhenNoPasswordIsConfigured() {
        let vault = SpyPasswordVault(storedPassword: nil)
        let autofill = SpyPasswordAutofillService(result: .filled)
        let controller = ManualFillController(vault: vault, autofillService: autofill, account: "account")

        let result = controller.fillFocusedPasswordField()

        XCTAssertEqual(result, .missingPassword)
        XCTAssertEqual(vault.events, [.readPassword(account: "account")])
        XCTAssertEqual(autofill.events, [.checkedAuthorizationPrompt])
        XCTAssertFalse(String(describing: result).contains("secret"))
    }

    func testManualFillDeniedWhenAccessibilityUnavailable() {
        let password = testPassword()
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = SpyPasswordAutofillService(
            isAccessibilityTrusted: false,
            result: .filled
        )
        let controller = ManualFillController(vault: vault, autofillService: autofill, account: "account")

        let result = controller.fillFocusedPasswordField()

        XCTAssertEqual(result, .accessibilityPermissionDenied)
        XCTAssertTrue(vault.events.isEmpty)
        XCTAssertTrue(autofill.events.isEmpty)
        XCTAssertFalse(String(describing: result).contains(password))
    }

    func testManualFillDoesNotReadPasswordForOrdinarySecureFields() {
        let password = testPassword()
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = SpyPasswordAutofillService(
            focusedStatus: .noFocusedPasswordField,
            result: .filled
        )
        let controller = ManualFillController(vault: vault, autofillService: autofill, account: "account")

        let result = controller.fillFocusedPasswordField()

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertTrue(vault.events.isEmpty)
        XCTAssertEqual(autofill.events, [.checkedAuthorizationPrompt])
    }

    func testManualFillCallsValueFillOnlyWhenPasswordExistsAndFocusedFieldPasses() {
        let password = testPassword()
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = SpyPasswordAutofillService(result: .filled)
        let controller = ManualFillController(vault: vault, autofillService: autofill, account: "account")

        let result = controller.fillFocusedPasswordField()

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(vault.events, [.readPassword(account: "account")])
        XCTAssertEqual(autofill.events, [
            .checkedAuthorizationPrompt,
            .fillAuthorizationValueOnly(passwordLength: password.count)
        ])
        XCTAssertEqual(autofill.forbiddenConfirmationActionCount, 0)
    }

    func testManualFillMapsFocusedFieldAndFillFailuresWithoutExposingPassword() {
        let password = testPassword()
        let cases: [(AccessibilityAutofillResult, ManualFillResult)] = [
            (.noFocusedPasswordField, .noFocusedPasswordField),
            (.focusedPasswordFieldUnavailable, .focusedPasswordFieldUnavailable),
            (.multipleApprovedPasswordFields, .multipleApprovedPasswordFields)
        ]

        for (autofillResult, expectedResult) in cases {
            let vault = SpyPasswordVault(storedPassword: password)
            let autofill = SpyPasswordAutofillService(result: autofillResult)
            let controller = ManualFillController(vault: vault, autofillService: autofill, account: "account")

            let result = controller.fillFocusedPasswordField()

            XCTAssertEqual(result, expectedResult)
            XCTAssertEqual(autofill.events, [
                .checkedAuthorizationPrompt,
                .fillAuthorizationValueOnly(passwordLength: password.count)
            ])
            XCTAssertEqual(autofill.forbiddenConfirmationActionCount, 0)
            XCTAssertFalse(String(describing: result).contains(password))
        }
    }

    func testManualFillReadFailureDoesNotExposePassword() {
        let password = testPassword()
        let vault = SpyPasswordVault(readError: TestVaultError(message: password))
        let autofill = SpyPasswordAutofillService(result: .filled)
        let controller = ManualFillController(vault: vault, autofillService: autofill, account: "account")

        let result = controller.fillFocusedPasswordField()

        XCTAssertEqual(result, .passwordReadFailed)
        XCTAssertEqual(autofill.events, [.checkedAuthorizationPrompt])
        XCTAssertFalse(String(describing: result).contains(password))
    }

    private func testPassword() -> String {
        "manual-fill-test-secret-\(UUID().uuidString)"
    }
}

final class SpyPasswordVault: PasswordVaultProviding {
    private var storedPassword: String?
    private let saveError: Error?
    private let readError: Error?
    private(set) var events: [PasswordVaultEvent] = []

    init(storedPassword: String? = nil, saveError: Error? = nil, readError: Error? = nil) {
        self.storedPassword = storedPassword
        self.saveError = saveError
        self.readError = readError
    }

    func savePassword(_ password: String, forAccount account: String) throws {
        events.append(.savedPassword(account: account, passwordLength: password.count))
        if let saveError {
            throw saveError
        }
        storedPassword = password
    }

    func password(forAccount account: String) throws -> String? {
        events.append(.readPassword(account: account))
        if let readError {
            throw readError
        }
        return storedPassword
    }

    func hasPassword(forAccount account: String) throws -> Bool {
        events.append(.checkedPassword(account: account))
        if let readError {
            throw readError
        }
        return storedPassword != nil
    }

    func setStoredPassword(_ password: String?) {
        storedPassword = password
    }

    func deletePassword(forAccount account: String) throws {
        events.append(.deletedPassword(account: account))
        storedPassword = nil
    }
}

private final class SpyPasswordAutofillService: PasswordAutofillService {
    let isAccessibilityTrusted: Bool
    private let focusedStatus: AuthorizationPromptPasswordFieldStatus
    private let result: AccessibilityAutofillResult
    private(set) var events: [AutofillEvent] = []
    private(set) var forbiddenConfirmationActionCount = 0

    init(
        isAccessibilityTrusted: Bool = true,
        focusedStatus: AuthorizationPromptPasswordFieldStatus = .available,
        result: AccessibilityAutofillResult
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.focusedStatus = focusedStatus
        self.result = result
    }

    func focusedAuthorizationPromptStatus() -> AuthorizationPromptPasswordFieldStatus {
        events.append(.checkedAuthorizationPrompt)
        return focusedStatus
    }

    func fillFocusedPasswordField(with password: String) -> AccessibilityAutofillResult {
        events.append(.fillValueOnly(passwordLength: password.count))
        return result
    }

    func fillFocusedAuthorizationPasswordField(with password: String) -> AccessibilityAutofillResult {
        events.append(.fillAuthorizationValueOnly(passwordLength: password.count))
        return result
    }
}

enum PasswordVaultEvent: Equatable {
    case checkedPassword(account: String)
    case readPassword(account: String)
    case savedPassword(account: String, passwordLength: Int)
    case deletedPassword(account: String)
}

private enum AutofillEvent: Equatable {
    case checkedAuthorizationPrompt
    case fillValueOnly(passwordLength: Int)
    case fillAuthorizationValueOnly(passwordLength: Int)
}

struct TestVaultError: Error {
    let message: String
}
