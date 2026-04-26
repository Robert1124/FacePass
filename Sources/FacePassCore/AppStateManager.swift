import Foundation

@MainActor
public protocol AutomaticLockScreenOverlayPresenting: AnyObject {
    func showScanning()
    func showSuccess()
    func showFailure()
    func showTimeout()
    func showRecognitionPreviewScanning()
    func showRecognitionPreviewRecognized()
    func showRecognitionPreviewFailure()
    func dismiss()
}

public final class AppStateManager: ObservableObject {
    private static let lockScreenUnlockEnabledDefaultsKey = "FacePass.lockScreenUnlockEnabled"
    private static let automaticLockScreenOverlayDismissDelay: TimeInterval = 1
    private static let recognitionPreviewStepDelay: TimeInterval = 0.9
    private static let recognitionPreviewDismissDelay: TimeInterval = 2.4

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isLockScreenUnlockEnabled: Bool
    @Published public private(set) var isScreenStateMonitorActive: Bool = false
    @Published public private(set) var permissionStatuses: [PermissionStatus]
    @Published public private(set) var passwordConfigurationState: PasswordConfigurationState
    @Published public private(set) var lastManualFillResult: ManualFillResult?
    @Published public private(set) var lastFacePresenceFillResult: FacePresenceFillResult?
    @Published public private(set) var lastLockScreenUnlockResult: LockScreenUnlockResult?
    @Published public private(set) var lastAutomaticLockScreenUnlockResult: LockScreenUnlockResult?
    @Published public private(set) var lastAutomaticLockScreenAttemptStatus: AutomaticLockScreenAttemptStatus?
    @Published public private(set) var isAuthorizationPromptMonitorActive: Bool = false
    @Published public private(set) var automationConditionSettings: AutomationConditionSettings
    @Published public private(set) var lastAutomationConditionEvaluation: AutomationConditionEvaluation?
    @Published public private(set) var lastAutomaticAuthorizationPromptFillResult: ManualFillResult?
    @Published public private(set) var lastAuthorizationPromptMonitorStatus: AuthorizationPromptMonitorStatus?
    @Published public private(set) var manualFillHotkeyStatus: ManualFillHotkeyStatus
    @Published public private(set) var recognitionRuntimeState: FaceRecognitionRuntimeState

    private let permissionStatusProvider: PermissionStatusProviding
    private let cameraPermissionProvider: any CameraFaceDetectionPermissionProviding
    private let passwordSettingsController: PasswordSettingsController
    private let manualFillController: ManualFillController
    private let automaticLockScreenFacePresenceDetector: any FacePresenceDetecting
    private let facePresenceFillController: FacePresenceFillController
    private let lockScreenStateProvider: LockScreenStateProviding
    private let lockScreenUnlockController: LockScreenUnlockController
    private let hotkeyManager: HotkeyManager
    private let manualFillHotkeyDescriptor: HotkeyDescriptor
    private let recognitionRuntimeController: FaceRecognitionRuntimeController
    private let automationConditionSettingsStore: AutomationConditionSettingsStore
    private let automationConditionEvaluator: AutomationConditionEvaluator
    private let userDefaults: UserDefaults
    private let screenStateEventScheduler: any UnlockScheduler
    private let lockScreenWakeDelay: TimeInterval
    private let automaticLockScreenFaceCheckTimeout: TimeInterval
    private var manualFillHotkeyRegistration: HotkeyRegistrationToken?
    private weak var automaticLockScreenOverlayPresenter: (any AutomaticLockScreenOverlayPresenting)?
    private var isFacePresenceFillInFlight = false
    private var isAutomaticAuthorizationPromptFillInFlight = false
    private var isAutomaticAuthorizationPromptSuppressedUntilPromptClears = false
    private var isAutomaticLockScreenAttemptScheduled = false
    private var isAutomaticLockScreenAttemptInFlight = false
    private var shouldSuppressScheduledAutomaticLockScreenAttempt = false
    private var automaticLockScreenOverlayGeneration: UInt = 0
    private var recognitionPreviewGeneration: UInt = 0

