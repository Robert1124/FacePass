import XCTest
@testable import FacePassCore

final class AccessibilityAutofillServiceTests: XCTestCase {
    func testPermissionDeniedPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .ordinarySecurePasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: false),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .accessibilityPermissionDenied)
        XCTAssertTrue(client.recordedEvents.isEmpty)
    }

    func testMissingFocusedElementPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: nil)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testNilFocusedElementFallsBackToSingleDiscoverableApprovedAuthorizationSecureField() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .systemSettingsPrivacySecurityAuthorizationPasswordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(status, .available)
        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .setValue(
                elementID: AccessibilityElementSnapshot.systemSettingsPrivacySecurityAuthorizationPasswordField.id,
                valueLength: password.count
            )
        ])
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testNonPasswordFocusedElementFallsBackToSingleDiscoverableApprovedAuthorizationSecureField() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(
            focusedElement: .plainTextField,
            authorizationPasswordFieldCandidates: [
                .securityAgentAuthorizationPasswordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .setValue(
                elementID: AccessibilityElementSnapshot.securityAgentAuthorizationPasswordField.id,
                valueLength: password.count
            )
        ])
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testDiscoverableGenericLocalAuthenticationPromptStillPreventsFill() {
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .localAuthenticationGenericPasswordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testMultipleDiscoverableApprovedAuthorizationSecureFieldsFailClosed() {
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .securityAgentAuthorizationPasswordField,
                .systemSettingsAuthorizationPasswordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(status, .multipleApprovedPasswordFields)
        XCTAssertEqual(result, .multipleApprovedPasswordFields)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
        XCTAssertNil(client.lastSetValue)
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testDuplicateDiscoverableApprovedAuthorizationSecureFieldsWithSameElementIDCoalesceToSingleAvailableField() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .localAuthenticationPrivacySecurityAuthorizationPasswordField(id: "local-auth-same-native-id"),
                .localAuthenticationPrivacySecurityAuthorizationPasswordField(id: "local-auth-same-native-id")
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(status, .available)
        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .setValue(
                elementID: AccessibilityElementID(rawValue: "local-auth-same-native-id"),
                valueLength: password.count
            )
        ])
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertFalse(String(describing: client.recordedEvents).contains(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testDuplicateDiscoverableApprovedAuthorizationSecureFieldsWithDifferentElementIDsFailClosed() {
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .localAuthenticationPrivacySecurityAuthorizationPasswordField(id: "local-auth-password-one"),
                .localAuthenticationPrivacySecurityAuthorizationPasswordField(id: "local-auth-password-two")
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(status, .multipleApprovedPasswordFields)
        XCTAssertEqual(result, .multipleApprovedPasswordFields)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
        XCTAssertNil(client.lastSetValue)
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testFocusedSystemSettingsSecureFieldWithInsufficientMetadataWinsWhenFallbackIncludesSameApprovedField() {
        let password = testPassword()
        let focusedField = AccessibilityElementSnapshot.insufficientMetadataSystemSettingsPasswordField(
            id: "system-settings-focused-password"
        )
        let duplicateProxyField = AccessibilityElementSnapshot.systemSettingsPrivacySecurityAuthorizationPasswordField(
            id: "system-settings-duplicate-proxy-password",
            fieldTextFragments: [
                "Password:"
            ]
        )
        let client = SpyAccessibilityElementClient(
            focusedElement: focusedField,
            authorizationPasswordFieldCandidates: [
                .systemSettingsPrivacySecurityAuthorizationPasswordField(
                    id: "system-settings-focused-password",
                    fieldTextFragments: [
                        "Password:"
                    ]
                ),
                duplicateProxyField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(status, .available)
        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .setValue(
                elementID: focusedField.id,
                valueLength: password.count
            )
        ])
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertFalse(String(describing: client.recordedEvents).contains(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testMultipleApprovedFieldDiagnosticsRedactSensitiveTextFragments() {
        let sensitiveUsername = "real.user@example.com"
        let sensitivePassword = "correct-horse-battery-staple"
        let metadata = AuthorizationPromptMetadata(
            bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
            processName: "coreautha",
            windowTitle: "Privacy & Security",
            promptTextFragments: [
                "System Settings is trying to unlock Privacy & Security for \(sensitiveUsername).",
                "Enter an administrator password to allow this."
            ]
        )
        let firstField = AccessibilityElementSnapshot(
            id: AccessibilityElementID(rawValue: "local-auth-native-id-one"),
            role: .textField,
            subrole: .secureTextField,
            isEnabled: true,
            isSettable: true,
            authorizationPromptMetadata: metadata,
            fieldTextFragments: [
                "Password:",
                sensitivePassword
            ]
        )
        let secondField = AccessibilityElementSnapshot(
            id: AccessibilityElementID(rawValue: "local-auth-native-id-two"),
            role: .textField,
            subrole: .secureTextField,
            isEnabled: true,
            isSettable: true,
            authorizationPromptMetadata: metadata
        )
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                firstField,
                secondField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let diagnosticSummary = service.authorizationPromptCandidateDiagnosticSummary()

        XCTAssertEqual(status, .multipleApprovedPasswordFields)
        XCTAssertNotNil(diagnosticSummary)
        XCTAssertTrue(diagnosticSummary?.contains("approvedCandidateCount=2") == true)
        XCTAssertTrue(diagnosticSummary?.contains("fieldTextSignal=password") == true)
        XCTAssertTrue(diagnosticSummary?.contains("fieldTextSignal=none") == true)
        XCTAssertFalse(diagnosticSummary?.contains(sensitiveUsername) == true)
        XCTAssertFalse(diagnosticSummary?.contains(sensitivePassword) == true)
        XCTAssertFalse(diagnosticSummary?.contains("local-auth-native-id-one") == true)
        XCTAssertFalse(diagnosticSummary?.contains("local-auth-native-id-two") == true)
        XCTAssertNil(client.lastSetValue)
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testPrivacySecurityPromptWithNameAndPasswordFieldsFillsOnlyPasswordField() {
        let password = testPassword()
        let passwordField = AccessibilityElementSnapshot
            .localAuthenticationPrivacySecurityAuthorizationPasswordField(id: "local-auth-password")
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .localAuthenticationPrivacySecurityAuthorizationNameField,
                passwordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(status, .available)
        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .setValue(
                elementID: passwordField.id,
                valueLength: password.count
            )
        ])
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testDuplicateCoalescingDoesNotApproveRejectedBrowserOrGenericLocalAuthenticationFields() {
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .browserSecurePasswordField,
                .browserSecurePasswordField,
                .localAuthenticationGenericPasswordField,
                .localAuthenticationGenericPasswordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let status = service.focusedAuthorizationPromptStatus()
        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(status, .noFocusedPasswordField)
        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates,
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
        XCTAssertNil(client.lastSetValue)
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testDiscoverableNonApprovedBundleWithAuthorizationPromptTextPreventsFill() {
        let client = SpyAccessibilityElementClient(
            focusedElement: nil,
            authorizationPasswordFieldCandidates: [
                .nonApprovedBundleWithAuthorizationPromptTextPasswordField
            ]
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testFocusedNonPasswordFieldPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .plainTextField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testOrdinarySecurePasswordFieldPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .ordinarySecurePasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testBrowserSecurePasswordFieldPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .browserSecurePasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testAppleProcessNameWithoutAppleBundleIdentifierPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .spoofedSystemSettingsPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testSystemSettingsSecureFieldWithoutAuthorizationTitlePreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .systemSettingsNonAuthorizationSecureField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testSystemSettingsPrivacySecurityAuthorizationPromptTextAllowsValueOnlyFill() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(focusedElement: .systemSettingsPrivacySecurityAuthorizationPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents.count, 2)
        XCTAssertEqual(client.recordedEvents.first, .requestedFocusedElement)
        XCTAssertEqual(client.recordedEvents.last?.kind, .setValue)
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testLocalAuthenticationUIAgentPrivacySecurityAuthorizationPromptTextAllowsValueOnlyFill() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(focusedElement: .localAuthenticationPrivacySecurityAuthorizationPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents.count, 2)
        XCTAssertEqual(client.recordedEvents.first, .requestedFocusedElement)
        XCTAssertEqual(client.recordedEvents.last?.kind, .setValue)
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testLocalAuthenticationUIAgentGenericPromptTextPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .localAuthenticationGenericPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testSystemSettingsPrivacySecuritySecureFieldWithoutPromptTextPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .systemSettingsPrivacySecurityNonAuthorizationPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testNonApprovedBundleWithAuthorizationPromptTextPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .nonApprovedBundleWithAuthorizationPromptTextPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .noFocusedPasswordField)
        XCTAssertEqual(client.recordedEvents, [
            .requestedFocusedElement,
            .requestedAuthorizationPasswordFieldCandidates
        ])
    }

    func testSystemSettingsAuthorizationPromptFillSetsValueOnly() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(focusedElement: .systemSettingsAuthorizationPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents.count, 2)
        XCTAssertEqual(client.recordedEvents.first, .requestedFocusedElement)
        XCTAssertEqual(client.recordedEvents.last?.kind, .setValue)
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testFocusedInvalidPasswordFieldPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .disabledSecurePasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .focusedPasswordFieldUnavailable)
        XCTAssertEqual(client.recordedEvents, [.requestedFocusedElement])
    }

    func testFocusedUnsettablePasswordFieldPreventsFill() {
        let client = SpyAccessibilityElementClient(focusedElement: .unsettableSecurePasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: testPassword())

        XCTAssertEqual(result, .focusedPasswordFieldUnavailable)
        XCTAssertEqual(client.recordedEvents, [.requestedFocusedElement])
    }

    func testAuthorizationSecureFocusedFieldFillSetsValueOnly() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(focusedElement: .securityAgentAuthorizationPasswordField)
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(client.recordedEvents.count, 2)
        XCTAssertEqual(client.recordedEvents.first, .requestedFocusedElement)
        XCTAssertEqual(client.recordedEvents.last?.kind, .setValue)
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    func testSetValueFailureReturnsUnavailableWithoutConfirmationAction() {
        let password = testPassword()
        let client = SpyAccessibilityElementClient(
            focusedElement: .securityAgentAuthorizationPasswordField,
            setValueSucceeds: false
        )
        let service = AccessibilityAutofillService(
            permissionChecker: StubAccessibilityPermissionChecker(isTrusted: true),
            elementClient: client
        )

        let result = service.fillFocusedPasswordField(with: password)

        XCTAssertEqual(result, .focusedPasswordFieldUnavailable)
        XCTAssertEqual(client.recordedEvents.count, 2)
        XCTAssertEqual(client.recordedEvents.first, .requestedFocusedElement)
        XCTAssertEqual(client.recordedEvents.last?.kind, .setValue)
        XCTAssertTrue(client.didSetExpectedPassword(password))
        XCTAssertEqual(client.forbiddenConfirmationActionCount, 0)
    }

    private func testPassword() -> String {
        "phase3-test-secret-\(UUID().uuidString)"
    }
}

private struct StubAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    let isTrusted: Bool

    var isAccessibilityTrusted: Bool {
        isTrusted
    }
}

private final class SpyAccessibilityElementClient: AccessibilityElementClient {
    private let focusedElementSnapshot: AccessibilityElementSnapshot?
    private let authorizationPasswordFieldCandidateSnapshots: [AccessibilityElementSnapshot]
    private let setValueSucceeds: Bool
    private(set) var recordedEvents: [AccessibilityClientEvent] = []
    private(set) var lastSetValue: String?
    private(set) var forbiddenConfirmationActionCount = 0

    init(
        focusedElement: AccessibilityElementSnapshot?,
        authorizationPasswordFieldCandidates: [AccessibilityElementSnapshot] = [],
        setValueSucceeds: Bool = true
    ) {
        self.focusedElementSnapshot = focusedElement
        self.authorizationPasswordFieldCandidateSnapshots = authorizationPasswordFieldCandidates
        self.setValueSucceeds = setValueSucceeds
    }

    func focusedElement() -> AccessibilityElementSnapshot? {
        recordedEvents.append(.requestedFocusedElement)
        return focusedElementSnapshot
    }

    func authorizationPasswordFieldCandidates() -> [AccessibilityElementSnapshot] {
        recordedEvents.append(.requestedAuthorizationPasswordFieldCandidates)
        return authorizationPasswordFieldCandidateSnapshots
    }

    func setValue(_ value: String, for element: AccessibilityElementSnapshot) -> Bool {
        recordedEvents.append(.setValue(elementID: element.id, valueLength: value.count))
        lastSetValue = value
        return setValueSucceeds
    }

    func didSetExpectedPassword(_ expectedPassword: String) -> Bool {
        lastSetValue == expectedPassword
    }
}

private enum AccessibilityClientEvent: Equatable {
    case requestedFocusedElement
    case requestedAuthorizationPasswordFieldCandidates
    case setValue(elementID: AccessibilityElementID, valueLength: Int)

    var kind: AccessibilityClientEventKind {
        switch self {
        case .requestedFocusedElement:
            .requestedFocusedElement
        case .requestedAuthorizationPasswordFieldCandidates:
            .requestedAuthorizationPasswordFieldCandidates
        case .setValue:
            .setValue
        }
    }
}

private enum AccessibilityClientEventKind {
    case requestedFocusedElement
    case requestedAuthorizationPasswordFieldCandidates
    case setValue
}

private extension AccessibilityElementSnapshot {
    static let ordinarySecurePasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "ordinary-secure-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true
    )

    static let plainTextField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "plain-text"),
        role: AccessibilityRole.textField,
        subrole: nil,
        isEnabled: true,
        isSettable: true
    )

    static let disabledSecurePasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "disabled-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: false,
        isSettable: true,
        authorizationPromptMetadata: .securityAgent
    )

    static let unsettableSecurePasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "unsettable-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: false,
        authorizationPromptMetadata: .securityAgent
    )

    static let securityAgentAuthorizationPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "security-agent-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .securityAgent
    )

    static let browserSecurePasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "browser-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .browser
    )

    static let spoofedSystemSettingsPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "spoofed-system-settings-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .spoofedSystemSettings
    )

    static let systemSettingsAuthorizationPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "system-settings-authorization-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .systemSettingsAuthorization
    )

    static let systemSettingsPrivacySecurityAuthorizationPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "system-settings-privacy-security-authorization-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .systemSettingsPrivacySecurityAuthorization
    )

    static let localAuthenticationPrivacySecurityAuthorizationPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "local-authentication-privacy-security-authorization-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .localAuthenticationPrivacySecurityAuthorization
    )

    static let localAuthenticationPrivacySecurityAuthorizationNameField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "local-authentication-privacy-security-authorization-name"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .localAuthenticationPrivacySecurityAuthorization,
        fieldTextFragments: [
            "Name:"
        ]
    )

    static let localAuthenticationGenericPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "local-authentication-generic-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .localAuthenticationGeneric
    )

    static let systemSettingsPrivacySecurityNonAuthorizationPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "system-settings-privacy-security-non-authorization-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .systemSettingsPrivacySecurityNonAuthorization
    )

    static let nonApprovedBundleWithAuthorizationPromptTextPasswordField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "non-approved-authorization-prompt-text-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .nonApprovedBundleWithAuthorizationPromptText
    )

    static let systemSettingsNonAuthorizationSecureField = AccessibilityElementSnapshot(
        id: AccessibilityElementID(rawValue: "system-settings-non-authorization-password"),
        role: AccessibilityRole.textField,
        subrole: AccessibilitySubrole.secureTextField,
        isEnabled: true,
        isSettable: true,
        authorizationPromptMetadata: .systemSettingsNonAuthorization
    )

    static func localAuthenticationPrivacySecurityAuthorizationPasswordField(
        id: String,
        fieldTextFragments: [String] = [
            "Password:"
        ]
    ) -> AccessibilityElementSnapshot {
        AccessibilityElementSnapshot(
            id: AccessibilityElementID(rawValue: id),
            role: AccessibilityRole.textField,
            subrole: AccessibilitySubrole.secureTextField,
            isEnabled: true,
            isSettable: true,
            authorizationPromptMetadata: .localAuthenticationPrivacySecurityAuthorization,
            fieldTextFragments: fieldTextFragments
        )
    }

    static func systemSettingsPrivacySecurityAuthorizationPasswordField(
        id: String,
        fieldTextFragments: [String] = [
            "Password:"
        ]
    ) -> AccessibilityElementSnapshot {
        AccessibilityElementSnapshot(
            id: AccessibilityElementID(rawValue: id),
            role: AccessibilityRole.textField,
            subrole: AccessibilitySubrole.secureTextField,
            isEnabled: true,
            isSettable: true,
            authorizationPromptMetadata: .systemSettingsPrivacySecurityAuthorization,
            fieldTextFragments: fieldTextFragments
        )
    }

    static func insufficientMetadataSystemSettingsPasswordField(id: String) -> AccessibilityElementSnapshot {
        AccessibilityElementSnapshot(
            id: AccessibilityElementID(rawValue: id),
            role: AccessibilityRole.textField,
            subrole: AccessibilitySubrole.secureTextField,
            isEnabled: true,
            isSettable: true,
            fieldTextFragments: [
                "Password:"
            ]
        )
    }
}

