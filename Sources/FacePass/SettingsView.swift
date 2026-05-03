import AppKit
import FacePassCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appStateManager: AppStateManager
    @State private var selectedSection = SettingsSection.permissions
    @State private var passwordInput = ""
    @State private var passwordStatusMessage: String?
    @State private var standByActionMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            ScrollView {
                selectedContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 500)
        .onAppear {
            appStateManager.refreshPermissions()
            appStateManager.refreshPasswordConfigurationStatus()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FacePass")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarButton(section: section, selection: $selectedSection)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 184)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .permissions:
            permissionsTab
        case .password:
            passwordTab
        case .automation:
            automationTab
        case .unlockMode:
            unlockModeTab
        case .standByUnlock:
            standByUnlockTab
        case .recognition:
            recognitionTab
        case .about:
            aboutTab
        }
    }

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.title2.weight(.semibold))
                Text("FacePass uses Keychain for password storage, Accessibility for approved macOS administrator/System Settings authorization prompts and Apple Passwords unlock prompts, and the camera only for short local recognition, enrollment, and opt-in wake-triggered lock-screen checks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("FacePass Enabled", isOn: enabledBinding)
                .toggleStyle(.switch)

            readinessPanel

            VStack(spacing: 10) {
                ForEach(appStateManager.permissionStatuses) { status in
                    PermissionSettingsRow(
                        status: status,
                        actionLabel: permissionActionLabel(for: status),
                        action: permissionAction(for: status)
                    )
                }
            }

            HStack {
                Button("Refresh") {
                    appStateManager.refreshPermissions()
                }

                Spacer()

                Button("Open Privacy Settings") {
                    SystemSettingsOpener.openPrivacySettings()
                }
            }

            Spacer()
        }
    }

    private var passwordTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.title2.weight(.semibold))
                Text(passwordConfigurationText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The saved password is stored in Keychain and is not shown in FacePass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsReadinessRow(
                title: "Saved Password",
                detail: appStateManager.passwordConfigurationState.isPasswordConfigured
                    ? "A password is saved in Keychain."
                    : "No password is saved yet.",
                isReady: appStateManager.passwordConfigurationState.isPasswordConfigured
            )
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            SecureField("Password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button(appStateManager.passwordConfigurationState.isPasswordConfigured ? "Update Password" : "Save Password") {
                    savePassword()
                }
                .disabled(passwordInput.isEmpty)

                Button("Delete Password", role: .destructive) {
                    deletePassword()
                }
                .disabled(!appStateManager.passwordConfigurationState.isPasswordConfigured)

                Button("Verify Keychain Access") {
                    preflightKeychainPasswordAccess()
                }
                .disabled(!appStateManager.passwordConfigurationState.isPasswordConfigured)

                Spacer()
            }

            Text("Use Verify Keychain Access while the session is unlocked to approve the macOS Keychain prompt before lock-screen use. FacePass reads the saved value only for this check, discards it immediately, and does not recommend weakening Keychain prompt protections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Unlocked-session fill is only for approved macOS administrator/System Settings authorization prompts and Apple Passwords unlock prompts. It runs local FacePass recognition first, fills the saved value only, and does not click Unlock/OK/Continue/Login, submit, or press Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Enable opt-in wake-triggered lock-screen unlock", isOn: lockScreenUnlockEnabledBinding)
                    .toggleStyle(.switch)
                Text("The shortcut is only for approved unlocked admin/System Settings authorization prompts and Apple Passwords unlock prompts. Because the macOS lock screen may not deliver global hotkeys, the separate lock-screen path listens for display or system wake and then makes a short delayed attempt if this option is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If a wake-triggered lock-screen attempt is enabled, FacePass first shows runtime scanning feedback, opens a short temporary camera window, and only after the enrolled local template passes the local recognition gate does it type the saved password and press Return for the locked session path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is not Apple Face ID, system biometrics, or a replacement for macOS authentication. Recognition is local app processing against an encrypted local template during that short wake-triggered window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("For locked-session use, macOS may ask for Keychain access when FacePass reads the saved password during the locked-session path. FacePass waits for user approval of that system prompt and does not recommend weakening Keychain prompt protections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ordinary webpage and app password fields are not a FacePass feature. Unlocked-session approved prompt fill remains value-only and never clicks, submits, or presses Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Global hotkey: \(appStateManager.manualFillHotkeyStatus.displayName). \(manualFillHotkeyStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Screen-state monitor: \(appStateManager.isScreenStateMonitorActive ? "Active" : "Inactive"). Wake-triggered lock-screen attempts only run while this runtime observer is active.")
                    .font(.caption)
                    .foregroundStyle(appStateManager.isScreenStateMonitorActive ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastManualFillResult = appStateManager.lastManualFillResult {
                    Text("Last approved prompt fill: \(manualFillDisplayText(for: lastManualFillResult))")
                        .foregroundStyle(manualFillStatusColor(for: lastManualFillResult))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastLockScreenUnlockResult = appStateManager.lastLockScreenUnlockResult {
                    Text("Last hotkey lock-screen fallback: \(lastLockScreenUnlockResult.description)")
                        .foregroundStyle(lockScreenUnlockStatusColor(for: lastLockScreenUnlockResult))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastAutomaticLockScreenAttemptStatus = appStateManager.lastAutomaticLockScreenAttemptStatus {
                    Text("Last automatic wake-triggered lock-screen attempt: \(lastAutomaticLockScreenAttemptStatus.description)")
                        .foregroundStyle(automaticLockScreenAttemptStatusColor(for: lastAutomaticLockScreenAttemptStatus))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastFacePresenceFillResult = appStateManager.lastFacePresenceFillResult {
                    Text(facePresenceFillDisplayText(for: lastFacePresenceFillResult))
                        .foregroundStyle(facePresenceFillStatusColor(for: lastFacePresenceFillResult))
                }

                if !appStateManager.isManualFillAvailable {
                    Text(appStateManager.isEnabled ? "Requires Accessibility permission and a configured Keychain password." : "FacePass is disabled from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let passwordStatusMessage {
                Text(passwordStatusMessage)
                    .foregroundStyle(.secondary)
            }

            if let preflightStatus = appStateManager.passwordConfigurationState.keychainPreflightStatus {
                Text(preflightStatus.description)
                    .foregroundStyle(keychainPreflightStatusColor(for: preflightStatus))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastError = appStateManager.passwordConfigurationState.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .onAppear {
            appStateManager.refreshPasswordConfigurationStatus()
        }
    }

    private var automationTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automation")
                    .font(.title2.weight(.semibold))
                Text("Automatic actions cover approved admin/System Settings and Apple Passwords prompt handling and the opt-in wake-triggered lock-screen path. Manual menu and hotkey actions are not blocked by trusted conditions in this MVP.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Automatically handle approved unlocked prompts", isOn: automaticAuthorizationPromptFillEnabledBinding)
                    .toggleStyle(.switch)
                Text("When enabled, FacePass checks for an approved authorization prompt while the session is unlocked, runs local recognition first, fills the password value only, and does not click, submit, or press Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Use trusted conditions for automatic actions", isOn: automationConditionGateEnabledBinding)
                    .toggleStyle(.switch)

                Picker("Match mode", selection: automationConditionMatchModeBinding) {
                    ForEach(AutomationConditionMatchMode.allCases, id: \.self) { mode in
                        Text(mode.description).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!appStateManager.automationConditionSettings.isConditionGateEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Wi-Fi connected", isOn: automationWiFiConnectedBinding)
                    Toggle("External monitor connected", isOn: automationExternalDisplayConnectedBinding)

                    Text("Power")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    Toggle("External power", isOn: automationPowerStateBinding(.externalPower))
                    Toggle("Charging", isOn: automationPowerStateBinding(.charging))
                    Toggle("Battery", isOn: automationPowerStateBinding(.battery))
                }
                .disabled(!appStateManager.automationConditionSettings.isConditionGateEnabled)

                Text("FacePass stores only these policy toggles. It does not store or show observed SSID, BSSID, display identifiers, Bluetooth device identifiers, or environment values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Bluetooth trusted conditions are disabled in this MVP; FacePass does not run background Bluetooth scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.headline)
                Text("Authorization prompt monitor: \(appStateManager.isAuthorizationPromptMonitorActive ? "Active" : "Inactive")")
                    .foregroundStyle(appStateManager.isAuthorizationPromptMonitorActive ? .green : .secondary)

                if let lastAuthorizationPromptMonitorStatus = appStateManager.lastAuthorizationPromptMonitorStatus {
                    Text("Last prompt check: \(lastAuthorizationPromptMonitorStatus.description)")
                        .foregroundStyle(authorizationPromptMonitorStatusColor(for: lastAuthorizationPromptMonitorStatus))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastAutomationConditionEvaluation = appStateManager.lastAutomationConditionEvaluation {
                    Text("Last condition check: \(lastAutomationConditionEvaluation.summary)")
                        .foregroundStyle(lastAutomationConditionEvaluation.isAllowed ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Last condition check: Not evaluated yet.")
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Condition Status") {
                    appStateManager.refreshAutomationConditionEvaluation()
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            Spacer()
        }
        .onAppear {
            appStateManager.refreshAutomationConditionEvaluation()
        }
    }

    private var standByUnlockTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("iPhone StandBy Unlock")
                    .font(.title2.weight(.semibold))
                Text("StandBy Unlock lets a paired iPhone request the locked-session FacePass password typing path over the local network. It is independent from Mac local FacePass recognition and does not use the Mac camera.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Each request must be approved on the iPhone first, such as by unlocking the iPhone, Face ID, or device approval, before the signed request is sent to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is not Apple Face ID on Mac, system biometrics, or a replacement for macOS authentication. The Mac password is never sent to the iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Enable iPhone StandBy Unlock", isOn: standByUnlockEnabledBinding)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 12) {
                Text("Pairing")
                    .font(.headline)

                if appStateManager.standByIPhoneUnlockStatus.pairingState == .pairing {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            standByPairingQRCode
                            standByPairingControls
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            standByPairingQRCode
                            standByPairingControls
                        }
                    }
                } else {
                    standByPairingControls
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text("Status")
                    .font(.headline)
                SettingsStatusRow(
                    title: "Pairing",
                    detail: appStateManager.standByIPhoneUnlockStatus.pairingState.description
                )
                SettingsStatusRow(
                    title: "Paired iPhone",
                    detail: appStateManager.standByIPhoneUnlockStatus.pairedIPhoneStatusText
                )
                SettingsStatusRow(
                    title: "Last Seen",
                    detail: standByLastSeenText
                )
                SettingsStatusRow(
                    title: "Local Server",
                    detail: appStateManager.standByIPhoneUnlockStatus.httpServerStatus.rawValue.capitalized
                )
                SettingsStatusRow(
                    title: "Bonjour",
                    detail: appStateManager.standByIPhoneUnlockStatus.bonjourStatusDescription ?? "Not published"
                )
                SettingsStatusRow(
                    title: "Last Request",
                    detail: standByLastRequestText
                )
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            Text("The selected provider mode controls whether local FacePass recognition, paired iPhone approval, or both may handle lock-screen unlock and approved unlocked prompt fill. Approved unlocked prompt fill remains value-only and never clicks or submits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .onAppear {
            appStateManager.refreshStandByUnlockStatus()
        }
    }

    private var unlockModeTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unlock Mode")
                    .font(.title2.weight(.semibold))
                Text("Choose which FacePass provider may handle each approved flow. This does not change password storage, pairing trust, or the prompt allowlist.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only the lock-screen path can press Return. Approved unlocked prompt fill remains value-only and never clicks, submits, or presses Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Provider Policy")
                    .font(.headline)
                Picker("Mode", selection: unlockProviderPolicyBinding) {
                    ForEach(FacePassUnlockProviderPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)

                Divider()

                Text(appStateManager.unlockProviderPolicy.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text("Current Routing")
                    .font(.headline)
                SettingsStatusRow(
                    title: "Lock Screen",
                    detail: unlockProviderLockScreenDetail
                )
                SettingsStatusRow(
                    title: "Unlocked Prompt",
                    detail: unlockProviderAuthorizationPromptDetail
                )
                SettingsStatusRow(
                    title: "iPhone StandBy Unlock",
                    detail: appStateManager.isStandByUnlockEnabled ? "Enabled" : "Disabled"
                )
                SettingsStatusRow(
                    title: "Local Recognition",
                    detail: appStateManager.isLockScreenUnlockEnabled ? "Enabled" : "Disabled"
                )
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            Spacer()
        }
    }

    private var recognitionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recognition Prototype")
                    .font(.title2.weight(.semibold))
                Text("This local prototype opens camera-backed FacePass recognition UI for explicit enrollment and observation, saves encrypted local embeddings, and can show a local similarity score. Unlocked approved prompt fill runs local recognition first, fills the saved value only, and does not click, submit, or press Return.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Recognition is FacePass-local processing, not Apple Face ID, system biometrics, or a macOS authentication replacement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bundled local model")
                    .font(.headline)
                Text("FacePass uses the bundled local recognition model selected by the app build. Model files are not chosen in Settings, and FacePass does not download or sync recognition data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let checksum = appStateManager.recognitionRuntimeState.lastModelChecksumSHA256 {
                    Text("Last saved model checksum: \(checksum)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text("Enrollment")
                    .font(.headline)
                Text("Capture \(appStateManager.recognitionRuntimeState.requiredEnrollmentSampleCount) one-second single-face samples with the camera-backed FacePass recognition UI. FacePass automatically saves encrypted local embeddings after the required samples are captured. Raw frames, photos, crops, and sample buffers are not stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsReadinessRow(
                    title: "Saved Face",
                    detail: appStateManager.recognitionRuntimeState.hasSavedEnrollmentTemplate
                        ? "An encrypted local face template is saved."
                        : "No encrypted local face template is saved yet.",
                    isReady: appStateManager.recognitionRuntimeState.hasSavedEnrollmentTemplate
                )

                HStack(spacing: 10) {
                    Button(appStateManager.recognitionRuntimeState.hasSavedEnrollmentTemplate ? "Recapture" : "Capture Enrollment") {
                        Task {
                            await appStateManager.captureRecognitionEnrollmentSample()
                        }
                    }
                    .disabled(appStateManager.recognitionRuntimeState.isBusy)

                    Button("Clear Saved Face", role: .destructive) {
                        appStateManager.clearRecognitionEnrollmentSamples()
                    }
                    .disabled(
                        appStateManager.recognitionRuntimeState.isBusy ||
                            !appStateManager.recognitionRuntimeState.hasSavedEnrollmentTemplate
                    )

                    Spacer()
                }

                Text("Captured samples: \(appStateManager.recognitionRuntimeState.capturedEnrollmentSampleCount) / \(appStateManager.recognitionRuntimeState.requiredEnrollmentSampleCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text("Similarity Threshold")
                    .font(.headline)
                HStack {
                    Slider(
                        value: recognitionSimilarityBinding,
                        in: Double(FaceRecognitionRuntimeController.minimumAllowedUnlockSimilarity)...Double(FaceRecognitionRuntimeController.maximumAllowedUnlockSimilarity),
                        step: 0.01
                    )
                    Text(String(format: "%.2f", appStateManager.recognitionRuntimeState.unlockMinimumSimilarity))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Recommended default: \(String(format: "%.2f", FaceRecognitionRuntimeController.defaultUnlockMinimumSimilarity)). Higher values are stricter; lower values are more permissive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset to Recommended") {
                    appStateManager.setRecognitionUnlockMinimumSimilarity(
                        FaceRecognitionRuntimeController.defaultUnlockMinimumSimilarity
                    )
                }
                .disabled(appStateManager.recognitionRuntimeState.isBusy)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text("Observe Once")
                    .font(.headline)
                Text("Observe Once shows the camera-backed FacePass recognition UI for a one-second capture attempt, evaluates any visible face candidates from the frame against the encrypted local template, and reports the best local similarity score. Enrollment still requires exactly one visible face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Observe Once") {
                    Task {
                        await appStateManager.observeRecognitionOnce()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appStateManager.recognitionRuntimeState.isBusy)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            Text(recognitionStatusDisplayText(for: appStateManager.recognitionRuntimeState.status))
                .foregroundStyle(recognitionStatusColor(for: appStateManager.recognitionRuntimeState.status))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .onAppear {
            appStateManager.refreshRecognitionRuntimeStatus()
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FacePass")
                .font(.title2.weight(.semibold))
            Text(AppVersionInfo.displayText(infoDictionary: Bundle.main.infoDictionary))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Check for Updates...") {
                NSApp.sendAction(Selector(("checkForUpdates:")), to: nil, from: nil)
            }
            .buttonStyle(.bordered)
            Text("A lightweight menu-bar password-fill and unlock helper for macOS. It is custom FacePass feedback, not a replacement for macOS sign-in or Apple security features.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Current runtime behavior supports Keychain password setup, approved unlocked admin/System Settings authorization prompt and Apple Passwords unlock prompt fill, an opt-in wake-triggered lock-screen path with the hotkey kept as a secondary fallback, and recognition prototype controls. Ordinary webpage and app password fields are not a FacePass feature. FacePass recognition is local app processing with encrypted local embeddings, not true biometric authentication, Apple Face ID, system biometrics, or a macOS authentication replacement.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Unlocked approved prompt fill is limited to setting the saved value after local recognition; it does not click Unlock/OK/Continue/Login, press Return, or submit.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The separate opt-in lock-screen path runs on display or system wake because the lock screen may not deliver hotkeys. That path types the saved password and presses Return for the locked session only after a short local recognition gate matches the enrolled local template.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var readinessPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approved Prompt Fill Readiness")
                .font(.headline)

            SettingsReadinessRow(
                title: "Accessibility",
                detail: isAccessibilityAuthorized
                    ? "Authorized for approved admin/System Settings and Apple Passwords prompt inspection and value-only fill."
                    : "Required before approved prompt fill or the default hotkey can run.",
                isReady: isAccessibilityAuthorized
            )

            SettingsReadinessRow(
                title: "Password setup",
                detail: appStateManager.passwordConfigurationState.isPasswordConfigured
                    ? "Password saved in Keychain."
                    : "Not configured. Keychain Available means storage is reachable, not that a password has been saved.",
                isReady: appStateManager.passwordConfigurationState.isPasswordConfigured
            )

            if !appStateManager.passwordConfigurationState.isPasswordConfigured {
                Button("Open Password Setup") {
                    selectedSection = .password
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var passwordConfigurationText: String {
        appStateManager.passwordConfigurationState.isPasswordConfigured
            ? "Password saved in Keychain."
            : "No password is configured."
    }

    private var unlockProviderLockScreenDetail: String {
        let policy = appStateManager.unlockProviderPolicy
        switch (policy.allowsLocalFaceLockScreenUnlock, policy.allowsIPhoneLockScreenUnlock) {
        case (true, true):
            return "Local face recognition or paired iPhone approval"
        case (true, false):
            return "Local face recognition only"
        case (false, true):
            return "Paired iPhone approval only"
        case (false, false):
            return "Disabled by current provider policy"
        }
    }

    private var unlockProviderAuthorizationPromptDetail: String {
        let policy = appStateManager.unlockProviderPolicy
        switch (policy.allowsLocalFaceAuthorizationPromptFill, policy.allowsIPhoneAuthorizationPromptFill) {
        case (true, true):
            return "Local face recognition or paired iPhone approval"
        case (true, false):
            return "Local face recognition only"
        case (false, true):
            return "Paired iPhone approval only"
        case (false, false):
            return "Disabled by current provider policy"
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.isEnabled },
            set: { appStateManager.setEnabled($0) }
        )
    }

    private var lockScreenUnlockEnabledBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.isLockScreenUnlockEnabled },
            set: { appStateManager.setLockScreenUnlockEnabled($0) }
        )
    }

    private var automaticAuthorizationPromptFillEnabledBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.automationConditionSettings.isAutomaticAuthorizationPromptFillEnabled },
            set: { appStateManager.setAutomaticAuthorizationPromptFillEnabled($0) }
        )
    }

    private var standByUnlockEnabledBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.isStandByUnlockEnabled },
            set: { appStateManager.setStandByUnlockEnabled($0) }
        )
    }

    private var unlockProviderPolicyBinding: Binding<FacePassUnlockProviderPolicy> {
        Binding(
            get: { appStateManager.unlockProviderPolicy },
            set: { appStateManager.setUnlockProviderPolicy($0) }
        )
    }

    private var recognitionSimilarityBinding: Binding<Double> {
        Binding(
            get: { Double(appStateManager.recognitionRuntimeState.unlockMinimumSimilarity) },
            set: { appStateManager.setRecognitionUnlockMinimumSimilarity(Float($0)) }
        )
    }

    private var automationConditionGateEnabledBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.automationConditionSettings.isConditionGateEnabled },
            set: { appStateManager.setAutomationConditionGateEnabled($0) }
        )
    }

    private var automationConditionMatchModeBinding: Binding<AutomationConditionMatchMode> {
        Binding(
            get: { appStateManager.automationConditionSettings.matchMode },
            set: { appStateManager.setAutomationConditionMatchMode($0) }
        )
    }

    private var automationWiFiConnectedBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.automationConditionSettings.requiresWiFiConnected },
            set: { appStateManager.setAutomationRequiresWiFiConnected($0) }
        )
    }

    private var automationExternalDisplayConnectedBinding: Binding<Bool> {
        Binding(
            get: { appStateManager.automationConditionSettings.requiresExternalDisplayConnected },
            set: { appStateManager.setAutomationRequiresExternalDisplayConnected($0) }
        )
    }

    private func automationPowerStateBinding(_ powerState: PowerState) -> Binding<Bool> {
        Binding(
            get: { appStateManager.automationConditionSettings.allowedPowerStates.contains(powerState) },
            set: { appStateManager.setAutomationPowerState(powerState, enabled: $0) }
        )
    }

    private func savePassword() {
        do {
            try appStateManager.savePassword(passwordInput)
            passwordInput = ""
            passwordStatusMessage = "Password saved in Keychain."
        } catch {
            passwordInput = ""
            passwordStatusMessage = "Password could not be saved."
        }
    }

    private func deletePassword() {
        do {
            try appStateManager.deletePassword()
            passwordInput = ""
            passwordStatusMessage = "Password deleted."
        } catch {
            passwordStatusMessage = "Password could not be deleted."
        }
    }

    private func preflightKeychainPasswordAccess() {
        _ = appStateManager.preflightKeychainPasswordAccess()
        passwordStatusMessage = nil
    }

    private func forgetStandByPairedIPhone() {
        do {
            try appStateManager.forgetStandByPairedIPhone()
            standByActionMessage = "Paired iPhone trust record removed."
        } catch {
            standByActionMessage = "Paired iPhone could not be forgotten."
        }
    }

    private var standByPairingInstructionText: String {
        switch appStateManager.standByIPhoneUnlockStatus.pairingState {
        case .pairing:
            "Scan this QR code from the FacePass iPhone companion to pair. The QR does not include the Mac password or private keys."
        case .paired:
            "An iPhone is paired. Start a new pairing session only when replacing the trusted iPhone."
        case .notPaired:
            "Start pairing to show a short-lived QR code for the iPhone companion."
        case .unavailable:
            "StandBy Unlock pairing is unavailable because the local Mac identity or server runtime is not ready."
        }
    }

    private var standByPairingQRCode: some View {
        QRCodeImage(payload: appStateManager.standByIPhoneUnlockStatus.pairingQRCodePayload)
    }

    private var standByPairingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(standByPairingInstructionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Button("Pair iPhone") {
                    appStateManager.startStandByPairingSession()
                    standByActionMessage = "Pairing QR is ready."
                }

                Button("Forget iPhone", role: .destructive) {
                    forgetStandByPairedIPhone()
                }
                .disabled(appStateManager.standByIPhoneUnlockStatus.pairingState != .paired)

                Button("Test Connection") {
                    appStateManager.refreshStandByUnlockStatus()
                    standByActionMessage = "StandBy Unlock status refreshed."
                }
            }

            if let standByActionMessage {
                Text(standByActionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var standByLastRequestText: String {
        appStateManager.standByIPhoneUnlockStatus.lastRequestResult?.userFacingDescription
            ?? "No StandBy Unlock request yet."
    }

    private var standByLastSeenText: String {
        guard let lastSeenAt = appStateManager.standByIPhoneUnlockStatus.lastSeenAt else {
            return "Never"
        }

        return lastSeenAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func manualFillStatusColor(for result: ManualFillResult) -> Color {
        result == .filled ? .green : .secondary
    }

    private func manualFillDisplayText(for result: ManualFillResult) -> String {
        switch result {
        case .filled:
            "Approved prompt value filled."
        case .missingPassword:
            "No password is configured."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required before filling approved prompts."
        case .noFocusedPasswordField:
            "No approved macOS administrator/System Settings authorization prompt or Apple Passwords unlock prompt was found."
        case .focusedPasswordFieldUnavailable:
            "The approved prompt is unavailable."
        case .multipleApprovedPasswordFields:
            "Multiple approved prompts were found."
        case .passwordReadFailed:
            "Unable to read password."
        case .recognitionRejected:
            "Local FacePass recognition did not approve the prompt fill."
        case .localRecognitionDisabled:
            "Local FacePass recognition is disabled by the selected provider mode."
        }
    }

    private func facePresenceFillStatusColor(for result: FacePresenceFillResult) -> Color {
        result == .filled ? .green : .secondary
    }

    private func facePresenceFillDisplayText(for result: FacePresenceFillResult) -> String {
        switch result {
        case .checking:
            "Running local FacePass recognition..."
        case .filled:
            "Local FacePass recognition approved; prompt value filled."
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

    private func lockScreenUnlockStatusColor(for result: LockScreenUnlockResult) -> Color {
        result == .typedPasswordAndSubmitted ? .green : .secondary
    }

    private func automaticLockScreenAttemptStatusColor(
        for status: AutomaticLockScreenAttemptStatus
    ) -> Color {
        if case .unlockResult(.typedPasswordAndSubmitted) = status {
            return .green
        }

        return .secondary
    }

    private func authorizationPromptMonitorStatusColor(
        for status: AuthorizationPromptMonitorStatus
    ) -> Color {
        switch status {
        case .fillResult(.filled):
            .green
        case .conditionsNotSatisfied,
             .focusedAuthorizationPromptUnavailable,
             .multipleAuthorizationPromptPasswordFields,
             .multipleAuthorizationPromptPasswordFieldsDiagnostic,
             .accessibilityPermissionDenied,
             .setupRequired:
            .orange
        default:
            .secondary
        }
    }

    private func keychainPreflightStatusColor(for status: KeychainPasswordPreflightStatus) -> Color {
        switch status {
        case .verified:
            .green
        case .notConfigured, .readFailed:
            .orange
        }
    }

    private func recognitionStatusColor(for status: FaceRecognitionRuntimeStatus) -> Color {
        switch status {
        case .enrollmentSampleCaptured, .enrollmentSaved, .observeSucceeded, .modelPathUpdated:
            return .green
        case .idle, .capturingEnrollmentSample, .savingEnrollment, .capturingObserveSample:
            return .secondary
        default:
            return .orange
        }
    }

    private func recognitionStatusDisplayText(for status: FaceRecognitionRuntimeStatus) -> String {
        switch status {
        case .idle:
            "Recognition runtime is idle. Settings actions stay local; unlocked approved prompt fill and the opt-in wake-triggered lock-screen path may use the local recognition gate."
        case let .observeSucceeded(similarity, templateCount, modelVersion):
            "Settings similarity \(String(format: "%.3f", similarity)) against \(templateCount) encrypted local templates for model \(modelVersion). Settings actions stay local; unlocked approved prompt fill remains value-only, while wake-triggered lock-screen unlock may type the password and press Return only while the session is locked."
        default:
            status.description
        }
    }

    private var isAccessibilityAuthorized: Bool {
        appStateManager.permissionStatuses.contains { status in
            status.kind == .accessibility && status.authorization == .authorized
        }
    }

    private var manualFillHotkeyStatusText: String {
        switch appStateManager.manualFillHotkeyStatus.runtimeRegistrationState {
        case .registered:
            appStateManager.isLockScreenUnlockEnabled
                ? "Active for approved admin/System Settings and Apple Passwords prompts. Wake events drive the separate opt-in lock-screen path with its short temporary camera window."
                : "Active for approved admin/System Settings and Apple Passwords prompts."
        case .disabled:
            "Disabled until Accessibility and password setup are ready."
        case .unavailable:
            "Unavailable in this build; use the menu-bar action."
        case .failed:
            "Could not be registered; use the menu-bar action."
        }
    }

    private func permissionActionLabel(for status: PermissionStatus) -> String? {
        switch status.kind {
        case .camera:
            status.authorization == .notDetermined ? "Request Camera" : "Camera Settings"
        case .keychain:
            "Password Setup"
        case .accessibility:
            nil
        }
    }

    private func permissionAction(for status: PermissionStatus) -> (() -> Void)? {
        switch status.kind {
        case .camera:
            if status.authorization == .notDetermined {
                return {
                    Task {
                        await appStateManager.requestCameraPermission()
                    }
                }
            }

            return {
                SystemSettingsOpener.openCameraSettings()
            }
        case .keychain:
            return {
                selectedSection = .password
            }
        case .accessibility:
            return nil
        }
    }
}

private enum SettingsSection: CaseIterable, Identifiable {
    case permissions
    case password
    case automation
    case unlockMode
    case standByUnlock
    case recognition
    case about

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .permissions:
            "Permissions"
        case .password:
            "Password Setup"
        case .automation:
            "Automation"
        case .unlockMode:
            "Unlock Mode"
        case .standByUnlock:
            "iPhone Unlock"
        case .recognition:
            "Recognition"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .permissions:
            "hand.raised"
        case .password:
            "key"
        case .automation:
            "switch.2"
        case .unlockMode:
            "checkmark.shield"
        case .standByUnlock:
            "iphone"
        case .recognition:
            "person.crop.rectangle"
        case .about:
            "info.circle"
        }
    }
}

private struct SettingsSidebarButton: View {
    let section: SettingsSection
    @Binding var selection: SettingsSection

    private var isSelected: Bool {
        selection == section
    }

    var body: some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .frame(width: 18)
                Text(section.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(.horizontal, 10)
    }
}

private struct SettingsReadinessRow: View {
    let title: String
    let detail: String
    let isReady: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 112, alignment: .leading)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionSettingsRow: View {
    let status: PermissionStatus
    let actionLabel: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isGranted ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(status.title)
                        .font(.headline)
                    Spacer()
                    Text(status.statusText)
                        .foregroundStyle(.secondary)
                }

                Text(status.kind.purpose)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status.kind == .keychain {
                    Text("The Keychain prompt appears when you save or update the password, run the unlocked-session Verify Keychain Access check, or FacePass reads it for the locked-session path. FacePass does not recommend weakening Keychain prompt protections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
