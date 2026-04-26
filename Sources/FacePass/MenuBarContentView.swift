import AppKit
import FacePassCore
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appStateManager: AppStateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appStateManager.menuStatus.title)
                .font(.headline)
            Text(appStateManager.menuStatus.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(appStateManager.permissionStatuses) { status in
                PermissionStatusRow(status: status)
            }

            Divider()

            Text(appStateManager.passwordConfigurationState.isPasswordConfigured ? "Password Configured" : "Password Not Configured")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Stored in Keychain; not shown in FacePass.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Unlocked-session fill is only for approved macOS administrator/System Settings authorization password prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("FacePass runs local recognition first, then fills the saved value only.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("It does not click OK/Continue/Login, submit, or press Return in unlocked admin/System Settings prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Lock-screen unlock is separate: when the session is locked and the opt-in path is enabled, FacePass may type the password and press Return after local recognition.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("FacePass is not Apple Face ID, system biometrics, or a macOS authentication replacement.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Global hotkey: \(appStateManager.manualFillHotkeyStatus.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(manualFillHotkeyStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Authorization monitor: \(appStateManager.isAuthorizationPromptMonitorActive ? "Active" : "Inactive")")
                .font(.caption)
                .foregroundStyle(appStateManager.isAuthorizationPromptMonitorActive ? Color.green : Color.secondary)
            if let lastAuthorizationPromptMonitorStatus = appStateManager.lastAuthorizationPromptMonitorStatus {
                Text("Last prompt check: \(lastAuthorizationPromptMonitorStatus.description)")
                    .font(.caption)
                    .foregroundStyle(authorizationPromptMonitorStatusColor(for: lastAuthorizationPromptMonitorStatus))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastManualFillResult = appStateManager.lastManualFillResult {
                Text(manualFillDisplayText(for: lastManualFillResult))
                    .font(.caption)
                    .foregroundStyle(lastManualFillResult == .filled ? Color.green : Color.secondary)
            }

            Button("Fill Admin Prompt Password") {
                appStateManager.fillFocusedPasswordField()
            }
            .disabled(!appStateManager.isManualFillAvailable)

            Button(facePresenceFillButtonTitle) {
                Task {
                    await appStateManager.fillFocusedPasswordFieldAfterFaceCheck()
                }
            }
            .disabled(!appStateManager.isManualFillAvailable || appStateManager.isFacePresenceFillChecking)

            if let lastFacePresenceFillResult = appStateManager.lastFacePresenceFillResult {
                Text(facePresenceFillDisplayText(for: lastFacePresenceFillResult))
                    .font(.caption)
                    .foregroundStyle(lastFacePresenceFillResult == .filled ? Color.green : Color.secondary)
            }

            if !appStateManager.isManualFillAvailable {
                Text("Requires Accessibility permission and a configured Keychain password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh Permissions") {
                appStateManager.refreshPermissions()
                appStateManager.refreshPasswordConfigurationStatus()
            }

            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit FacePass") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280, alignment: .leading)
    }

    private func authorizationPromptMonitorStatusColor(
        for status: AuthorizationPromptMonitorStatus
    ) -> Color {
        switch status {
        case .checkingRecognition, .fillResult(.filled):
            .green
        case .automaticPromptFillDisabled,
             .disabled,
             .inFlight,
             .noFocusedAuthorizationPrompt,
             .suppressedUntilPromptClears:
            .secondary
        case .accessibilityPermissionDenied,
             .conditionsNotSatisfied,
             .focusedAuthorizationPromptUnavailable,
             .multipleAuthorizationPromptPasswordFields,
             .multipleAuthorizationPromptPasswordFieldsDiagnostic,
             .lockedSessionSkipped,
             .setupRequired,
             .fillResult:
            .orange
        }
    }

    private var manualFillHotkeyStatusText: String {
        switch appStateManager.manualFillHotkeyStatus.runtimeRegistrationState {
        case .registered:
            "Hotkey is active for approved admin/System Settings prompts."
        case .disabled:
            "Hotkey is disabled until Accessibility and password setup are ready."
        case .unavailable:
            "Hotkey runtime is unavailable; use the button."
        case .failed:
            "Hotkey could not be registered; use the button."
        }
    }

    private var facePresenceFillButtonTitle: String {
        appStateManager.isFacePresenceFillChecking
            ? "Running FacePass Camera Check..."
            : "Run FacePass Recognition & Fill Admin Prompt"
    }

    private func manualFillDisplayText(for result: ManualFillResult) -> String {
        switch result {
        case .filled:
            "Admin/System Settings prompt value filled."
        case .missingPassword:
            "No password is configured."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required before filling admin/System Settings prompts."
        case .noFocusedPasswordField:
            "No approved macOS administrator/System Settings authorization password prompt was found."
        case .focusedPasswordFieldUnavailable:
            "The approved authorization password prompt is unavailable."
        case .multipleApprovedPasswordFields:
            "Multiple approved authorization password prompts were found."
        case .passwordReadFailed:
            "Unable to read password."
        case .recognitionRejected:
            "Local FacePass recognition did not approve admin/System Settings prompt fill."
        }
    }

    private func facePresenceFillDisplayText(for result: FacePresenceFillResult) -> String {
        switch result {
        case .checking:
            "Running local FacePass recognition..."
        case .filled:
            "Local FacePass recognition approved; admin/System Settings prompt value filled."
        case .cameraPermissionDenied:
            "Camera permission is required for local FacePass recognition."
        case .timedOut:
            "Local FacePass recognition did not complete before the check timed out."
        case .cameraFailed:
            "Local FacePass recognition could not use the camera."
        case .manualFillFailed(let manualResult):
            manualFillDisplayText(for: manualResult)
        }
    }
}