    public init(
        permissionStatusProvider: PermissionStatusProviding = SystemPermissionStatusProvider(),
        passwordVault: PasswordVaultProviding = PasswordVault(),
        autofillService: PasswordAutofillService = AccessibilityAutofillService(),
        passwordAccount: String = defaultPasswordAccountIdentifier,
        hotkeyManager: HotkeyManager = HotkeyManager(),
        manualFillHotkeyDescriptor: HotkeyDescriptor = .defaultManualFill,
        facePresenceDetector: any FacePresenceDetecting = CameraFaceDetector(),
        cameraPermissionProvider: any CameraFaceDetectionPermissionProviding = SystemCameraFaceDetectionPermissionProvider(),
        facePresenceCheckTimeout: TimeInterval = 3,
        automaticLockScreenFaceCheckTimeout: TimeInterval = 1,
        lockScreenStateProvider: LockScreenStateProviding = SystemLockScreenStateProvider(),
        lockScreenPasswordTyper: LockScreenPasswordTyping = SystemLockScreenPasswordTyper(),
        recognitionRuntimeController: FaceRecognitionRuntimeController = FaceRecognitionRuntimeController(),
        screenStateEventScheduler: (any UnlockScheduler)? = nil,
        lockScreenWakeDelay: TimeInterval = 1,
        conditionSignalProvider: any ConditionSignalProviding = MacConditionSignalProvider(),
        userDefaults: UserDefaults = .standard
    ) {
        self.isEnabled = true
        self.userDefaults = userDefaults
        let automationConditionSettingsStore = AutomationConditionSettingsStore(userDefaults: userDefaults)
        self.automationConditionSettingsStore = automationConditionSettingsStore
        self.automationConditionSettings = automationConditionSettingsStore.load()
        self.automationConditionEvaluator = AutomationConditionEvaluator(signalProvider: conditionSignalProvider)
        self.isLockScreenUnlockEnabled = userDefaults.bool(
            forKey: Self.lockScreenUnlockEnabledDefaultsKey
        )
        self.screenStateEventScheduler = screenStateEventScheduler ?? MainQueueUnlockScheduler()
        self.lockScreenWakeDelay = max(0, lockScreenWakeDelay)
        self.permissionStatusProvider = permissionStatusProvider
        self.cameraPermissionProvider = cameraPermissionProvider
        self.hotkeyManager = hotkeyManager
        self.manualFillHotkeyDescriptor = manualFillHotkeyDescriptor
        self.recognitionRuntimeController = recognitionRuntimeController
        self.automaticLockScreenFacePresenceDetector = facePresenceDetector
        self.automaticLockScreenFaceCheckTimeout = max(0, automaticLockScreenFaceCheckTimeout)
        self.lockScreenStateProvider = lockScreenStateProvider
        self.passwordSettingsController = PasswordSettingsController(
            vault: passwordVault,
            account: passwordAccount
        )
        let manualFillController = ManualFillController(
            vault: passwordVault,
            autofillService: autofillService,
            account: passwordAccount
        )
        self.manualFillController = manualFillController
        self.facePresenceFillController = FacePresenceFillController(
            detector: facePresenceDetector,
            manualFill: manualFillController.fillFocusedPasswordField,
            timeout: facePresenceCheckTimeout
        )
        self.lockScreenUnlockController = LockScreenUnlockController(
            stateProvider: lockScreenStateProvider,
            passwordVault: passwordVault,
            passwordTyper: lockScreenPasswordTyper,
            account: passwordAccount
        )
        self.permissionStatuses = permissionStatusProvider.currentPermissionStatuses()
        self.passwordConfigurationState = passwordSettingsController.state
        self.manualFillHotkeyStatus = ManualFillHotkeyStatus(
            descriptor: manualFillHotkeyDescriptor,
            runtimeRegistrationState: .disabled,
            isEnabled: false
        )
        self.recognitionRuntimeState = recognitionRuntimeController.state
    }

    public var overallPermissionState: OverallPermissionState {
        isManualFillReady ? .ready : .needsAttention
    }

    public var isManualFillAvailable: Bool {
        isEnabled && isManualFillReady
    }

    public var areAllPermissionsAcquired: Bool {
        let statusesByKind = Dictionary(uniqueKeysWithValues: permissionStatuses.map { ($0.kind, $0) })
        return PermissionKind.allCases.allSatisfy { kind in
            statusesByKind[kind]?.isGranted == true
        }
    }

    public var isFacePresenceFillChecking: Bool {
        lastFacePresenceFillResult == .checking
    }

    public var menuStatus: MenuStatus {
        switch overallPermissionState {
        case .ready:
            MenuStatus(
                title: "Authorization Fill Ready",
                detail: isLockScreenUnlockEnabled
                    ? "Authorization prompt fill is ready. Admin prompts require local recognition and fill value only; the separate opt-in lock-screen path can type and press Return only while the session is locked."
                    : "Authorization prompt fill is ready. Admin prompts require local recognition and fill value only; FacePass does not click, submit, or press Return while the session is unlocked."
            )
        case .needsAttention:
            MenuStatus(
                title: "Setup Needed",
                detail: "Authorization prompt fill needs Accessibility permission and a configured Keychain password."
            )
        }
    }

    public func refreshPermissions() {
        permissionStatuses = permissionStatusProvider.currentPermissionStatuses()
        updateManualFillHotkeyEnabledState()
    }

    @discardableResult
    public func requestCameraPermission() async -> PermissionAuthorization {
        let currentStatus = cameraPermissionProvider.cameraAuthorizationStatus()
        let requestedStatus = currentStatus == .notDetermined
            ? await cameraPermissionProvider.requestCameraAuthorization()
            : currentStatus
        let authorization = requestedStatus.permissionAuthorization
        replacePermissionStatus(.camera(authorization))
        return authorization
    }

    public func refreshPasswordConfigurationStatus() {
        passwordSettingsController.refreshStatus()
        passwordConfigurationState = passwordSettingsController.state
        updateManualFillHotkeyEnabledState()
    }