private extension AuthorizationPromptMetadata {
    static let securityAgent = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.SecurityAgent",
        processName: "SecurityAgent",
        windowTitle: "System Settings wants to make changes."
    )

    static let browser = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.Safari",
        processName: "Safari",
        windowTitle: "Sign in"
    )

    static let spoofedSystemSettings = AuthorizationPromptMetadata(
        bundleIdentifier: "com.example.SystemSettingsLookalike",
        processName: "System Settings",
        windowTitle: "System Settings wants to make changes."
    )

    static let systemSettingsAuthorization = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.SystemSettings",
        processName: "System Settings",
        windowTitle: "System Settings wants to make changes."
    )

    static let systemSettingsPrivacySecurityAuthorization = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.SystemSettings",
        processName: "System Settings",
        windowTitle: "Privacy & Security",
        promptTextFragments: [
            "Privacy & Security is trying to modify your system settings.",
            "Enter your password to allow this."
        ]
    )

    static let localAuthenticationPrivacySecurityAuthorization = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
        processName: "coreautha",
        windowTitle: "Privacy & Security",
        promptTextFragments: [
            "System Settings is trying to unlock Privacy & Security settings.",
            "Enter an administrator password to allow this."
        ]
    )

    static let localAuthenticationGeneric = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
        processName: "coreautha",
        windowTitle: "FacePass Test App",
        promptTextFragments: [
            "FacePass Test App wants to authenticate.",
            "Enter your password to continue."
        ]
    )

    static let systemSettingsPrivacySecurityNonAuthorization = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.SystemSettings",
        processName: "System Settings",
        windowTitle: "Privacy & Security",
        promptTextFragments: [
            "Privacy & Security"
        ]
    )

    static let nonApprovedBundleWithAuthorizationPromptText = AuthorizationPromptMetadata(
        bundleIdentifier: "com.example.SystemSettingsLookalike",
        processName: "System Settings",
        windowTitle: "Privacy & Security",
        promptTextFragments: [
            "Privacy & Security is trying to modify your system settings.",
            "Enter your password to allow this."
        ]
    )

    static let systemSettingsNonAuthorization = AuthorizationPromptMetadata(
        bundleIdentifier: "com.apple.SystemSettings",
        processName: "System Settings",
        windowTitle: "Apple Account"
    )
}
