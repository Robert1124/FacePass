import ApplicationServices
import AppKit
import Foundation

public struct AccessibilityAutofillService {
    private let permissionChecker: AccessibilityPermissionChecking
    private let elementClient: AccessibilityElementClient

    public init() {
        self.init(
            permissionChecker: SystemAccessibilityPermissionChecker(),
            elementClient: SystemAccessibilityElementClient()
        )
    }

    public var isAccessibilityTrusted: Bool {
        permissionChecker.isAccessibilityTrusted
    }

    init(
        permissionChecker: AccessibilityPermissionChecking,
        elementClient: AccessibilityElementClient
    ) {
        self.permissionChecker = permissionChecker
        self.elementClient = elementClient
    }

    public func fillFocusedPasswordField(with password: String) -> AccessibilityAutofillResult {
        fillFocusedAuthorizationPasswordField(with: password)
    }

    public func focusedAuthorizationPromptStatus() -> AuthorizationPromptPasswordFieldStatus {
        guard permissionChecker.isAccessibilityTrusted else {
            return .accessibilityPermissionDenied
        }

        switch authorizationPasswordFieldResolution() {
        case .available:
            return .available
        case .notFound:
            return .noFocusedPasswordField
        case .unavailable(.multipleApprovedPasswordFields):
            return .multipleApprovedPasswordFields
        case .unavailable(.passwordFieldUnavailable):
            return .focusedPasswordFieldUnavailable
        }
    }

    public func authorizationPromptCandidateDiagnosticSummary() -> String? {
        guard permissionChecker.isAccessibilityTrusted else {
            return nil
        }

        let approvedCandidates = elementClient.authorizationPasswordFieldCandidates()
            .filter(\.isMacAdministratorAuthorizationPasswordField)
        let distinctApprovedCandidates = coalescedApprovedPasswordFieldCandidates(from: approvedCandidates)
        guard distinctApprovedCandidates.count > 1 else {
            return nil
        }

        return AuthorizationPromptCandidateDiagnostics(
            candidates: distinctApprovedCandidates
        ).summary
    }

    public func fillFocusedAuthorizationPasswordField(with password: String) -> AccessibilityAutofillResult {
        guard permissionChecker.isAccessibilityTrusted else {
            return .accessibilityPermissionDenied
        }

        switch authorizationPasswordFieldResolution() {
        case .available(let passwordField):
            return elementClient.setValue(password, for: passwordField) ? .filled : .focusedPasswordFieldUnavailable
        case .notFound:
            return .noFocusedPasswordField
        case .unavailable(.multipleApprovedPasswordFields):
            return .multipleApprovedPasswordFields
        case .unavailable(.passwordFieldUnavailable):
            return .focusedPasswordFieldUnavailable
        }
    }

    private func authorizationPasswordFieldResolution() -> AuthorizationPasswordFieldResolution {
        let focusedElement = elementClient.focusedElement()
        if let focusedElement {
            if focusedElement.isMacAdministratorAuthorizationPasswordField {
                return focusedElement.isEnabled && focusedElement.isSettable
                    ? .available(focusedElement)
                    : .unavailable(.passwordFieldUnavailable)
            }
        }

        let approvedCandidates = elementClient.authorizationPasswordFieldCandidates()
            .filter(\.isMacAdministratorAuthorizationPasswordField)

        guard !approvedCandidates.isEmpty else {
            return .notFound
        }

        let distinctApprovedCandidates = coalescedApprovedPasswordFieldCandidates(from: approvedCandidates)
        if let focusedElement,
           let focusedApprovedCandidate = focusedSystemSettingsCandidate(
               matching: focusedElement,
               in: approvedCandidates
           ) {
            return focusedApprovedCandidate.isEnabled && focusedApprovedCandidate.isSettable
                && focusedElement.isEnabled && focusedElement.isSettable
                ? .available(focusedElement)
                : .unavailable(.passwordFieldUnavailable)
        }

        guard distinctApprovedCandidates.count == 1 else {
            return .unavailable(.multipleApprovedPasswordFields)
        }

        let candidateGroup = distinctApprovedCandidates[0]
        return candidateGroup.isAvailable
            ? .available(candidateGroup.representative)
            : .unavailable(.passwordFieldUnavailable)
    }

