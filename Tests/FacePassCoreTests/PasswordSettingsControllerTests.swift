import XCTest
@testable import FacePassCore

final class PasswordSettingsControllerTests: XCTestCase {
    func testInitialStateReflectsConfiguredPasswordWithoutExposingSecret() {
        let password = testPassword()
        let vault = SpyPasswordVault(storedPassword: password)

        let controller = PasswordSettingsController(vault: vault, account: "account")

        XCTAssertTrue(controller.state.isPasswordConfigured)
        XCTAssertNil(controller.state.passwordPreview)
        XCTAssertFalse(String(describing: controller.state).contains(password))
        XCTAssertEqual(vault.events, [.checkedPassword(account: "account")])
    }

    func testSaveDelegatesToVaultAndRefreshesConfiguredStatus() throws {
        let password = testPassword()
        let vault = SpyPasswordVault()
        let controller = PasswordSettingsController(vault: vault, account: "account")

        try controller.savePassword(password)

        XCTAssertTrue(controller.state.isPasswordConfigured)
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: "account"),
            .savedPassword(account: "account", passwordLength: password.count),
            .checkedPassword(account: "account")
        ])
        XCTAssertFalse(String(describing: controller.state.lastError).contains(password))
    }

    func testEmptyPasswordIsRejectedWithoutSaving() {
        let vault = SpyPasswordVault()
        let controller = PasswordSettingsController(vault: vault, account: "account")

        XCTAssertThrowsError(try controller.savePassword("")) { error in
            XCTAssertEqual(error as? PasswordSettingsError, .emptyPassword)
        }

        XCTAssertFalse(controller.state.isPasswordConfigured)
        XCTAssertEqual(controller.state.lastError, "Password cannot be empty.")
        XCTAssertEqual(vault.events, [.checkedPassword(account: "account")])
    }

    func testDeleteDelegatesToVaultAndRefreshesConfiguredStatus() throws {
        let vault = SpyPasswordVault(storedPassword: testPassword())
        let controller = PasswordSettingsController(vault: vault, account: "account")

        try controller.deletePassword()

        XCTAssertFalse(controller.state.isPasswordConfigured)
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: "account"),
            .deletedPassword(account: "account"),
            .checkedPassword(account: "account")
        ])
    }

    func testSaveFailureDoesNotExposePasswordInStateError() {
        let password = testPassword()
        let vault = SpyPasswordVault(saveError: TestVaultError(message: "failed"))
        let controller = PasswordSettingsController(vault: vault, account: "account")

        XCTAssertThrowsError(try controller.savePassword(password))

        XCTAssertEqual(controller.state.lastError, "Unable to save password.")
        XCTAssertFalse(controller.state.lastError?.contains(password) ?? true)
    }

    func testPreflightReadsConfiguredPasswordAndDiscardsItWithoutExposingSecretOrLength() {
        let password = testPassword()
        let vault = SpyPasswordVault(storedPassword: password)
        let controller = PasswordSettingsController(vault: vault, account: "account")

        let result = controller.preflightKeychainPasswordAccess()

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(controller.state.keychainPreflightStatus, .verified)
        XCTAssertTrue(controller.state.isPasswordConfigured)
        XCTAssertFalse(String(describing: result).contains(password))
        XCTAssertFalse(String(describing: controller.state).contains(password))
        XCTAssertFalse(String(describing: result).contains("\(password.count)"))
        XCTAssertFalse(String(describing: controller.state).contains("\(password.count)"))
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: "account"),
            .readPassword(account: "account")
        ])
    }

    func testPreflightReportsMissingPasswordWithoutSavingOrExposingSecretMetadata() {
        let vault = SpyPasswordVault(storedPassword: nil)
        let controller = PasswordSettingsController(vault: vault, account: "account")

        let result = controller.preflightKeychainPasswordAccess()

        XCTAssertEqual(result, .notConfigured)
        XCTAssertEqual(controller.state.keychainPreflightStatus, .notConfigured)
        XCTAssertFalse(controller.state.isPasswordConfigured)
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: "account"),
            .readPassword(account: "account")
        ])
    }

    func testPreflightReadFailureUsesSafeStatusText() {
        let password = testPassword()
        let vault = SpyPasswordVault(storedPassword: password, readError: TestVaultError(message: password))
        let controller = PasswordSettingsController(vault: vault, account: "account")

        let result = controller.preflightKeychainPasswordAccess()

        XCTAssertEqual(result, .readFailed)
        XCTAssertEqual(controller.state.keychainPreflightStatus, .readFailed)
        XCTAssertFalse(String(describing: result).contains(password))
        XCTAssertFalse(String(describing: controller.state).contains(password))
    }

    private func testPassword() -> String {
        "controller-test-secret-\(UUID().uuidString)"
    }
}