    @discardableResult
    public func preflightKeychainPasswordAccess() -> KeychainPasswordPreflightStatus {
        let result = passwordSettingsController.preflightKeychainPasswordAccess()
        passwordConfigurationState = passwordSettingsController.state
        updateManualFillHotkeyEnabledState()
        return result
    }

    public func savePassword(_ password: String) throws {
        try passwordSettingsController.savePassword(password)
        passwordConfigurationState = passwordSettingsController.state
        updateManualFillHotkeyEnabledState()
    }

    public func deletePassword() throws {
        try passwordSettingsController.deletePassword()
        passwordConfigurationState = passwordSettingsController.state
        updateManualFillHotkeyEnabledState()
    }

    public func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    public func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else {
            return
        }

        self.isEnabled = isEnabled
        updateManualFillHotkeyEnabledState()
    }

    public func setLockScreenUnlockEnabled(_ isEnabled: Bool) {
        guard self.isLockScreenUnlockEnabled != isEnabled else {
            return
        }

        self.isLockScreenUnlockEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: Self.lockScreenUnlockEnabledDefaultsKey)
    }

    public func setAutomaticAuthorizationPromptFillEnabled(_ isEnabled: Bool) {
        updateAutomationConditionSettings { settings in
            settings.isAutomaticAuthorizationPromptFillEnabled = isEnabled
        }
    }

    public func setAutomationConditionGateEnabled(_ isEnabled: Bool) {
        updateAutomationConditionSettings { settings in
            settings.isConditionGateEnabled = isEnabled
        }
    }

    public func setAutomationConditionMatchMode(_ matchMode: AutomationConditionMatchMode) {
        updateAutomationConditionSettings { settings in
            settings.matchMode = matchMode
        }
    }

    public func setAutomationRequiresWiFiConnected(_ isRequired: Bool) {
        updateAutomationConditionSettings { settings in
            settings.requiresWiFiConnected = isRequired
        }
    }

    public func setAutomationRequiresExternalDisplayConnected(_ isRequired: Bool) {
        updateAutomationConditionSettings { settings in
            settings.requiresExternalDisplayConnected = isRequired
        }
    }

    public func setAutomationPowerState(_ powerState: PowerState, enabled: Bool) {
        updateAutomationConditionSettings { settings in
            if enabled {
                settings.allowedPowerStates.insert(powerState)
            } else {
                settings.allowedPowerStates.remove(powerState)
            }
        }
    }

    public func setAutomationAllowedPowerStates(_ powerStates: Set<PowerState>) {
        updateAutomationConditionSettings { settings in
            settings.allowedPowerStates = powerStates
        }
    }

    public func refreshAutomationConditionEvaluation() {
        lastAutomationConditionEvaluation = automationConditionEvaluator.evaluate(
            settings: automationConditionSettings
        )
    }

    public func setAuthorizationPromptMonitorActive(_ isActive: Bool) {
        guard isAuthorizationPromptMonitorActive != isActive else {
            return
        }

        isAuthorizationPromptMonitorActive = isActive
    }

    public func setAutomaticLockScreenOverlayPresenter(
        _ presenter: (any AutomaticLockScreenOverlayPresenting)?
    ) {
        automaticLockScreenOverlayPresenter = presenter
    }

    @MainActor
    public func previewRecognitionOverlay() {
        recognitionPreviewGeneration &+= 1
        let generation = recognitionPreviewGeneration
        automaticLockScreenOverlayGeneration &+= 1
        automaticLockScreenOverlayPresenter?.showRecognitionPreviewScanning()

        screenStateEventScheduler.schedule(after: Self.recognitionPreviewStepDelay) {
            Task { @MainActor [weak self] in
                guard let self, self.recognitionPreviewGeneration == generation else {
                    return
                }

                self.automaticLockScreenOverlayGeneration &+= 1
                self.automaticLockScreenOverlayPresenter?.showRecognitionPreviewRecognized()
            }
        }

        screenStateEventScheduler.schedule(after: Self.recognitionPreviewDismissDelay) {
            Task { @MainActor [weak self] in
                guard let self, self.recognitionPreviewGeneration == generation else {
                    return
                }

                self.dismissRecognitionPreviewOverlay()
            }
        }
    }

    @MainActor
    public func previewRecognitionFailureOverlay() {
        recognitionPreviewGeneration &+= 1
        let generation = recognitionPreviewGeneration
        automaticLockScreenOverlayGeneration &+= 1
        automaticLockScreenOverlayPresenter?.showRecognitionPreviewFailure()

        screenStateEventScheduler.schedule(after: Self.recognitionPreviewDismissDelay) {
            Task { @MainActor [weak self] in
                guard let self, self.recognitionPreviewGeneration == generation else {
                    return
                }

                self.dismissRecognitionPreviewOverlay()
            }
        }
    }

    @MainActor
    public func dismissRecognitionPreviewOverlay() {
        recognitionPreviewGeneration &+= 1
        automaticLockScreenOverlayGeneration &+= 1
        automaticLockScreenOverlayPresenter?.dismiss()
    }

    public func setRecognitionModelPath(_ path: String) {
        recognitionRuntimeController.setModelPath(path)
        recognitionRuntimeState = recognitionRuntimeController.state
    }

    public func clearRecognitionEnrollmentSamples() {
        recognitionRuntimeController.clearCapturedEnrollmentSamples()
        recognitionRuntimeState = recognitionRuntimeController.state
    }

    public func captureRecognitionEnrollmentSample() async {
        await recognitionRuntimeController.captureEnrollmentSample()
        recognitionRuntimeState = recognitionRuntimeController.state
    }

    public func saveRecognitionEnrollment() async {
        await recognitionRuntimeController.saveEnrollment()
        recognitionRuntimeState = recognitionRuntimeController.state
    }

    public func observeRecognitionOnce() async {
        await recognitionRuntimeController.observeOnce()
        recognitionRuntimeState = recognitionRuntimeController.state
    }

    public func fillFocusedPasswordField() {
        Task { [weak self] in
            await self?.fillFocusedAuthorizationPromptAfterRecognition()
        }
    }

    public func fillFocusedPasswordFieldAfterFaceCheck() async {
        await fillFocusedAuthorizationPromptAfterRecognition()
    }

    @MainActor
    public func handleAuthorizationPromptMonitorTick() async {
        guard isEnabled else {
            publishAuthorizationPromptMonitorStatus(.disabled)
            return
        }

        guard automationConditionSettings.isAutomaticAuthorizationPromptFillEnabled else {
            publishAuthorizationPromptMonitorStatus(.automaticPromptFillDisabled)
            return
        }

        guard !lockScreenStateProvider.isSessionLocked else {
            publishAuthorizationPromptMonitorStatus(.lockedSessionSkipped)
            return
        }

        guard isAccessibilityAuthorized, passwordConfigurationState.isPasswordConfigured else {
            publishAuthorizationPromptMonitorStatus(.setupRequired)
            return
        }

        guard !isAutomaticAuthorizationPromptFillInFlight else {
            publishAuthorizationPromptMonitorStatus(.inFlight)
            return
        }

        guard evaluateAutomationConditionsForAutomaticAction() else {
            publishAuthorizationPromptMonitorStatus(.conditionsNotSatisfied)
            return
        }

        let promptStatus = manualFillController.focusedAuthorizationPromptStatus()
        guard promptStatus == .available else {
            isAutomaticAuthorizationPromptSuppressedUntilPromptClears = false
            publishAuthorizationPromptMonitorStatus(authorizationPromptMonitorStatus(for: promptStatus))
            return
        }

        guard !isAutomaticAuthorizationPromptSuppressedUntilPromptClears else {
            publishAuthorizationPromptMonitorStatus(.suppressedUntilPromptClears)
            return
        }

        isAutomaticAuthorizationPromptSuppressedUntilPromptClears = true
        isAutomaticAuthorizationPromptFillInFlight = true
        defer {
            isAutomaticAuthorizationPromptFillInFlight = false
        }

        publishAutomaticAuthorizationPromptFillResult(nil)
        publishAuthorizationPromptMonitorStatus(.checkingRecognition)
        await fillFocusedAuthorizationPromptAfterRecognition()

        if let result = lastManualFillResult {
            publishAutomaticAuthorizationPromptFillResult(result)
            publishAuthorizationPromptMonitorStatus(.fillResult(result))
        }
    }

    public func handleScreenStateEvent(_ event: ScreenStateEvent) {
        switch event {
        case .didWake:
            guard isEnabled, isLockScreenUnlockEnabled else {
                return
            }

            shouldSuppressScheduledAutomaticLockScreenAttempt = false

            guard !isAutomaticLockScreenAttemptScheduled, !isAutomaticLockScreenAttemptInFlight else {
                return
            }

            isAutomaticLockScreenAttemptScheduled = true
            screenStateEventScheduler.schedule(after: lockScreenWakeDelay) {
                Task { [weak self] in
                    await self?.performScheduledAutomaticLockScreenUnlockAttempt()
                }
            }
        case .userDidLock:
            shouldSuppressScheduledAutomaticLockScreenAttempt = true
        case .didUnlock, .didSleep:
            return
        }
    }

    public func setScreenStateMonitorActive(_ isActive: Bool) {
        guard isScreenStateMonitorActive != isActive else {
            return
        }

        isScreenStateMonitorActive = isActive
    }

    public func startManualFillHotkeyRuntime() {
        refreshPasswordConfigurationStatus()

        guard manualFillHotkeyRegistration == nil else {
            updateManualFillHotkeyEnabledState()
            return
        }

        let registration = hotkeyManager.register(
            manualFillHotkeyDescriptor,
            enabled: isManualFillAvailable
        ) { [weak self] in
            self?.fillFocusedPasswordFieldFromHotkey()
        }
        manualFillHotkeyRegistration = registration
        updateManualFillHotkeyStatus()
    }

    public func stopManualFillHotkeyRuntime() {
        guard let manualFillHotkeyRegistration else {
            return
        }

        hotkeyManager.unregister(manualFillHotkeyRegistration.id)
        self.manualFillHotkeyRegistration = nil
        manualFillHotkeyStatus = ManualFillHotkeyStatus(
            descriptor: manualFillHotkeyDescriptor,
            runtimeRegistrationState: .disabled,
            isEnabled: false
        )
    }

    private var isAccessibilityAuthorized: Bool {
        permissionStatuses.contains { status in
            status.kind == .accessibility && status.authorization == .authorized
        }
    }

    private var isManualFillReady: Bool {
        passwordConfigurationState.isPasswordConfigured && isAccessibilityAuthorized
    }

    @MainActor
    private func performScheduledAutomaticLockScreenUnlockAttempt() async {
        isAutomaticLockScreenAttemptScheduled = false
        defer {
            shouldSuppressScheduledAutomaticLockScreenAttempt = false
        }

        guard !isAutomaticLockScreenAttemptInFlight else {
            return
        }

        guard isEnabled, isLockScreenUnlockEnabled else {
            return
        }

        guard !shouldSuppressScheduledAutomaticLockScreenAttempt else {
            lastAutomaticLockScreenUnlockResult = nil
            lastAutomaticLockScreenAttemptStatus = .suppressedByUserLock
            return
        }

        guard lockScreenStateProvider.isSessionLocked else {
            lastAutomaticLockScreenUnlockResult = .sessionNotLocked
            lastAutomaticLockScreenAttemptStatus = .unlockResult(.sessionNotLocked)
            return
        }

        guard isAccessibilityAuthorized else {
            lastAutomaticLockScreenUnlockResult = .accessibilityPermissionDenied
            lastAutomaticLockScreenAttemptStatus = .unlockResult(.accessibilityPermissionDenied)
            return
        }

        guard passwordConfigurationState.isPasswordConfigured else {
            lastAutomaticLockScreenUnlockResult = .missingPassword
            lastAutomaticLockScreenAttemptStatus = .unlockResult(.missingPassword)
            return
        }

        guard evaluateAutomationConditionsForAutomaticAction() else {
            lastAutomaticLockScreenUnlockResult = nil
            lastAutomaticLockScreenAttemptStatus = .conditionsNotSatisfied
            return
        }

        isAutomaticLockScreenAttemptInFlight = true
        defer {
            isAutomaticLockScreenAttemptInFlight = false
        }

        lastAutomaticLockScreenUnlockResult = nil
        lastAutomaticLockScreenAttemptStatus = .checkingRecognition
        presentAutomaticLockScreenOverlayScanning()

        let recognitionResult = await recognitionRuntimeController.evaluateUnlockRecognition(
            timeout: automaticLockScreenFaceCheckTimeout
        )
        recognitionRuntimeState = recognitionRuntimeController.state

        switch recognitionResult {
        case .accepted:
            replacePermissionStatus(.camera(.authorized))

            guard !shouldSuppressScheduledAutomaticLockScreenAttempt else {
                lastAutomaticLockScreenUnlockResult = nil
                lastAutomaticLockScreenAttemptStatus = .suppressedByUserLock
                dismissAutomaticLockScreenOverlay()
                return
            }

            guard lockScreenStateProvider.isSessionLocked else {
                lastAutomaticLockScreenUnlockResult = .sessionNotLocked
                lastAutomaticLockScreenAttemptStatus = .unlockResult(.sessionNotLocked)
                dismissAutomaticLockScreenOverlay()
                return
            }

            let result = lockScreenUnlockController.attemptUnlock(
                isEnabled: true,
                isAccessibilityTrusted: isLiveAccessibilityAuthorized()
            )
            lastAutomaticLockScreenUnlockResult = result
            lastAutomaticLockScreenAttemptStatus = .unlockResult(result)
            refreshPasswordConfigurationStatus()

            switch result {
            case .typedPasswordAndSubmitted:
                presentAutomaticLockScreenOverlaySuccess()
            case .sessionNotLocked, .disabled:
                dismissAutomaticLockScreenOverlay()
            case .accessibilityPermissionDenied,
                 .missingPassword,
                 .passwordReadFailed,
                 .typingFailed:
                presentAutomaticLockScreenOverlayFailure()
            }
        case let .rejected(reason):
            replacePermissionStatus(
                .camera(cameraPermissionProvider.cameraAuthorizationStatus().permissionAuthorization)
            )
            lastAutomaticLockScreenUnlockResult = nil
            lastAutomaticLockScreenAttemptStatus = automaticLockScreenAttemptStatus(
                forRecognitionRejection: reason
            )

            switch reason {
            case .timedOut:
                presentAutomaticLockScreenOverlayTimeout()
            default:
                presentAutomaticLockScreenOverlayFailure()
            }
        }
    }

    private func fillFocusedPasswordFieldFromHotkey() {
        guard isEnabled else {
            return
        }

        if lockScreenStateProvider.isSessionLocked {
            Task { [weak self] in
                await self?.attemptRecognizedLockScreenUnlockFromHotkey()
            }
            return
        }

        guard isManualFillAvailable else {
            return
        }

        Task { [weak self] in
            await self?.fillFocusedAuthorizationPromptAfterRecognition()
        }
    }

    @MainActor
    private func attemptRecognizedLockScreenUnlockFromHotkey() async {
        refreshPasswordConfigurationStatus()

        guard isEnabled else {
            return
        }

        guard isLockScreenUnlockEnabled else {
            publishHotkeyLockScreenUnlockResult(.disabled)
            return
        }

        guard lockScreenStateProvider.isSessionLocked else {
            publishHotkeyLockScreenUnlockResult(.sessionNotLocked)
            return
        }

        guard isAccessibilityAuthorized else {
            publishHotkeyLockScreenUnlockResult(.accessibilityPermissionDenied)
            return
        }

        guard passwordConfigurationState.isPasswordConfigured else {
            publishHotkeyLockScreenUnlockResult(.missingPassword)
            return
        }

        lastLockScreenUnlockResult = nil
        lastAutomaticLockScreenAttemptStatus = .checkingRecognition
        presentAutomaticLockScreenOverlayScanning()

        let recognitionResult = await recognitionRuntimeController.evaluateUnlockRecognition(
            timeout: automaticLockScreenFaceCheckTimeout
        )
        recognitionRuntimeState = recognitionRuntimeController.state

        switch recognitionResult {
        case .accepted:
            replacePermissionStatus(.camera(.authorized))

            guard lockScreenStateProvider.isSessionLocked else {
                publishHotkeyLockScreenUnlockResult(.sessionNotLocked)
                dismissAutomaticLockScreenOverlay()
                return
            }

            let result = lockScreenUnlockController.attemptUnlock(
                isEnabled: true,
                isAccessibilityTrusted: isLiveAccessibilityAuthorized()
            )
            publishHotkeyLockScreenUnlockResult(result)
            refreshPasswordConfigurationStatus()

            switch result {
            case .typedPasswordAndSubmitted:
                presentAutomaticLockScreenOverlaySuccess()
            case .sessionNotLocked, .disabled:
                dismissAutomaticLockScreenOverlay()
            case .accessibilityPermissionDenied,
                 .missingPassword,
                 .passwordReadFailed,
                 .typingFailed:
                presentAutomaticLockScreenOverlayFailure()
            }
        case let .rejected(reason):
            replacePermissionStatus(
                .camera(cameraPermissionProvider.cameraAuthorizationStatus().permissionAuthorization)
            )
            lastLockScreenUnlockResult = nil
            lastAutomaticLockScreenAttemptStatus = automaticLockScreenAttemptStatus(
                forRecognitionRejection: reason
            )

            switch reason {
            case .timedOut:
                presentAutomaticLockScreenOverlayTimeout()
            default:
                presentAutomaticLockScreenOverlayFailure()
            }
        }
    }

    private func publishHotkeyLockScreenUnlockResult(_ result: LockScreenUnlockResult) {
        lastLockScreenUnlockResult = result
        lastAutomaticLockScreenAttemptStatus = .unlockResult(result)
    }

    private func automaticLockScreenAttemptStatus(
        forRecognitionRejection reason: FaceRecognitionUnlockGateRejectionReason
    ) -> AutomaticLockScreenAttemptStatus {
        switch reason {
        case .cameraPermissionDenied:
            return .cameraPermissionDenied
        case .timedOut:
            return .timedOut
        case .cameraFailed:
            return .cameraFailed
        default:
            return .recognitionRejected
        }
    }

    @MainActor
    private func fillFocusedAuthorizationPromptAfterRecognition() async {
        guard isEnabled else {
            return
        }

        guard passwordConfigurationState.isPasswordConfigured else {
            lastManualFillResult = .missingPassword
            return
        }

        guard isAccessibilityAuthorized else {
            lastManualFillResult = .accessibilityPermissionDenied
            return
        }

        let promptStatus = manualFillController.focusedAuthorizationPromptStatus()
        guard promptStatus == .available else {
            lastManualFillResult = ManualFillResult(promptStatus)
            return
        }

        let recognitionResult = await recognitionRuntimeController.evaluateUnlockRecognition(
            timeout: automaticLockScreenFaceCheckTimeout
        )
        recognitionRuntimeState = recognitionRuntimeController.state

        guard recognitionResult.isAccepted else {
            replacePermissionStatus(
                .camera(cameraPermissionProvider.cameraAuthorizationStatus().permissionAuthorization)
            )
            lastManualFillResult = .recognitionRejected
            return
        }

        replacePermissionStatus(.camera(.authorized))
        let result = manualFillController.fillFocusedAuthorizationPromptPasswordField()
        lastManualFillResult = result
        refreshPasswordConfigurationStatus()
    }

    private func updateAutomationConditionSettings(
        _ update: (inout AutomationConditionSettings) -> Void
    ) {
        var settings = automationConditionSettings
        update(&settings)

        guard settings != automationConditionSettings else {
            return
        }

        automationConditionSettings = settings
        automationConditionSettingsStore.save(settings)
        refreshAutomationConditionEvaluation()
    }

    private func evaluateAutomationConditionsForAutomaticAction() -> Bool {
        let evaluation = automationConditionEvaluator.evaluate(settings: automationConditionSettings)
        publishAutomationConditionEvaluation(evaluation)
        return evaluation.isAllowed
    }

    private func authorizationPromptMonitorStatus(
        for promptStatus: AuthorizationPromptPasswordFieldStatus
    ) -> AuthorizationPromptMonitorStatus {
        switch promptStatus {
        case .available:
            .fillResult(.filled)
        case .accessibilityPermissionDenied:
            .accessibilityPermissionDenied
        case .noFocusedPasswordField:
            .noFocusedAuthorizationPrompt
        case .focusedPasswordFieldUnavailable:
            .focusedAuthorizationPromptUnavailable
        case .multipleApprovedPasswordFields:
            if let diagnosticSummary = manualFillController.authorizationPromptCandidateDiagnosticSummary() {
                .multipleAuthorizationPromptPasswordFieldsDiagnostic(diagnosticSummary)
            } else {
                .multipleAuthorizationPromptPasswordFields
            }
        }
    }

    private func publishAuthorizationPromptMonitorStatus(_ status: AuthorizationPromptMonitorStatus) {
        guard lastAuthorizationPromptMonitorStatus != status else {
            return
        }

        lastAuthorizationPromptMonitorStatus = status
    }

    private func publishAutomaticAuthorizationPromptFillResult(_ result: ManualFillResult?) {
        guard lastAutomaticAuthorizationPromptFillResult != result else {
            return
        }

        lastAutomaticAuthorizationPromptFillResult = result
    }

    private func publishAutomationConditionEvaluation(_ evaluation: AutomationConditionEvaluation) {
        guard lastAutomationConditionEvaluation != evaluation else {
            return
        }

        lastAutomationConditionEvaluation = evaluation
    }

    private func updateManualFillHotkeyEnabledState() {
        guard let manualFillHotkeyRegistration else {
            manualFillHotkeyStatus = ManualFillHotkeyStatus(
                descriptor: manualFillHotkeyDescriptor,
                runtimeRegistrationState: .disabled,
                isEnabled: false
            )
            return
        }

        hotkeyManager.setEnabled(isManualFillAvailable, for: manualFillHotkeyRegistration.id)
        updateManualFillHotkeyStatus()
    }

    private func updateManualFillHotkeyStatus() {
        let runtimeRegistrationState = manualFillHotkeyRegistration
            .flatMap { hotkeyManager.runtimeRegistrationState(for: $0.id) } ?? .disabled
        manualFillHotkeyStatus = ManualFillHotkeyStatus(
            descriptor: manualFillHotkeyDescriptor,
            runtimeRegistrationState: runtimeRegistrationState,
            isEnabled: isManualFillAvailable
        )
    }

    private func isLiveAccessibilityAuthorized() -> Bool {
        let statuses = permissionStatusProvider.currentPermissionStatuses()
        guard let accessibilityStatus = statuses.first(where: { $0.kind == .accessibility }) else {
            return false
        }

        replacePermissionStatus(accessibilityStatus)
        return accessibilityStatus.authorization == .authorized
    }

    private func replacePermissionStatus(_ status: PermissionStatus) {
        if let index = permissionStatuses.firstIndex(where: { $0.kind == status.kind }) {
            permissionStatuses[index] = status
        } else {
            permissionStatuses.append(status)
        }
        updateManualFillHotkeyEnabledState()
    }

    @MainActor
    private func presentAutomaticLockScreenOverlayScanning() {
        automaticLockScreenOverlayGeneration &+= 1
        automaticLockScreenOverlayPresenter?.showScanning()
    }

    @MainActor
    private func presentAutomaticLockScreenOverlaySuccess() {
        automaticLockScreenOverlayGeneration &+= 1
        let generation = automaticLockScreenOverlayGeneration
        automaticLockScreenOverlayPresenter?.showSuccess()
        scheduleAutomaticLockScreenOverlayDismissal(for: generation)
    }

    @MainActor
    private func presentAutomaticLockScreenOverlayFailure() {
        automaticLockScreenOverlayGeneration &+= 1
        let generation = automaticLockScreenOverlayGeneration
        automaticLockScreenOverlayPresenter?.showFailure()
        scheduleAutomaticLockScreenOverlayDismissal(for: generation)
    }

    @MainActor
    private func presentAutomaticLockScreenOverlayTimeout() {
        automaticLockScreenOverlayGeneration &+= 1
        let generation = automaticLockScreenOverlayGeneration
        automaticLockScreenOverlayPresenter?.showTimeout()
        scheduleAutomaticLockScreenOverlayDismissal(for: generation)
    }

    @MainActor
    private func dismissAutomaticLockScreenOverlay() {
        automaticLockScreenOverlayGeneration &+= 1
        automaticLockScreenOverlayPresenter?.dismiss()
    }

    @MainActor
    private func scheduleAutomaticLockScreenOverlayDismissal(for generation: UInt) {
        guard automaticLockScreenOverlayPresenter != nil else {
            return
        }

        screenStateEventScheduler.schedule(after: Self.automaticLockScreenOverlayDismissDelay) {
            Task { @MainActor [weak self] in
                guard let self, self.automaticLockScreenOverlayGeneration == generation else {
                    return
                }

                self.dismissAutomaticLockScreenOverlay()
            }
        }
    }
}