    private func focusedSystemSettingsCandidate(
        matching focusedElement: AccessibilityElementSnapshot,
        in approvedCandidates: [AccessibilityElementSnapshot]
    ) -> AccessibilityElementSnapshot? {
        guard focusedElement.isSecurePasswordTextField,
              focusedElement.fieldTextDiagnosticSignal == .password,
              focusedElement.authorizationPromptMetadata?.isAllowedMacAdministratorAuthorizationPrompt != true else {
            return nil
        }

        return approvedCandidates.first { candidate in
            candidate.id == focusedElement.id &&
                candidate.isSystemSettingsAuthorizationPasswordField
        }
    }

    private func coalescedApprovedPasswordFieldCandidates(
        from candidates: [AccessibilityElementSnapshot]
    ) -> [CoalescedAuthorizationPasswordFieldCandidate] {
        var groups: [AccessibilityElementID: [AccessibilityElementSnapshot]] = [:]
        var orderedKeys: [AccessibilityElementID] = []

        for candidate in candidates {
            let key = candidate.id
            if groups[key] == nil {
                orderedKeys.append(key)
            }
            groups[key, default: []].append(candidate)
        }

        return orderedKeys.compactMap { key in
            guard let candidates = groups[key],
                  let representative = candidates.first else {
                return nil
            }

            return CoalescedAuthorizationPasswordFieldCandidate(
                representative: representative,
                isAvailable: candidates.allSatisfy { $0.isEnabled && $0.isSettable }
            )
        }
    }
}

private enum AuthorizationPasswordFieldResolution: Equatable {
    case available(AccessibilityElementSnapshot)
    case notFound
    case unavailable(AuthorizationPasswordFieldUnavailableReason)
}

private enum AuthorizationPasswordFieldUnavailableReason: Equatable {
    case passwordFieldUnavailable
    case multipleApprovedPasswordFields
}

private struct CoalescedAuthorizationPasswordFieldCandidate {
    let representative: AccessibilityElementSnapshot
    let isAvailable: Bool
}

private struct AuthorizationPromptCandidateDiagnostics {
    let candidates: [CoalescedAuthorizationPasswordFieldCandidate]

    var summary: String {
        let candidateSummaries = candidates.enumerated()
            .map { index, candidate in
                let snapshot = candidate.representative
                let metadata = snapshot.authorizationPromptMetadata
                return [
                    "candidate=\(index + 1)",
                    "bundle=\(Self.safe(metadata?.bundleIdentifier))",
                    "process=\(Self.safe(metadata?.processName))",
                    "role=\(snapshot.role.diagnosticName)",
                    "subrole=\(snapshot.subrole.diagnosticName)",
                    "enabled=\(snapshot.isEnabled)",
                    "settable=\(snapshot.isSettable)",
                    "groupAvailable=\(candidate.isAvailable)",
                    "fieldTextSignal=\(snapshot.fieldTextDiagnosticSignal.rawValue)",
                    "idHash=\(Self.stableHashPrefix(for: snapshot.id.rawValue))"
                ].joined(separator: ",")
            }
            .joined(separator: "; ")

        // For duplicate-candidate debugging, compare idHash values first: the
        // same visible prompt with multiple idHash values means AX exposed
        // distinct native secure fields, which FacePass intentionally does not
        // merge by role, title, frame, or other heuristic fingerprints.
        return "approvedCandidateCount=\(candidates.count); \(candidateSummaries)"
    }

    private static func safe(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func stableHashPrefix(for value: String) -> String {
        let bytes = value.utf8
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash).prefix(8).description
    }
}

public protocol PasswordAutofillService {
    var isAccessibilityTrusted: Bool { get }
    func focusedAuthorizationPromptStatus() -> AuthorizationPromptPasswordFieldStatus
    func authorizationPromptCandidateDiagnosticSummary() -> String?
    func fillFocusedPasswordField(with password: String) -> AccessibilityAutofillResult
    func fillFocusedAuthorizationPasswordField(with password: String) -> AccessibilityAutofillResult
}

