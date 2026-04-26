import Security
import XCTest
@testable import FacePassCore

final class PasswordVaultTests: XCTestCase {
    private var cleanupItems: [(service: String, account: String)] = []

    override func tearDownWithError() throws {
        for item in cleanupItems {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account
            ]
            SecItemDelete(query as CFDictionary)
        }
        cleanupItems.removeAll()
        try super.tearDownWithError()
    }

    func testSaveAndReadPasswordRoundTripsThroughKeychain() throws {
        let service = uniqueService()
        let account = uniqueAccount()
        let password = testPassword("roundtrip")
        cleanupItems.append((service, account))
        let vault = PasswordVault(service: service)

        try vault.savePassword(password, forAccount: account)

        let loadedPassword = try vault.password(forAccount: account)
        XCTAssertTrue(loadedPassword == password)
    }

    func testSaveUpdatesExistingKeychainItem() throws {
        let service = uniqueService()
        let account = uniqueAccount()
        let oldPassword = testPassword("old")
        let newPassword = testPassword("new")
        cleanupItems.append((service, account))
        let vault = PasswordVault(service: service)

        try vault.savePassword(oldPassword, forAccount: account)
        try vault.savePassword(newPassword, forAccount: account)

        let loadedPassword = try vault.password(forAccount: account)
        XCTAssertTrue(loadedPassword == newPassword)
    }

    func testUpdateRequiresExistingKeychainItem() throws {
        let service = uniqueService()
        let account = uniqueAccount()
        cleanupItems.append((service, account))
        let vault = PasswordVault(service: service)

        XCTAssertThrowsError(try vault.updatePassword(testPassword("missing-update"), forAccount: account)) { error in
            XCTAssertEqual(error as? PasswordVaultError, .passwordNotFound)
        }
    }

    func testDeleteRemovesStoredKeychainItem() throws {
        let service = uniqueService()
        let account = uniqueAccount()
        let password = testPassword("delete")
        cleanupItems.append((service, account))
        let vault = PasswordVault(service: service)

        try vault.savePassword(password, forAccount: account)
        try vault.deletePassword(forAccount: account)

        let loadedPassword = try vault.password(forAccount: account)
        XCTAssertNil(loadedPassword)
    }

    func testMissingPasswordReturnsNil() throws {
        let vault = PasswordVault(service: uniqueService())

        let loadedPassword = try vault.password(forAccount: uniqueAccount())

        XCTAssertNil(loadedPassword)
    }

    func testMapsAddFailureWithoutExposingPasswordMaterial() {
        let client = StubSecItemClient(addStatus: errSecAuthFailed)
        let vault = PasswordVault(service: uniqueService(), secItemClient: client)
        let password = testPassword("add-failure")

        XCTAssertThrowsError(try vault.savePassword(password, forAccount: uniqueAccount())) { error in
            XCTAssertEqual(error as? PasswordVaultError, .keychainFailure(operation: .save, status: errSecAuthFailed))
            XCTAssertFalse(String(describing: error).contains(password))
        }
    }

    func testMapsUnexpectedReadFailure() {
        let client = StubSecItemClient(copyMatchingStatus: errSecInteractionNotAllowed)
        let vault = PasswordVault(service: uniqueService(), secItemClient: client)

        XCTAssertThrowsError(try vault.password(forAccount: uniqueAccount())) { error in
            XCTAssertEqual(error as? PasswordVaultError, .keychainFailure(operation: .read, status: errSecInteractionNotAllowed))
        }
    }

    func testSaveUsesDeviceOnlyKeychainAccessibility() throws {
        let client = StubSecItemClient()
        let service = uniqueService()
        let account = uniqueAccount()
        let vault = PasswordVault(service: service, secItemClient: client)

        try vault.savePassword(testPassword("accessibility"), forAccount: account)

        XCTAssertEqual(client.lastAddQuery?[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(client.lastAddQuery?[kSecAttrService as String] as? String, service)
        XCTAssertEqual(client.lastAddQuery?[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(
            client.lastAddQuery?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testHasPasswordChecksKeychainStatusWithoutReturningPasswordData() throws {
        let client = StubSecItemClient(copyMatchingStatus: errSecSuccess)
        let service = uniqueService()
        let account = uniqueAccount()
        let vault = PasswordVault(service: service, secItemClient: client)

        XCTAssertTrue(try vault.hasPassword(forAccount: account))

        XCTAssertEqual(client.lastCopyMatchingQuery?[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(client.lastCopyMatchingQuery?[kSecAttrService as String] as? String, service)
        XCTAssertEqual(client.lastCopyMatchingQuery?[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(client.lastCopyMatchingQuery?[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(client.lastCopyMatchingQuery?[kSecReturnData as String])
    }

    func testHasPasswordReturnsFalseForMissingKeychainItem() throws {
        let client = StubSecItemClient(copyMatchingStatus: errSecItemNotFound)
        let vault = PasswordVault(service: uniqueService(), secItemClient: client)

        XCTAssertFalse(try vault.hasPassword(forAccount: uniqueAccount()))
    }

    func testInvalidStoredPasswordDataThrowsWithoutExposingMaterial() {
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD]) as NSData
        let client = StubSecItemClient(copyMatchingStatus: errSecSuccess, copyMatchingResult: invalidUTF8)
        let vault = PasswordVault(service: uniqueService(), secItemClient: client)

        XCTAssertThrowsError(try vault.password(forAccount: uniqueAccount())) { error in
            XCTAssertEqual(error as? PasswordVaultError, .invalidStoredPasswordData)
            XCTAssertFalse(String(describing: error).contains("FF"))
            XCTAssertFalse(String(describing: error).contains("FE"))
            XCTAssertFalse(String(describing: error).contains("FD"))
        }
    }

    func testMapsUnexpectedUpdateFailure() {
        let client = StubSecItemClient(updateStatus: errSecInteractionNotAllowed)
        let vault = PasswordVault(service: uniqueService(), secItemClient: client)

        XCTAssertThrowsError(try vault.updatePassword(testPassword("update-failure"), forAccount: uniqueAccount())) { error in
            XCTAssertEqual(error as? PasswordVaultError, .keychainFailure(operation: .update, status: errSecInteractionNotAllowed))
        }
    }

    func testMapsUnexpectedDeleteFailure() {
        let client = StubSecItemClient(deleteStatus: errSecInteractionNotAllowed)
        let vault = PasswordVault(service: uniqueService(), secItemClient: client)

        XCTAssertThrowsError(try vault.deletePassword(forAccount: uniqueAccount())) { error in
            XCTAssertEqual(error as? PasswordVaultError, .keychainFailure(operation: .delete, status: errSecInteractionNotAllowed))
        }
    }

    private func uniqueService() -> String {
        "com.facepass.tests.password-vault.\(UUID().uuidString)"
    }

    private func uniqueAccount() -> String {
        "account-\(UUID().uuidString)"
    }

    private func testPassword(_ label: String) -> String {
        "facepass-test-secret-\(label)-\(UUID().uuidString)"
    }
}

private final class StubSecItemClient: SecItemClient {
    private let addStatus: OSStatus
    private let updateStatus: OSStatus
    private let copyMatchingStatus: OSStatus
    private let copyMatchingResult: CFTypeRef?
    private let deleteStatus: OSStatus
    private(set) var lastAddQuery: [String: Any]?
    private(set) var lastCopyMatchingQuery: [String: Any]?

    init(
        addStatus: OSStatus = errSecSuccess,
        updateStatus: OSStatus = errSecSuccess,
        copyMatchingStatus: OSStatus = errSecItemNotFound,
        copyMatchingResult: CFTypeRef? = nil,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.addStatus = addStatus
        self.updateStatus = updateStatus
        self.copyMatchingStatus = copyMatchingStatus
        self.copyMatchingResult = copyMatchingResult
        self.deleteStatus = deleteStatus
    }

    func add(_ query: CFDictionary) -> OSStatus {
        lastAddQuery = query as NSDictionary as? [String: Any]
        return addStatus
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        updateStatus
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lastCopyMatchingQuery = query as NSDictionary as? [String: Any]
        if copyMatchingStatus == errSecSuccess {
            result?.pointee = copyMatchingResult
        }
        return copyMatchingStatus
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteStatus
    }
}