private extension CameraFaceDetectionPermissionStatus {
    var permissionAuthorization: PermissionAuthorization {
        switch self {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        case .unknown:
            .unknown
        }
    }
}

public enum OverallPermissionState: Equatable {
    case ready
    case needsAttention
}

public struct MenuStatus: Equatable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public enum AutomaticLockScreenAttemptStatus: Equatable, CustomStringConvertible {
    case checkingCamera
    case checkingRecognition
    case suppressedByUserLock
    case cameraPermissionDenied
    case timedOut
    case cameraFailed
    case recognitionRejected
    case conditionsNotSatisfied
    case unlockResult(LockScreenUnlockResult)

    public var description: String {
        switch self {
        case .checkingCamera:
            "Lock-screen attempt is opening a short temporary camera window for the local recognition gate."
        case .checkingRecognition:
            "Lock-screen attempt is running a short local recognition check."
        case .suppressedByUserLock:
            "Wake-triggered lock-screen attempt was suppressed after a user lock event."
        case .cameraPermissionDenied:
            "Lock-screen attempt could not use the camera."
        case .timedOut:
            "Lock-screen attempt timed out before recognition completed."
        case .cameraFailed:
            "Lock-screen attempt could not complete the temporary camera check."
        case .recognitionRejected:
            "Lock-screen attempt did not pass local recognition."
        case .conditionsNotSatisfied:
            "Automatic lock-screen attempt did not run because trusted conditions were not satisfied."
        case .unlockResult(let result):
            result.description
        }
    }
}