extension AccessibilityAutofillService: PasswordAutofillService {}

public extension PasswordAutofillService {
    func focusedAuthorizationPromptStatus() -> AuthorizationPromptPasswordFieldStatus {
        isAccessibilityTrusted ? .available : .accessibilityPermissionDenied
    }

    func authorizationPromptCandidateDiagnosticSummary() -> String? {
        nil
    }

    func fillFocusedAuthorizationPasswordField(with password: String) -> AccessibilityAutofillResult {
        fillFocusedPasswordField(with: password)
    }
}

public enum AuthorizationPromptPasswordFieldStatus: Equatable {
    case available
    case accessibilityPermissionDenied
    case noFocusedPasswordField
    case focusedPasswordFieldUnavailable
    case multipleApprovedPasswordFields
}

public enum AccessibilityAutofillResult: Equatable {
    case filled
    case accessibilityPermissionDenied
    case noFocusedPasswordField
    case focusedPasswordFieldUnavailable
    case multipleApprovedPasswordFields
}

protocol AccessibilityPermissionChecking {
    var isAccessibilityTrusted: Bool { get }
}

struct SystemAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }
}

protocol AccessibilityElementClient {
    func focusedElement() -> AccessibilityElementSnapshot?
    func authorizationPasswordFieldCandidates() -> [AccessibilityElementSnapshot]
    func setValue(_ value: String, for element: AccessibilityElementSnapshot) -> Bool
}

public struct AccessibilityElementSnapshot: Equatable {
    public let id: AccessibilityElementID
    public let role: AccessibilityRole?
    public let subrole: AccessibilitySubrole?
    public let isEnabled: Bool
    public let isSettable: Bool
    public let authorizationPromptMetadata: AuthorizationPromptMetadata?
    public let fieldTextFragments: [String]
    let nativeElement: AXUIElement?

    public init(
        id: AccessibilityElementID,
        role: AccessibilityRole?,
        subrole: AccessibilitySubrole?,
        isEnabled: Bool,
        isSettable: Bool,
        authorizationPromptMetadata: AuthorizationPromptMetadata? = nil,
        fieldTextFragments: [String] = []
    ) {
        self.init(
            id: id,
            role: role,
            subrole: subrole,
            isEnabled: isEnabled,
            isSettable: isSettable,
            authorizationPromptMetadata: authorizationPromptMetadata,
            fieldTextFragments: fieldTextFragments,
            nativeElement: nil
        )
    }

    init(
        id: AccessibilityElementID,
        role: AccessibilityRole?,
        subrole: AccessibilitySubrole?,
        isEnabled: Bool,
        isSettable: Bool,
        authorizationPromptMetadata: AuthorizationPromptMetadata?,
        fieldTextFragments: [String] = [],
        nativeElement: AXUIElement?
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.isEnabled = isEnabled
        self.isSettable = isSettable
        self.authorizationPromptMetadata = authorizationPromptMetadata
        self.fieldTextFragments = fieldTextFragments
        self.nativeElement = nativeElement
    }

    var isSecurePasswordTextField: Bool {
        role == .textField &&
            subrole == .secureTextField &&
            !hasExplicitNonPasswordFieldTextSignal
    }

    var isMacAdministratorAuthorizationPasswordField: Bool {
        isSecurePasswordTextField &&
            authorizationPromptMetadata?.isAllowedMacAdministratorAuthorizationPrompt == true
    }

    var isSystemSettingsAuthorizationPasswordField: Bool {
        isSecurePasswordTextField &&
            authorizationPromptMetadata?.isAllowedSystemSettingsAuthorizationPrompt == true
    }

    fileprivate var fieldTextDiagnosticSignal: FieldTextDiagnosticSignal {
        guard !fieldTextFragments.isEmpty else {
            return .none
        }

        return hasPasswordFieldTextSignal ? .password : .nonPassword
    }

