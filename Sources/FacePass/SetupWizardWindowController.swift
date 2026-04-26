import AppKit
import FacePassCore
import SwiftUI

final class SetupWizardWindowController: NSWindowController {
    private static let hasPresentedDefaultsKey = "FacePass.hasPresentedSetupWizard"

    private let appStateManager: AppStateManager

    init(appStateManager: AppStateManager) {
        self.appStateManager = appStateManager

        let window = NSWindow()
        window.title = "FacePass Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 620, height: 430))
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: SetupWizardView(
                onCompleteOrSkip: { [weak self] in
                    self?.markPresented()
                    self?.close()
                }
            )
            .environmentObject(appStateManager)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showOnFirstLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasPresentedDefaultsKey) else {
            return
        }

        showWizard()
    }

    func showWizard() {
        appStateManager.refreshPermissions()
        appStateManager.refreshPasswordConfigurationStatus()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func markPresented() {
        UserDefaults.standard.set(true, forKey: Self.hasPresentedDefaultsKey)
    }
}

private struct SetupWizardView: View {
    @EnvironmentObject private var appStateManager: AppStateManager
    @State private var selectedStep: SetupWizardStep = .accessibility
    @State private var passwordInput = ""
    @State private var statusMessage: String?
    @State private var isRequestingCameraPermission = false

    let onCompleteOrSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                stepList

                Divider()

                stepDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()