public enum AuthorizationPromptMonitorStatus: Equatable, CustomStringConvertible {
    case disabled
    case automaticPromptFillDisabled
    case setupRequired
    case lockedSessionSkipped
    case conditionsNotSatisfied
    case noFocusedAuthorizationPrompt
    case focusedAuthorizationPromptUnavailable
    case multipleAuthorizationPromptPasswordFields
    case multipleAuthorizationPromptPasswordFieldsDiagnostic(String)
    case accessibilityPermissionDenied
    case suppressedUntilPromptClears
    case inFlight
    case checkingRecognition
    case fillResult(ManualFillResult)

    public var description: String {
        switch self {
        case .disabled:
            "FacePass is disabled."
        case .automaticPromptFillDisabled:
            "Automatic admin/System Settings prompt handling is off."
        case .setupRequired:
            "Automatic admin/System Settings prompt handling needs Accessibility permission and a configured Keychain password."
        case .lockedSessionSkipped:
            "Automatic admin/System Settings prompt handling skipped a locked session; the lock-screen flow remains separate."
        case .conditionsNotSatisfied:
            "Automatic admin/System Settings prompt handling did not run because trusted conditions were not satisfied."
        case .noFocusedAuthorizationPrompt:
            "No approved macOS administrator/System Settings authorization prompt was found."
        case .focusedAuthorizationPromptUnavailable:
            "The approved authorization prompt password field is unavailable."
        case .multipleAuthorizationPromptPasswordFields:
            "Multiple approved authorization prompt password fields were found; FacePass did not fill."
        case .multipleAuthorizationPromptPasswordFieldsDiagnostic(let diagnosticSummary):
            "Multiple approved authorization prompt password fields were found; FacePass did not fill. Diagnostic: \(diagnosticSummary)"
        case .accessibilityPermissionDenied:
            "Accessibility permission is required before monitoring authorization prompts."
        case .suppressedUntilPromptClears:
            "Automatic prompt handling is waiting for the current approved prompt to clear before trying again."
        case .inFlight:
            "Automatic prompt handling is already running."
        case .checkingRecognition:
            "Automatic prompt handling is running local FacePass recognition."
        case .fillResult(let result):
            result.description
        }
    }
}

public struct ManualFillHotkeyStatus: Equatable {
    public let descriptor: HotkeyDescriptor
    public let runtimeRegistrationState: HotkeyRuntimeRegistrationState
    public let isEnabled: Bool

    public var displayName: String {
        descriptor.displayName
    }

    public init(
        descriptor: HotkeyDescriptor,
        runtimeRegistrationState: HotkeyRuntimeRegistrationState,
        isEnabled: Bool
    ) {
        self.descriptor = descriptor
        self.runtimeRegistrationState = runtimeRegistrationState
        self.isEnabled = isEnabled
    }
}

private final class MainQueueUnlockScheduler: UnlockScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: action)
    }
}