    private var hasExplicitNonPasswordFieldTextSignal: Bool {
        !fieldTextFragments.isEmpty && !hasPasswordFieldTextSignal
    }

    private var hasPasswordFieldTextSignal: Bool {
        fieldTextFragments.contains { fragment in
            fragment
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .contains("password")
        }
    }

    public static func == (lhs: AccessibilityElementSnapshot, rhs: AccessibilityElementSnapshot) -> Bool {
        lhs.id == rhs.id &&
            lhs.role == rhs.role &&
            lhs.subrole == rhs.subrole &&
            lhs.isEnabled == rhs.isEnabled &&
            lhs.isSettable == rhs.isSettable &&
            lhs.authorizationPromptMetadata == rhs.authorizationPromptMetadata &&
            lhs.fieldTextFragments == rhs.fieldTextFragments
    }
}

private enum FieldTextDiagnosticSignal: String {
    case none
    case password
    case nonPassword
}

public struct AuthorizationPromptMetadata: Equatable {
    public let bundleIdentifier: String?
    public let processName: String?
    public let windowTitle: String?
    public let promptTextFragments: [String]

    public init(
        bundleIdentifier: String?,
        processName: String?,
        windowTitle: String?,
        promptTextFragments: [String] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.windowTitle = windowTitle
        self.promptTextFragments = promptTextFragments
    }

    var isAllowedMacAdministratorAuthorizationPrompt: Bool {
        guard let bundleIdentifier else {
            return false
        }

        let normalizedBundleIdentifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedBundleIdentifier == "com.apple.securityagent" {
            return true
        }

        if normalizedBundleIdentifier == "com.apple.systemsettings" ||
            normalizedBundleIdentifier == "com.apple.systempreferences" {
            return hasAdministratorAuthorizationWindowSignal || hasStrongAuthorizationPromptTextSignal
        }

        // Modern System Settings authorization sheets can be hosted by LocalAuthentication.
        if normalizedBundleIdentifier == "com.apple.localauthentication.uiagent" {
            return hasSystemSettingsContextSignal && hasStrongAuthorizationPromptTextSignal
        }

        return false
    }

    var isAllowedSystemSettingsAuthorizationPrompt: Bool {
        guard let bundleIdentifier else {
            return false
        }

        let normalizedBundleIdentifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return (
            normalizedBundleIdentifier == "com.apple.systemsettings" ||
                normalizedBundleIdentifier == "com.apple.systempreferences"
        ) && (hasAdministratorAuthorizationWindowSignal || hasStrongAuthorizationPromptTextSignal)
    }

    private var hasAdministratorAuthorizationWindowSignal: Bool {
        let normalizedWindowTitle = windowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        guard !normalizedWindowTitle.isEmpty else {
            return false
        }

        let administratorPromptFragments = [
            "wants to make changes",
            "administrator",
            "authorization",
            "authentication",
            "unlock"
        ]
        return administratorPromptFragments.contains { normalizedWindowTitle.contains($0) }
    }

    private var hasStrongAuthorizationPromptTextSignal: Bool {
        let normalizedPromptText = normalizedContextText
        guard !normalizedPromptText.isEmpty else {
            return false
        }

        let strongPromptFragments = [
            "trying to modify your system settings",
            "enter your password to allow this",
            "modify your system settings",
            "modify settings",
            "wants to make changes",
            "make changes"
        ]

        if strongPromptFragments.contains(where: { normalizedPromptText.contains($0) }) {
            return true
        }

        let passwordFragments = [
            "enter your password",
            "enter an administrator password",
            "enter an administrator's password",
            "administrator name and password",
            "administrator's name and password",
            "administrator password",
            "name and password"
        ]
        let authorizationActionFragments = [
            "allow this",
            "make changes",
            "modify",
            "unlock"
        ]

        return passwordFragments.contains { normalizedPromptText.contains($0) } &&
            authorizationActionFragments.contains { normalizedPromptText.contains($0) }
    }