            footer
        }
        .frame(width: 620, height: 430)
        .onAppear {
            refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FacePass Setup")
                .font(.title2.weight(.semibold))
            Text("Configure permissions and Keychain password storage for approved macOS administrator/System Settings authorization prompts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SetupWizardStep.allCases) { step in
                Button {
                    selectedStep = step
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: step))
                            .frame(width: 18)
                        Text(step.title)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedStep == step ? Color.accentColor : Color.primary)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    selectedStep == step ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 190, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var stepDetail: some View {
        switch selectedStep {
        case .accessibility:
            permissionStep(
                title: "Accessibility Permission",
                status: accessibilityStatus,
                detail: "Required for checking approved administrator/System Settings authorization password prompts and setting the saved value only.",
                primaryTitle: "Request Prompt",
                primaryAction: {
                    AccessibilityPermissionPrompter.requestPrompt()
                    SystemSettingsOpener.openAccessibilitySettings()
                    refresh()
                },
                secondaryTitle: "Open Settings",
                secondaryAction: SystemSettingsOpener.openAccessibilitySettings
            )
        case .camera:
            permissionStep(
                title: "Camera Permission",
                status: cameraStatus,
                detail: "Used only for short local FacePass recognition, enrollment, approved admin/System Settings prompt fill, and opt-in lock-screen checks. FacePass is not Apple Face ID, system biometrics, or a macOS authentication replacement, does not keep the camera running, and does not save raw frames or photos.",
                primaryTitle: isRequestingCameraPermission ? "Requesting..." : "Request Camera",
                primaryAction: requestCameraPermission,
                secondaryTitle: "Open Settings",
                secondaryAction: SystemSettingsOpener.openCameraSettings
            )
        case .password:
            passwordStep
        }
    }

    private func permissionStep(
        title: String,
        status: PermissionStatus?,
        detail: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            statusPill(status?.statusText ?? "Unknown", isGranted: status?.isGranted == true)

            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(primaryTitle, action: primaryAction)
                    .disabled(isRequestingCameraPermission)
                Button(secondaryTitle, action: secondaryAction)
                Button("Refresh", action: refresh)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keychain Password")
                .font(.title3.weight(.semibold))

            statusPill(
                appStateManager.passwordConfigurationState.isPasswordConfigured ? "Configured" : "Not Configured",
                isGranted: appStateManager.passwordConfigurationState.isPasswordConfigured
            )

            Text("The password is saved through Keychain only. FacePass does not show saved passwords.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button(appStateManager.passwordConfigurationState.isPasswordConfigured ? "Update Password" : "Save Password") {
                    savePassword()
                }
                .disabled(passwordInput.isEmpty)

                Button("Refresh", action: refresh)

                Button("Verify Keychain Access") {
                    preflightKeychainPasswordAccess()
                }
                .disabled(!appStateManager.passwordConfigurationState.isPasswordConfigured)
            }

            Text("Verify Keychain Access can be used while this session is unlocked to approve the macOS Keychain prompt before lock-screen use. FacePass reads the saved value only for this check, discards it immediately, and does not recommend weakening Keychain prompt protections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Unlocked admin/System Settings prompt fill runs local FacePass recognition first, fills the saved value only, and does not click OK/Continue/Login, submit, or press Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastError = appStateManager.passwordConfigurationState.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button("Back") {
                selectedStep = selectedStep.previous
            }
            .disabled(selectedStep == SetupWizardStep.allCases.first)

            Button(primaryFooterActionTitle) {
                if selectedStep == SetupWizardStep.allCases.last {
                    onCompleteOrSkip()
                } else {
                    selectedStep = selectedStep.next
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func statusPill(_ text: String, isGranted: Bool) -> some View {
        Label(text, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(isGranted ? Color.green : Color.orange)
            .font(.headline)
    }

    private func iconName(for step: SetupWizardStep) -> String {
        switch step {
        case .accessibility:
            accessibilityStatus?.isGranted == true ? "checkmark.circle.fill" : "hand.raised.fill"
        case .camera:
            cameraStatus?.isGranted == true ? "checkmark.circle.fill" : "camera.fill"
        case .password:
            appStateManager.passwordConfigurationState.isPasswordConfigured ? "checkmark.circle.fill" : "key.fill"
        }
    }

    private var accessibilityStatus: PermissionStatus? {
        appStateManager.permissionStatuses.first { $0.kind == .accessibility }
    }

    private var cameraStatus: PermissionStatus? {
        appStateManager.permissionStatuses.first { $0.kind == .camera }
    }

    private var summaryText: String {
        let permissionText = appStateManager.areAllPermissionsAcquired ? "Permissions complete." : "Some permissions still need attention."
        let passwordText = appStateManager.passwordConfigurationState.isPasswordConfigured ? "Password configured." : "Password not configured."
        return "\(permissionText) \(passwordText)"
    }

    private var isSetupComplete: Bool {
        appStateManager.areAllPermissionsAcquired && appStateManager.passwordConfigurationState.isPasswordConfigured
    }

    private var primaryFooterActionTitle: String {
        guard selectedStep == SetupWizardStep.allCases.last else {
            return "Next"
        }

        return isSetupComplete ? "Finish" : "Skip Setup"
    }

    private func refresh() {
        appStateManager.refreshPermissions()
        appStateManager.refreshPasswordConfigurationStatus()
    }

    private func requestCameraPermission() {
        isRequestingCameraPermission = true
        statusMessage = nil
        Task {
            let result = await appStateManager.requestCameraPermission()
            await MainActor.run {
                isRequestingCameraPermission = false
                statusMessage = result == .authorized
                    ? "Camera permission is allowed."
                    : "Camera permission is not allowed."
                refresh()
            }
        }
    }

    private func savePassword() {
        do {
            try appStateManager.savePassword(passwordInput)
            passwordInput = ""
            statusMessage = "Password saved in Keychain."
        } catch {
            passwordInput = ""
            statusMessage = "Password could not be saved."
        }
    }

    private func preflightKeychainPasswordAccess() {
        let result = appStateManager.preflightKeychainPasswordAccess()
        statusMessage = result.description
    }
}

private enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case accessibility
    case camera
    case password

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .camera:
            "Camera"
        case .password:
            "Password"
        }
    }

    var next: SetupWizardStep {
        let steps = Self.allCases
        let nextIndex = min(rawValue + 1, steps.count - 1)
        return steps[nextIndex]
    }

    var previous: SetupWizardStep {
        let previousIndex = max(rawValue - 1, 0)
        return Self.allCases[previousIndex]
    }
}