    private var hasSystemSettingsContextSignal: Bool {
        let normalizedPromptText = normalizedContextText
        let contextFragments = [
            "system settings",
            "system preferences",
            "privacy & security",
            "privacy and security"
        ]
        return contextFragments.contains { normalizedPromptText.contains($0) }
    }

    private var normalizedContextText: String {
        ([windowTitle] + promptTextFragments)
            .compactMap { $0 }
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct AccessibilityElementID: Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum AccessibilityRole: Equatable, Hashable {
    case textField
    case other(String)

    init(rawValue: String) {
        if rawValue == kAXTextFieldRole as String {
            self = .textField
        } else {
            self = .other(rawValue)
        }
    }
}

private extension Optional where Wrapped == AccessibilityRole {
    var diagnosticName: String {
        switch self {
        case .textField:
            "textField"
        case .other:
            "other"
        case nil:
            "unknown"
        }
    }
}

public enum AccessibilitySubrole: Equatable, Hashable {
    case secureTextField
    case other(String)

    init(rawValue: String) {
        if rawValue == kAXSecureTextFieldSubrole as String {
            self = .secureTextField
        } else {
            self = .other(rawValue)
        }
    }
}

private extension Optional where Wrapped == AccessibilitySubrole {
    var diagnosticName: String {
        switch self {
        case .secureTextField:
            "secureTextField"
        case .other:
            "other"
        case nil:
            "unknown"
        }
    }
}

struct SystemAccessibilityElementClient: AccessibilityElementClient {
    private static let promptTextTraversalMaxDepth = 5
    private static let promptTextTraversalMaxElements = 80
    private static let promptTextFragmentsMaxCount = 24
    private static let promptTextFragmentMaxLength = 512
    private static let ancestorTraversalMaxDepth = 8
    private static let secureFieldTraversalMaxDepth = 8
    private static let secureFieldTraversalMaxElements = 160
    private static let promptHostBundleIdentifiers: Set<String> = [
        "com.apple.securityagent",
        "com.apple.localauthentication.uiagent"
    ]
    fileprivate static let systemSettingsBundleIdentifiers: Set<String> = [
        "com.apple.systemsettings",
        "com.apple.systempreferences"
    ]

    func focusedElement() -> AccessibilityElementSnapshot? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success else {
            return nil
        }

        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedElement = focusedValue as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute, from: focusedElement)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focusedElement)
        let accessibilityRole = role.map(AccessibilityRole.init(rawValue:))
        let accessibilitySubrole = subrole.map(AccessibilitySubrole.init(rawValue:))
        let isSecurePasswordField = role == kAXTextFieldRole as String &&
            subrole == kAXSecureTextFieldSubrole as String
        let metadata = isSecurePasswordField
            ? focusedAuthorizationPromptMetadata(for: focusedElement)
            : nil
        let fieldTextFragments = isSecurePasswordField
            ? fieldTextFragments(for: focusedElement)
            : []

        return AccessibilityElementSnapshot(
            id: AccessibilityElementID(rawValue: String(describing: focusedElement)),
            role: accessibilityRole,
            subrole: accessibilitySubrole,
            isEnabled: isSecurePasswordField
                ? boolAttribute(kAXEnabledAttribute, from: focusedElement) ?? true
                : true,
            isSettable: isSecurePasswordField
                ? isValueSettable(for: focusedElement)
                : false,
            authorizationPromptMetadata: metadata,
            fieldTextFragments: fieldTextFragments,
            nativeElement: focusedElement
        )
    }

    func authorizationPasswordFieldCandidates() -> [AccessibilityElementSnapshot] {
        var candidates: [AccessibilityElementSnapshot] = []
        var seenCandidateIDs = Set<AccessibilityElementID>()

        func appendCandidates(from applications: [AccessibilityApplicationCandidate]) {
            for application in applications {
                for window in candidateWindows(for: application) {
                    let metadata = authorizationPromptMetadata(
                        for: window,
                        application: application.runningApplication
                    )
                    guard metadata.isAllowedMacAdministratorAuthorizationPrompt else {
                        continue
                    }

                    for passwordField in securePasswordFields(in: window, metadata: metadata) {
                        guard !seenCandidateIDs.contains(passwordField.id) else {
                            continue
                        }

                        candidates.append(passwordField)
                        seenCandidateIDs.insert(passwordField.id)
                    }
                }
            }
        }

        let applications = authorizationHostApplications()
        appendCandidates(from: applications.filter { !$0.isSystemSettingsHost })
        if candidates.isEmpty {
            appendCandidates(from: applications.filter(\.isSystemSettingsHost))
        }

        return candidates
    }

    func setValue(_ value: String, for element: AccessibilityElementSnapshot) -> Bool {
        guard let nativeElement = element.nativeElement else {
            return false
        }

        return AXUIElementSetAttributeValue(
            nativeElement,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func isValueSettable(for element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        ) == .success else {
            return false
        }
        return isSettable.boolValue
    }

    private func authorizationHostApplications() -> [AccessibilityApplicationCandidate] {
        var applications: [AccessibilityApplicationCandidate] = []
        var seenPIDs = Set<pid_t>()

        func append(_ application: NSRunningApplication?, matching allowedBundleIdentifiers: Set<String>) {
            guard let application,
                  let normalizedBundleIdentifier = normalizedBundleIdentifier(for: application),
                  allowedBundleIdentifiers.contains(normalizedBundleIdentifier),
                  !seenPIDs.contains(application.processIdentifier) else {
                return
            }

            applications.append(AccessibilityApplicationCandidate(
                runningApplication: application,
                element: AXUIElementCreateApplication(application.processIdentifier),
                normalizedBundleIdentifier: normalizedBundleIdentifier
            ))
            seenPIDs.insert(application.processIdentifier)
        }

        let focusedApplication = systemFocusedApplication()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication

        append(focusedApplication, matching: Self.promptHostBundleIdentifiers)
        append(frontmostApplication, matching: Self.promptHostBundleIdentifiers)

        for application in NSWorkspace.shared.runningApplications {
            append(application, matching: Self.promptHostBundleIdentifiers)
        }

        append(focusedApplication, matching: Self.systemSettingsBundleIdentifiers)
        append(frontmostApplication, matching: Self.systemSettingsBundleIdentifiers)

        return applications
    }

    private func normalizedBundleIdentifier(for application: NSRunningApplication) -> String? {
        application.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func systemFocusedApplication() -> NSRunningApplication? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedApplicationValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplicationValue
        ) == .success,
              let focusedApplicationValue,
              CFGetTypeID(focusedApplicationValue) == AXUIElementGetTypeID() else {
            return nil
        }

        var processID = pid_t()
        guard AXUIElementGetPid((focusedApplicationValue as! AXUIElement), &processID) == .success else {
            return nil
        }

        return NSRunningApplication(processIdentifier: processID)
    }

    private func authorizationPromptMetadata(for element: AXUIElement) -> AuthorizationPromptMetadata {
        var processID = pid_t()
        let application = AXUIElementGetPid(element, &processID) == .success
            ? NSRunningApplication(processIdentifier: processID)
            : nil
        let window = windowElement(for: element)

        return AuthorizationPromptMetadata(
            bundleIdentifier: application?.bundleIdentifier,
            processName: application?.localizedName,
            windowTitle: window.flatMap { stringAttribute(kAXTitleAttribute, from: $0) },
            promptTextFragments: promptTextFragments(for: element, window: window)
        )
    }

    private func focusedAuthorizationPromptMetadata(for element: AXUIElement) -> AuthorizationPromptMetadata {
        let directMetadata = authorizationPromptMetadata(for: element)
        guard !directMetadata.isAllowedMacAdministratorAuthorizationPrompt else {
            return directMetadata
        }

        return approvedFocusedApplicationWindowMetadata(for: element) ?? directMetadata
    }

    private func approvedFocusedApplicationWindowMetadata(for element: AXUIElement) -> AuthorizationPromptMetadata? {
        var applications: [AccessibilityApplicationCandidate] = []
        var seenPIDs = Set<pid_t>()

        func append(_ application: NSRunningApplication?) {
            guard let application,
                  let normalizedBundleIdentifier = normalizedBundleIdentifier(for: application),
                  Self.promptHostBundleIdentifiers.contains(normalizedBundleIdentifier) ||
                  Self.systemSettingsBundleIdentifiers.contains(normalizedBundleIdentifier),
                  !seenPIDs.contains(application.processIdentifier) else {
                return
            }

            applications.append(AccessibilityApplicationCandidate(
                runningApplication: application,
                element: AXUIElementCreateApplication(application.processIdentifier),
                normalizedBundleIdentifier: normalizedBundleIdentifier
            ))
            seenPIDs.insert(application.processIdentifier)
        }

        append(runningApplication(for: element))
        append(systemFocusedApplication())
        append(NSWorkspace.shared.frontmostApplication)

        for application in applications {
            for window in candidateWindows(for: application) {
                let metadata = authorizationPromptMetadata(
                    for: window,
                    application: application.runningApplication
                )
                if metadata.isAllowedMacAdministratorAuthorizationPrompt {
                    return metadata
                }
            }
        }

        return nil
    }

    private func authorizationPromptMetadata(
        for window: AXUIElement,
        application: NSRunningApplication?
    ) -> AuthorizationPromptMetadata {
        AuthorizationPromptMetadata(
            bundleIdentifier: application?.bundleIdentifier,
            processName: application?.localizedName,
            windowTitle: stringAttribute(kAXTitleAttribute, from: window),
            promptTextFragments: windowContextFragments(from: window)
        )
    }

    private func runningApplication(for element: AXUIElement) -> NSRunningApplication? {
        var processID = pid_t()
        guard AXUIElementGetPid(element, &processID) == .success else {
            return nil
        }

        return NSRunningApplication(processIdentifier: processID)
    }

    private func windowElement(for element: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (windowValue as! AXUIElement)
    }

    private func candidateWindows(for application: AccessibilityApplicationCandidate) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        var seenWindowIDs = Set<String>()

        func appendWindow(_ window: AXUIElement?) {
            guard let window else {
                return
            }

            let id = String(describing: window)
            guard !seenWindowIDs.contains(id) else {
                return
            }

            windows.append(window)
            seenWindowIDs.insert(id)
        }

        appendWindow(applicationWindowAttribute(kAXFocusedWindowAttribute, from: application.element))
        appendWindow(applicationWindowAttribute(kAXMainWindowAttribute, from: application.element))

        guard !application.isSystemSettingsHost else {
            return windows
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application.element,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
           let windowsValue,
           let applicationWindows = windowsValue as? [AXUIElement] {
            for window in applicationWindows {
                appendWindow(window)
            }
        }

        return windows
    }

    private func applicationWindowAttribute(_ attribute: String, from application: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            attribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (windowValue as! AXUIElement)
    }

    private func securePasswordFields(
        in window: AXUIElement,
        metadata: AuthorizationPromptMetadata
    ) -> [AccessibilityElementSnapshot] {
        var fields: [AccessibilityElementSnapshot] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var inspectedElementCount = 0
        var seenElementIDs = Set<String>()

        while !queue.isEmpty,
              inspectedElementCount < Self.secureFieldTraversalMaxElements {
            let current = queue.removeFirst()
            inspectedElementCount += 1

            let role = stringAttribute(kAXRoleAttribute, from: current.element)
            let subrole = stringAttribute(kAXSubroleAttribute, from: current.element)
            if role == kAXTextFieldRole as String,
               subrole == kAXSecureTextFieldSubrole as String {
                let id = String(describing: current.element)
                if !seenElementIDs.contains(id) {
                    let accessibilityRole = AccessibilityRole(rawValue: role ?? "")
                    let accessibilitySubrole = AccessibilitySubrole(rawValue: subrole ?? "")
                    let field = AccessibilityElementSnapshot(
                        id: AccessibilityElementID(rawValue: id),
                        role: accessibilityRole,
                        subrole: accessibilitySubrole,
                        isEnabled: boolAttribute(kAXEnabledAttribute, from: current.element) ?? true,
                        isSettable: isValueSettable(for: current.element),
                        authorizationPromptMetadata: metadata,
                        fieldTextFragments: fieldTextFragments(for: current.element),
                        nativeElement: current.element
                    )
                    if field.isSecurePasswordTextField {
                        fields.append(field)
                        seenElementIDs.insert(id)
                    }
                }
            }

            guard current.depth < Self.secureFieldTraversalMaxDepth else {
                continue
            }

            for child in childElements(for: current.element) {
                queue.append((child, current.depth + 1))
            }
        }

        return fields
    }

    private func promptTextFragments(for element: AXUIElement, window: AXUIElement?) -> [String] {
        var fragments: [String] = []
        var seenFragments = Set<String>()

        appendContextFragments(
            ancestorContextFragments(for: element),
            to: &fragments,
            seenFragments: &seenFragments
        )

        if let window {
            appendContextFragments(
                windowContextFragments(from: window),
                to: &fragments,
                seenFragments: &seenFragments
            )
        }

        return fragments
    }

    private func ancestorContextFragments(for element: AXUIElement) -> [String] {
        var fragments: [String] = []
        var currentElement: AXUIElement? = element
        var depth = 0

        while let current = currentElement, depth < Self.ancestorTraversalMaxDepth {
            let role = stringAttribute(kAXRoleAttribute, from: current)
            fragments.append(contentsOf: contextStringFragments(from: current, role: role))
            currentElement = parentElement(for: current)
            depth += 1
        }

        return fragments
    }

    private func windowContextFragments(from window: AXUIElement) -> [String] {
        var fragments: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var inspectedElementCount = 0

        while !queue.isEmpty,
              inspectedElementCount < Self.promptTextTraversalMaxElements,
              fragments.count < Self.promptTextFragmentsMaxCount {
            let current = queue.removeFirst()
            inspectedElementCount += 1

            let role = stringAttribute(kAXRoleAttribute, from: current.element)
            fragments.append(contentsOf: contextStringFragments(from: current.element, role: role))

            guard current.depth < Self.promptTextTraversalMaxDepth else {
                continue
            }

            for child in childElements(for: current.element) {
                queue.append((child, current.depth + 1))
            }
        }

        return fragments
    }

    private func contextStringFragments(from element: AXUIElement, role: String?) -> [String] {
        var fragments: [String] = []

        if let title = stringAttribute(kAXTitleAttribute, from: element) {
            fragments.append(title)
        }

        if let description = stringAttribute(kAXDescriptionAttribute, from: element) {
            fragments.append(description)
        }

        if role == kAXStaticTextRole as String,
           let value = stringAttribute(kAXValueAttribute, from: element) {
            fragments.append(value)
        }

        return fragments
    }

    private func fieldTextFragments(for element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXPlaceholderValueAttribute as String,
            kAXHelpAttribute as String
        ]
            .compactMap { stringAttribute($0, from: element) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func appendContextFragments(
        _ candidates: [String],
        to fragments: inout [String],
        seenFragments: inout Set<String>
    ) {
        for candidate in candidates {
            guard fragments.count < Self.promptTextFragmentsMaxCount else {
                return
            }

            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let limitedFragment = String(trimmed.prefix(Self.promptTextFragmentMaxLength))
            let key = limitedFragment.lowercased()
            guard !seenFragments.contains(key) else {
                continue
            }

            fragments.append(limitedFragment)
            seenFragments.insert(key)
        }
    }

    private func parentElement(for element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        ) == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (parentValue as! AXUIElement)
    }

    private func childElements(for element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let childrenValue else {
            return []
        }

        return childrenValue as? [AXUIElement] ?? []
    }
}

private struct AccessibilityApplicationCandidate {
    let runningApplication: NSRunningApplication
    let element: AXUIElement
    let normalizedBundleIdentifier: String

    var isSystemSettingsHost: Bool {
        SystemAccessibilityElementClient.systemSettingsBundleIdentifiers.contains(normalizedBundleIdentifier)
    }
}
