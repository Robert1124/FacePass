import CoreGraphics
import Combine
import XCTest
@testable import FacePassCore

final class AppStateManagerTests: XCTestCase {
    func testInitializesWithPermissionStatusesFromProvider() {
        let provider = StubPermissionStatusProvider(statuses: [
            .camera(.authorized),
            .accessibility(.denied),
            .keychain(.available)
        ])

        let manager = AppStateManager(permissionStatusProvider: provider)

        XCTAssertEqual(manager.permissionStatuses, [
            .camera(.authorized),
            .accessibility(.denied),
            .keychain(.available)
        ])
        XCTAssertEqual(manager.overallPermissionState, .needsAttention)
    }

    func testRefreshPermissionsReloadsProviderStatuses() {
        let provider = MutablePermissionStatusProvider(statuses: [
            .camera(.notDetermined),
            .accessibility(.notDetermined),
            .keychain(.available)
        ])
        let manager = AppStateManager(
            permissionStatusProvider: provider,
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        provider.statuses = [
            .camera(.authorized),
            .accessibility(.authorized),
            .keychain(.available)
        ]
        manager.refreshPermissions()

        XCTAssertEqual(manager.permissionStatuses, [
            .camera(.authorized),
            .accessibility(.authorized),
            .keychain(.available)
        ])
        XCTAssertEqual(manager.overallPermissionState, .ready)
    }

    func testMenuStatusReflectsManualFillReadinessWithoutCameraBlockingMVP() {
        let readyDefaults = makeIsolatedUserDefaults()
        let blockedDefaults = makeIsolatedUserDefaults()
        let readyManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [
                .camera(.denied),
                .accessibility(.authorized),
                .keychain(.available)
            ]),
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            userDefaults: readyDefaults.defaults
        )
        let blockedManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [
                .camera(.authorized),
                .accessibility(.denied),
                .keychain(.available)
            ]),
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            userDefaults: blockedDefaults.defaults
        )

        XCTAssertEqual(readyManager.overallPermissionState, .ready)
        XCTAssertEqual(readyManager.menuStatus.title, "Authorization Fill Ready")
        XCTAssertEqual(
            readyManager.menuStatus.detail,
            "Authorization prompt fill is ready. Admin prompts require local recognition and fill value only; FacePass does not click, submit, or press Return while the session is unlocked."
        )
        XCTAssertEqual(blockedManager.menuStatus.title, "Setup Needed")
        XCTAssertEqual(blockedManager.menuStatus.detail, "Authorization prompt fill needs Accessibility permission and a configured Keychain password.")
    }

    func testManualFillReadinessRequiresConfiguredPasswordEvenWhenPermissionsAreGranted() {
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [
                .camera(.authorized),
                .accessibility(.authorized),
                .keychain(.available)
            ]),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        XCTAssertEqual(manager.overallPermissionState, .needsAttention)
        XCTAssertFalse(manager.isManualFillAvailable)
    }

    func testPermissionPurposeTextReflectsCurrentServiceLayerWithoutRuntimeWiring() {
        XCTAssertEqual(
            PermissionKind.camera.purpose,
            "Used only for short local FacePass recognition, enrollment, approved admin/System Settings prompt fill, and opt-in wake-triggered lock-screen checks. FacePass does not keep the camera running or save raw frames or photos."
        )
        XCTAssertEqual(
            PermissionKind.accessibility.purpose,
            "Used to inspect approved macOS administrator/System Settings authorization password prompts and set the saved value only. It does not click, submit, or press Return in unlocked prompts."
        )
        XCTAssertEqual(
            PermissionKind.keychain.purpose,
            "Stores the configured password in Keychain without showing it in the app UI. The user-triggered preflight reads it only to verify access and discards it immediately."
        )
    }

    func testSystemProviderIncludesKeychainPlaceholderWithoutSecrets() {
        let statuses = SystemPermissionStatusProvider().currentPermissionStatuses()

        XCTAssertTrue(statuses.contains(.keychain(.available)))
    }

    func testInitializesWithPasswordConfiguredStatusWithoutExposingSecret() {
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)

        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        XCTAssertTrue(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertNil(manager.passwordConfigurationState.passwordPreview)
        XCTAssertFalse(String(describing: manager.passwordConfigurationState).contains(password))
    }

    func testSavePasswordUpdatesConfiguredStatusWithoutExposingSecret() throws {
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        try manager.savePassword(password)

        XCTAssertTrue(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertNil(manager.passwordConfigurationState.passwordPreview)
        XCTAssertFalse(String(describing: manager.passwordConfigurationState).contains(password))
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: defaultPasswordAccountIdentifier),
            .savedPassword(account: defaultPasswordAccountIdentifier, passwordLength: password.count),
            .checkedPassword(account: defaultPasswordAccountIdentifier)
        ])
    }

    func testPreflightKeychainPasswordAccessReadsAndDiscardsConfiguredPasswordWithoutExposingSecret() {
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        let result = manager.preflightKeychainPasswordAccess()

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(manager.passwordConfigurationState.keychainPreflightStatus, .verified)
        XCTAssertTrue(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertFalse(String(describing: result).contains(password))
        XCTAssertFalse(String(describing: manager.passwordConfigurationState).contains(password))
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: defaultPasswordAccountIdentifier),
            .readPassword(account: defaultPasswordAccountIdentifier)
        ])
    }

    func testDeletePasswordUpdatesConfiguredStatusWithoutExposingSecret() throws {
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        try manager.deletePassword()

        XCTAssertFalse(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertNil(manager.passwordConfigurationState.passwordPreview)
        XCTAssertFalse(String(describing: manager.passwordConfigurationState).contains(password))
        XCTAssertEqual(vault.events, [
            .checkedPassword(account: defaultPasswordAccountIdentifier),
            .deletedPassword(account: defaultPasswordAccountIdentifier),
            .checkedPassword(account: defaultPasswordAccountIdentifier)
        ])
    }

    func testManualFillActionPublishesResultAndRefreshesPasswordStatusWithoutUsingLockScreenTyper() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let typer = RecordingLockScreenPasswordTyper()
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(manager.lastManualFillResult, .filled)
        XCTAssertNil(manager.lastLockScreenUnlockResult)
        XCTAssertTrue(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertEqual(autofill.fillEvents, [
            .checkedAuthorizationPrompt,
            .checkedAuthorizationPrompt,
            .fillAuthorizationValueOnly(passwordLength: password.count)
        ])
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testLockScreenOptInPersistsToInjectedUserDefaultsWithoutPasswordMaterial() {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let userDefaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName
        let secret = "app-state-secret-\(UUID().uuidString)"

        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: secret),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            userDefaults: userDefaults
        )

        manager.setLockScreenUnlockEnabled(true)

        XCTAssertTrue(manager.isLockScreenUnlockEnabled)
        XCTAssertEqual(
            userDefaults.object(forKey: "FacePass.lockScreenUnlockEnabled") as? Bool,
            true
        )
        XCTAssertFalse(
            userDefaults
                .persistentDomain(forName: suiteName)?
                .values
                .contains { String(describing: $0).contains(secret) } ?? false
        )

        let reloadedManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: secret),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            userDefaults: userDefaults
        )
        XCTAssertTrue(reloadedManager.isLockScreenUnlockEnabled)
    }

    @MainActor
    func testDidWakeWithOptInAndLockedSessionRunsRecognitionThenTypesPassword() async throws {
        let delay = 1.5
        let isolatedDefaults = makeIsolatedUserDefaults()
        let scheduler = RecordingAppStateUnlockScheduler()
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            screenStateEventScheduler: scheduler,
            lockScreenWakeDelay: delay,
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.setLockScreenUnlockEnabled(true)
        manager.handleScreenStateEvent(.didWake)

        XCTAssertEqual(scheduler.scheduledDelays, [delay])
        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])

        scheduler.runNext()
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .unlockResult(.typedPasswordAndSubmitted)
        }

        XCTAssertEqual(manager.lastAutomaticLockScreenUnlockResult, .typedPasswordAndSubmitted)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .unlockResult(.typedPasswordAndSubmitted))
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            1
        )
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertEqual(typer.events, [.typedPasswordAndSubmit(passwordLength: password.count)])
        XCTAssertTrue(typer.didReceiveExpectedPassword(password))
        XCTAssertEqual(overlay.recordedEvents(), [.scanning, .success])
    }

    @MainActor
    func testDidWakeRechecksLiveAccessibilityAfterRecognitionBeforeReadingOrTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let scheduler = RecordingAppStateUnlockScheduler()
        let provider = SequencePermissionStatusProvider(statusSets: [
            [.accessibility(.authorized)],
            [.accessibility(.denied)]
        ])
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let capture = QueueAppStateRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(
                sample: try makeRecognitionSample(),
                processedFrameCount: 1
            )),
            .captured(FaceSampleCaptureSummary(
                sample: try makeRecognitionSample(),
                processedFrameCount: 1
            ))
        ])
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: provider,
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            screenStateEventScheduler: scheduler,
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.setLockScreenUnlockEnabled(true)
        manager.handleScreenStateEvent(.didWake)
        scheduler.runNext()
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .unlockResult(.accessibilityPermissionDenied)
        }

        XCTAssertEqual(manager.lastAutomaticLockScreenUnlockResult, .accessibilityPermissionDenied)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .unlockResult(.accessibilityPermissionDenied))
        XCTAssertEqual(capture.requestedTimeouts, [10, 10])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [.scanning, .failure])
    }

    @MainActor
    func testDidWakeWithOptOutDoesNotScheduleReadTypeCameraOrOverlay() {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            screenStateEventScheduler: scheduler,
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.handleScreenStateEvent(.didWake)

        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])
    }

    @MainActor
    func testRecognitionOverlayPreviewUsesOnlyPresenterAndScheduler() async {
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            screenStateEventScheduler: scheduler
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.previewRecognitionOverlay()

        XCTAssertEqual(overlay.recordedEvents(), [.recognitionPreviewScanning])
        XCTAssertEqual(scheduler.scheduledDelays, [0.9, 2.4])
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertNil(manager.lastLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)

        scheduler.runNext()
        await waitUntil {
            overlay.recordedEvents() == [.recognitionPreviewScanning, .recognitionPreviewRecognized]
        }
        XCTAssertEqual(overlay.recordedEvents(), [.recognitionPreviewScanning, .recognitionPreviewRecognized])

        scheduler.runNext()
        await waitUntil {
            overlay.recordedEvents() == [
                .recognitionPreviewScanning,
                .recognitionPreviewRecognized,
                .dismiss
            ]
        }
        XCTAssertEqual(overlay.recordedEvents(), [
            .recognitionPreviewScanning,
            .recognitionPreviewRecognized,
            .dismiss
        ])
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
    }

    @MainActor
    func testRecognitionFailurePreviewUsesOnlyPresenterAndScheduler() async {
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            screenStateEventScheduler: scheduler
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.previewRecognitionFailureOverlay()

        XCTAssertEqual(overlay.recordedEvents(), [.recognitionPreviewFailure])
        XCTAssertEqual(scheduler.scheduledDelays, [2.4])
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)

        scheduler.runNext()
        await waitUntil {
            overlay.recordedEvents() == [.recognitionPreviewFailure, .dismiss]
        }
        XCTAssertEqual(overlay.recordedEvents(), [.recognitionPreviewFailure, .dismiss])
    }

    @MainActor
    func testDidWakeWithUnlockedSessionSkipsCameraAndReportsSessionNotLocked() async {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            lockScreenPasswordTyper: typer,
            screenStateEventScheduler: scheduler,
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.setLockScreenUnlockEnabled(true)
        manager.handleScreenStateEvent(.didWake)

        XCTAssertEqual(scheduler.scheduledDelays, [1])
        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])

        scheduler.runNext()
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .unlockResult(.sessionNotLocked)
        }

        XCTAssertEqual(manager.lastAutomaticLockScreenUnlockResult, .sessionNotLocked)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .unlockResult(.sessionNotLocked))
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])
    }

    @MainActor
    func testDidWakeRecognitionFailuresDoNotReadOrTypeAndReportNonSensitiveStatus() async throws {
        let cases: [
            (
                name: String,
                captureResult: FaceSampleCaptureResult,
                observeError: Error?,
                cameraStatus: CameraFaceDetectionPermissionStatus,
                expectedStatus: AutomaticLockScreenAttemptStatus,
                expectedOverlayEvents: [RecordingAutomaticLockScreenOverlayPresenter.Event]
            )
        ] = [
            (
                name: "permission denied",
                captureResult: .permissionDenied,
                observeError: nil,
                cameraStatus: .denied,
                expectedStatus: .cameraPermissionDenied,
                expectedOverlayEvents: [.scanning, .failure]
            ),
            (
                name: "timed out",
                captureResult: .timedOut,
                observeError: nil,
                cameraStatus: .authorized,
                expectedStatus: .timedOut,
                expectedOverlayEvents: [.scanning, .timeout]
            ),
            (
                name: "missing template",
                captureResult: .captured(FaceSampleCaptureSummary(
                    sample: try makeRecognitionSample(),
                    processedFrameCount: 1
                )),
                observeError: FaceRecognitionRuntimeWorkflowError.noTemplate,
                cameraStatus: .authorized,
                expectedStatus: .recognitionRejected,
                expectedOverlayEvents: [.scanning, .failure]
            ),
            (
                name: "camera failure",
                captureResult: .failed(.captureFailed),
                observeError: nil,
                cameraStatus: .authorized,
                expectedStatus: .cameraFailed,
                expectedOverlayEvents: [.scanning, .failure]
            )
        ]

        for testCase in cases {
            let isolatedDefaults = makeIsolatedUserDefaults()
            let scheduler = RecordingAppStateUnlockScheduler()
            let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
            let typer = RecordingLockScreenPasswordTyper()
            let detector = RecordingFacePresenceDetector(
                result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
            )
            let recognition = try makeRecognitionController(
                userDefaults: isolatedDefaults.defaults,
                captureResult: testCase.captureResult,
                observeError: testCase.observeError
            )
            let overlay = RecordingAutomaticLockScreenOverlayPresenter()
            let manager = AppStateManager(
                permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
                passwordVault: vault,
                autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
                facePresenceDetector: detector,
                cameraPermissionProvider: StubCameraPermissionProvider(
                    currentStatus: testCase.cameraStatus,
                    requestedStatus: testCase.cameraStatus
                ),
                lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
                lockScreenPasswordTyper: typer,
                recognitionRuntimeController: recognition,
                screenStateEventScheduler: scheduler,
                userDefaults: isolatedDefaults.defaults
            )
            manager.setAutomaticLockScreenOverlayPresenter(overlay)

            manager.setLockScreenUnlockEnabled(true)
            manager.handleScreenStateEvent(.didWake)

            XCTAssertEqual(scheduler.scheduledDelays, [1], testCase.name)
            XCTAssertFalse(
                vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)),
                testCase.name
            )
            XCTAssertEqual(detector.requestedTimeouts, [], testCase.name)
            XCTAssertEqual(overlay.recordedEvents(), [], testCase.name)

            scheduler.runNext()
            await waitUntil {
                manager.lastAutomaticLockScreenAttemptStatus == testCase.expectedStatus
            }

            XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult, testCase.name)
            XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, testCase.expectedStatus, testCase.name)
            XCTAssertFalse(
                vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)),
                testCase.name
            )
            XCTAssertTrue(typer.events.isEmpty, testCase.name)
            XCTAssertEqual(detector.requestedTimeouts, [], testCase.name)
            XCTAssertEqual(overlay.recordedEvents(), testCase.expectedOverlayEvents, testCase.name)
            XCTAssertFalse(testCase.expectedStatus.description.contains("app-state-secret"), testCase.name)
        }
    }

    @MainActor
    func testDidWakeMissingRecognitionModelDoesNotReadOrType() async {
        let isolatedDefaults = makeIsolatedUserDefaults()
        isolatedDefaults.defaults.removeObject(forKey: FaceRecognitionRuntimeController.modelPathDefaultsKey)
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let recognition = FaceRecognitionRuntimeController(
            sampleCaptureService: QueueAppStateRecognitionSampleCapture(result: .timedOut),
            workflowFactory: RecordingAppStateRecognitionWorkflowFactory(
                workflow: RecordingAppStateRecognitionWorkflow(
                    observation: FaceRecognitionObservation(
                        bestSimilarity: 0.72,
                        modelVersion: "app-state-test-model",
                        dimension: 3,
                        comparedTemplateCount: 1,
                        frame: .usable(FaceRecognitionMatchScore(
                            similarity: 0.72,
                            modelVersion: "app-state-test-model"
                        ))
                    ),
                    observeError: nil
                )
            ),
            bundledModelURLProvider: FixedAppStateBundledModelURLProvider(url: nil),
            userDefaults: isolatedDefaults.defaults
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            cameraPermissionProvider: StubCameraPermissionProvider(
                currentStatus: .authorized,
                requestedStatus: .authorized
            ),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            screenStateEventScheduler: scheduler,
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.setLockScreenUnlockEnabled(true)
        manager.handleScreenStateEvent(.didWake)
        scheduler.runNext()
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .recognitionRejected
        }

        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertEqual(overlay.recordedEvents(), [.scanning, .failure])
        XCTAssertFalse(manager.lastAutomaticLockScreenAttemptStatus?.description.contains("app-state-secret") ?? true)
    }

    @MainActor
    func testUserDidLockDoesNotImmediatelyUnlockAndSuppressesPendingWakeAttempt() async {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            screenStateEventScheduler: scheduler,
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)

        manager.setLockScreenUnlockEnabled(true)
        manager.handleScreenStateEvent(.userDidLock)

        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])

        manager.handleScreenStateEvent(.didWake)
        manager.handleScreenStateEvent(.userDidLock)

        XCTAssertEqual(scheduler.scheduledDelays, [1])
        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])

        scheduler.runNext()
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .suppressedByUserLock
        }

        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .suppressedByUserLock)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])
    }

    func testEnabledStateDefaultsOnAndToggles() {
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled)
        )

        XCTAssertTrue(manager.isEnabled)

        manager.toggleEnabled()

        XCTAssertFalse(manager.isEnabled)

        manager.setEnabled(true)

        XCTAssertTrue(manager.isEnabled)
    }

    func testScreenStateMonitorActiveStatusCanBeUpdatedWithoutRunningSensitiveFlows() {
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled)
        )

        XCTAssertFalse(manager.isScreenStateMonitorActive)

        manager.setScreenStateMonitorActive(true)
        XCTAssertTrue(manager.isScreenStateMonitorActive)

        manager.setScreenStateMonitorActive(false)
        XCTAssertFalse(manager.isScreenStateMonitorActive)
    }

    func testManualFillDoesNotRunWhenAppIsDisabled() {
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        manager.setEnabled(false)
        manager.fillFocusedPasswordField()

        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testUnlockedAuthorizationFillRunsRecognitionBeforeReadingPassword() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(manager.lastManualFillResult, .filled)
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            1
        )
        XCTAssertEqual(autofill.fillEvents, [
            .checkedAuthorizationPrompt,
            .checkedAuthorizationPrompt,
            .fillAuthorizationValueOnly(passwordLength: password.count)
        ])
    }

    func testUnlockedAuthorizationFillRejectsOrdinarySecureFieldsWithoutRecognitionOrPasswordRead() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .noFocusedPasswordField,
            result: .filled
        )
        let capture = QueueAppStateRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(
                sample: try makeRecognitionSample(),
                processedFrameCount: 1
            )),
            .captured(FaceSampleCaptureSummary(
                sample: try makeRecognitionSample(),
                processedFrameCount: 1
            ))
        ])
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(manager.lastManualFillResult, .noFocusedPasswordField)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertEqual(autofill.fillEvents, [.checkedAuthorizationPrompt])
    }

    func testUnlockedAuthorizationFillRecognitionFailureDoesNotReadOrFill() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .timedOut
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            cameraPermissionProvider: StubCameraPermissionProvider(
                currentStatus: .authorized,
                requestedStatus: .authorized
            ),
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(manager.lastManualFillResult, .recognitionRejected)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(autofill.fillEvents, [.checkedAuthorizationPrompt])
    }

    func testUnlockedAuthorizationFillDoesNotStartRecognitionWhenAccessibilityIsMissing() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.denied)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(manager.lastManualFillResult, .accessibilityPermissionDenied)
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testUnlockedAuthorizationFillDoesNotStartRecognitionWhenPasswordIsMissing() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(manager.lastManualFillResult, .missingPassword)
        XCTAssertEqual(capture.requestedTimeouts, [])
    }

    func testAutomaticAuthorizationPromptTickChecksPromptBeforeRecognitionAndPasswordRead() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .noFocusedPasswordField,
            result: .filled
        )
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )

        await manager.handleAuthorizationPromptMonitorTick()

        XCTAssertNil(manager.lastAutomaticAuthorizationPromptFillResult)
        XCTAssertEqual(manager.lastAuthorizationPromptMonitorStatus, .noFocusedAuthorizationPrompt)
        XCTAssertEqual(autofill.fillEvents, [.checkedAuthorizationPrompt])
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    @MainActor
    func testAutomaticAuthorizationPromptTickDoesNotRepublishUnchangedPromptStatus() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .noFocusedPasswordField,
            result: .filled
        )
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )
        var publishedStatuses: [AuthorizationPromptMonitorStatus?] = []
        let cancellable = manager.$lastAuthorizationPromptMonitorStatus
            .dropFirst()
            .sink { publishedStatuses.append($0) }

        await manager.handleAuthorizationPromptMonitorTick()
        await manager.handleAuthorizationPromptMonitorTick()

        XCTAssertEqual(publishedStatuses, [.noFocusedAuthorizationPrompt])
        XCTAssertEqual(autofill.fillEvents, [.checkedAuthorizationPrompt, .checkedAuthorizationPrompt])
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        _ = cancellable
    }

    func testAutomaticAuthorizationPromptTickReportsMultipleApprovedFieldsWithoutRecognitionOrPasswordRead() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .multipleApprovedPasswordFields,
            result: .filled
        )
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )

        await manager.handleAuthorizationPromptMonitorTick()

        XCTAssertNil(manager.lastAutomaticAuthorizationPromptFillResult)
        XCTAssertEqual(manager.lastAuthorizationPromptMonitorStatus, .multipleAuthorizationPromptPasswordFields)
        XCTAssertEqual(autofill.fillEvents, [.checkedAuthorizationPrompt])
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testAutomaticAuthorizationPromptTickFillsOnceThenSuppressesUntilPromptClears() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let capture = QueueAppStateRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeRecognitionSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeRecognitionSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeRecognitionSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeRecognitionSample(), processedFrameCount: 1))
        ])
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )

        await manager.handleAuthorizationPromptMonitorTick()
        XCTAssertEqual(manager.lastAutomaticAuthorizationPromptFillResult, .filled)
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            1
        )
        XCTAssertEqual(capture.requestedTimeouts, [10, 10])
        XCTAssertEqual(autofill.fillEvents, [
            .checkedAuthorizationPrompt,
            .checkedAuthorizationPrompt,
            .checkedAuthorizationPrompt,
            .fillAuthorizationValueOnly(passwordLength: password.count)
        ])

        await manager.handleAuthorizationPromptMonitorTick()
        XCTAssertEqual(manager.lastAuthorizationPromptMonitorStatus, .suppressedUntilPromptClears)
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            1
        )
        XCTAssertEqual(capture.requestedTimeouts, [10, 10])

        autofill.setFocusedStatus(.noFocusedPasswordField)
        await manager.handleAuthorizationPromptMonitorTick()
        XCTAssertEqual(manager.lastAuthorizationPromptMonitorStatus, .noFocusedAuthorizationPrompt)

        autofill.setFocusedStatus(.available)
        await manager.handleAuthorizationPromptMonitorTick()

        XCTAssertEqual(manager.lastAutomaticAuthorizationPromptFillResult, .filled)
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            2
        )
        XCTAssertEqual(capture.requestedTimeouts, [10, 10, 10, 10])
    }

    func testAutomaticAuthorizationPromptTickSkipsLockedSessionWithoutPromptCheck() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            recognitionRuntimeController: recognition,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )

        await manager.handleAuthorizationPromptMonitorTick()

        XCTAssertNil(manager.lastAutomaticAuthorizationPromptFillResult)
        XCTAssertEqual(manager.lastAuthorizationPromptMonitorStatus, .lockedSessionSkipped)
        XCTAssertTrue(autofill.fillEvents.isEmpty)
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testAutomaticAuthorizationPromptTickRespectsEnabledConditionGateBeforePromptCheck() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: ConditionSignalSnapshot(
                wifi: .unavailable,
                externalDisplays: .connected([]),
                power: .available(.battery),
                bluetooth: .inconclusive
            )),
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomationConditionGateEnabled(true)
        manager.setAutomationRequiresWiFiConnected(true)

        await manager.handleAuthorizationPromptMonitorTick()

        XCTAssertNil(manager.lastAutomaticAuthorizationPromptFillResult)
        XCTAssertEqual(manager.lastAuthorizationPromptMonitorStatus, .conditionsNotSatisfied)
        XCTAssertEqual(manager.lastAutomationConditionEvaluation?.isAllowed, false)
        XCTAssertTrue(autofill.fillEvents.isEmpty)
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    @MainActor
    func testWakeTriggeredLockScreenAttemptRespectsEnabledConditionGateBeforeRecognition() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let scheduler = RecordingAppStateUnlockScheduler()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let detector = RecordingFacePresenceDetector(
            result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1))
        )
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let overlay = RecordingAutomaticLockScreenOverlayPresenter()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            screenStateEventScheduler: scheduler,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: ConditionSignalSnapshot(
                wifi: .unavailable,
                externalDisplays: .connected([]),
                power: .available(.battery),
                bluetooth: .inconclusive
            )),
            userDefaults: isolatedDefaults.defaults
        )
        manager.setAutomaticLockScreenOverlayPresenter(overlay)
        manager.setAutomationConditionGateEnabled(true)
        manager.setAutomationRequiresWiFiConnected(true)

        manager.setLockScreenUnlockEnabled(true)
        manager.handleScreenStateEvent(.didWake)
        scheduler.runNext()
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .conditionsNotSatisfied
        }

        XCTAssertNil(manager.lastAutomaticLockScreenUnlockResult)
        XCTAssertEqual(manager.lastAutomationConditionEvaluation?.isAllowed, false)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(overlay.recordedEvents(), [])
    }

    func testFacePresenceFillDoesNotStartCameraWhenAppIsDisabled() async {
        let detector = RecordingFacePresenceDetector(result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            facePresenceDetector: detector
        )

        manager.setEnabled(false)
        await manager.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertNil(manager.lastFacePresenceFillResult)
        XCTAssertEqual(detector.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testManualFillAvailabilityRequiresConfiguredPasswordAndAuthorizedAccessibility() {
        let availableManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )
        let missingPasswordManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )
        let deniedAccessibilityManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.denied)]),
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )
        let missingAccessibilityStatusManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        XCTAssertTrue(availableManager.isManualFillAvailable)
        XCTAssertFalse(missingPasswordManager.isManualFillAvailable)
        XCTAssertFalse(deniedAccessibilityManager.isManualFillAvailable)
        XCTAssertFalse(missingAccessibilityStatusManager.isManualFillAvailable)
    }

    func testManualFillAvailabilityRefreshesWithPermissionsAndPasswordStatus() throws {
        let provider = MutablePermissionStatusProvider(statuses: [.accessibility(.denied)])
        let vault = SpyPasswordVault()
        let manager = AppStateManager(
            permissionStatusProvider: provider,
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        )

        XCTAssertFalse(manager.isManualFillAvailable)

        provider.statuses = [.accessibility(.authorized)]
        manager.refreshPermissions()
        XCTAssertFalse(manager.isManualFillAvailable)

        try manager.savePassword("app-state-secret-\(UUID().uuidString)")
        XCTAssertTrue(manager.isManualFillAvailable)
    }

    func testManualFillHotkeyRuntimeRegistersDefaultShortcutWhenManualFillIsAvailable() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.startManualFillHotkeyRuntime()

        XCTAssertEqual(manager.manualFillHotkeyStatus.descriptor, .defaultManualFill)
        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .registered)
        XCTAssertEqual(manager.manualFillHotkeyStatus.displayName, "Control-Option-Command-P")
        XCTAssertEqual(runtime.registrations.map(\.descriptor), [.defaultManualFill])

        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastManualFillResult == .filled
        }

        XCTAssertEqual(manager.lastManualFillResult, .filled)
    }

    func testManualFillHotkeyRuntimeRefreshesPasswordStatusBeforeRegistration() {
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: nil)
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            hotkeyManager: HotkeyManager(runtime: runtime)
        )

        XCTAssertFalse(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertFalse(manager.isManualFillAvailable)

        vault.setStoredPassword("app-state-secret-\(UUID().uuidString)")
        manager.startManualFillHotkeyRuntime()

        XCTAssertTrue(manager.passwordConfigurationState.isPasswordConfigured)
        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .registered)
        XCTAssertEqual(runtime.registrations.map(\.descriptor), [.defaultManualFill])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testManualFillHotkeyDoesNotRunFacePresenceCheck() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let detector = RecordingFacePresenceDetector(result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)"),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            hotkeyManager: HotkeyManager(runtime: runtime),
            facePresenceDetector: detector,
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.startManualFillHotkeyRuntime()
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastManualFillResult == .filled
        }

        XCTAssertEqual(manager.lastManualFillResult, .filled)
        XCTAssertNil(manager.lastFacePresenceFillResult)
        XCTAssertEqual(detector.requestedTimeouts, [])
    }

    @MainActor
    func testManualFillHotkeyLockedSessionFallbackRunsRecognitionBeforeTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .noFocusedPasswordField,
            result: .noFocusedPasswordField
        )
        let typer = RecordingLockScreenPasswordTyper()
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.setLockScreenUnlockEnabled(true)
        manager.startManualFillHotkeyRuntime()
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastLockScreenUnlockResult == .typedPasswordAndSubmitted
        }

        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertEqual(manager.lastLockScreenUnlockResult, .typedPasswordAndSubmitted)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .unlockResult(.typedPasswordAndSubmitted))
        XCTAssertTrue(autofill.fillEvents.isEmpty)
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            1
        )
        XCTAssertEqual(typer.events, [.typedPasswordAndSubmit(passwordLength: password.count)])
        XCTAssertTrue(typer.didReceiveExpectedPassword(password))
    }

    @MainActor
    func testManualFillHotkeyLockedSessionRechecksLiveAccessibilityAfterRecognitionBeforeReadingOrTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let provider = SequencePermissionStatusProvider(statusSets: [
            [.accessibility(.authorized)],
            [.accessibility(.denied)]
        ])
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .noFocusedPasswordField,
            result: .noFocusedPasswordField
        )
        let typer = RecordingLockScreenPasswordTyper()
        let capture = QueueAppStateRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(
                sample: try makeRecognitionSample(),
                processedFrameCount: 1
            )),
            .captured(FaceSampleCaptureSummary(
                sample: try makeRecognitionSample(),
                processedFrameCount: 1
            ))
        ])
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: provider,
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.setLockScreenUnlockEnabled(true)
        manager.startManualFillHotkeyRuntime()
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastAutomaticLockScreenAttemptStatus == .unlockResult(.accessibilityPermissionDenied)
        }

        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertEqual(manager.lastLockScreenUnlockResult, .accessibilityPermissionDenied)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .unlockResult(.accessibilityPermissionDenied))
        XCTAssertTrue(autofill.fillEvents.isEmpty)
        XCTAssertEqual(capture.requestedTimeouts.count, 2)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
    }

    @MainActor
    func testManualFillHotkeyLockedSessionRecognitionFailuresDoNotReadOrType() async throws {
        let rejectedObservation = FaceRecognitionObservation(
            bestSimilarity: 0.2,
            modelVersion: "app-state-test-model",
            dimension: 3,
            comparedTemplateCount: 1,
            frame: .usable(FaceRecognitionMatchScore(
                similarity: 0.2,
                modelVersion: "app-state-test-model"
            ))
        )
        let cases: [
            (
                name: String,
                captureResult: FaceSampleCaptureResult,
                observation: FaceRecognitionObservation,
                observeError: Error?,
                configureModelPath: Bool,
                expectedStatus: AutomaticLockScreenAttemptStatus
            )
        ] = [
            (
                name: "recognition rejected",
                captureResult: .captured(FaceSampleCaptureSummary(
                    sample: try makeRecognitionSample(),
                    processedFrameCount: 1
                )),
                observation: rejectedObservation,
                observeError: nil,
                configureModelPath: true,
                expectedStatus: .recognitionRejected
            ),
            (
                name: "missing model",
                captureResult: .captured(FaceSampleCaptureSummary(
                    sample: try makeRecognitionSample(),
                    processedFrameCount: 1
                )),
                observation: rejectedObservation,
                observeError: nil,
                configureModelPath: false,
                expectedStatus: .recognitionRejected
            ),
            (
                name: "missing template",
                captureResult: .captured(FaceSampleCaptureSummary(
                    sample: try makeRecognitionSample(),
                    processedFrameCount: 1
                )),
                observation: rejectedObservation,
                observeError: FaceRecognitionRuntimeWorkflowError.noTemplate,
                configureModelPath: true,
                expectedStatus: .recognitionRejected
            ),
            (
                name: "camera failure",
                captureResult: .failed(.captureFailed),
                observation: rejectedObservation,
                observeError: nil,
                configureModelPath: true,
                expectedStatus: .cameraFailed
            )
        ]

        for testCase in cases {
            let isolatedDefaults = makeIsolatedUserDefaults()
            let runtime = RecordingHotkeyRuntime()
            let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
            let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .noFocusedPasswordField)
            let typer = RecordingLockScreenPasswordTyper()
            let capture = QueueAppStateRecognitionSampleCapture(result: testCase.captureResult)
            let recognition = try makeRecognitionController(
                userDefaults: isolatedDefaults.defaults,
                sampleCaptureService: capture,
                observation: testCase.observation,
                observeError: testCase.observeError,
                configureModelPath: testCase.configureModelPath
            )
            let manager = AppStateManager(
                permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
                passwordVault: vault,
                autofillService: autofill,
                hotkeyManager: HotkeyManager(runtime: runtime),
                cameraPermissionProvider: StubCameraPermissionProvider(
                    currentStatus: .authorized,
                    requestedStatus: .authorized
                ),
                lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
                lockScreenPasswordTyper: typer,
                recognitionRuntimeController: recognition,
                userDefaults: isolatedDefaults.defaults
            )

            manager.setLockScreenUnlockEnabled(true)
            manager.startManualFillHotkeyRuntime()
            runtime.trigger(eventID: runtime.registrations[0].eventID)
            await waitUntil {
                manager.lastAutomaticLockScreenAttemptStatus == testCase.expectedStatus
            }

            XCTAssertNil(manager.lastManualFillResult, testCase.name)
            XCTAssertNil(manager.lastLockScreenUnlockResult, testCase.name)
            XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, testCase.expectedStatus, testCase.name)
            XCTAssertTrue(autofill.fillEvents.isEmpty, testCase.name)
            XCTAssertFalse(
                vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)),
                testCase.name
            )
            XCTAssertTrue(typer.events.isEmpty, testCase.name)
            XCTAssertFalse(testCase.expectedStatus.description.contains("app-state-secret"), testCase.name)
        }
    }

    @MainActor
    func testManualFillHotkeyReportsSessionNotLockedWithoutRecognitionOrTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(
            isAccessibilityTrusted: true,
            focusedStatus: .noFocusedPasswordField,
            result: .noFocusedPasswordField
        )
        let typer = RecordingLockScreenPasswordTyper()
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.setLockScreenUnlockEnabled(true)
        manager.startManualFillHotkeyRuntime()
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastManualFillResult == .noFocusedPasswordField
        }

        XCTAssertEqual(manager.lastManualFillResult, .noFocusedPasswordField)
        XCTAssertNil(manager.lastLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
        XCTAssertEqual(autofill.fillEvents, [.checkedAuthorizationPrompt])
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertTrue(typer.events.isEmpty)
    }

    @MainActor
    func testManualFillHotkeyLockedSessionMissingPasswordDoesNotStartRecognitionOrTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .noFocusedPasswordField)
        let typer = RecordingLockScreenPasswordTyper()
        let capture = QueueAppStateRecognitionSampleCapture(result: .captured(FaceSampleCaptureSummary(
            sample: try makeRecognitionSample(),
            processedFrameCount: 1
        )))
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: capture
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.setLockScreenUnlockEnabled(true)
        manager.startManualFillHotkeyRuntime()
        vault.setStoredPassword(nil)
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastLockScreenUnlockResult == .missingPassword
        }

        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertEqual(manager.lastLockScreenUnlockResult, .missingPassword)
        XCTAssertEqual(manager.lastAutomaticLockScreenAttemptStatus, .unlockResult(.missingPassword))
        XCTAssertTrue(autofill.fillEvents.isEmpty)
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testManualFillHotkeySuccessDoesNotAttemptLockScreenTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let runtime = RecordingHotkeyRuntime()
        let password = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: password)
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled)
        let typer = RecordingLockScreenPasswordTyper()
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            captureResult: .captured(FaceSampleCaptureSummary(
                sample: makeRecognitionSample(),
                processedFrameCount: 1
            ))
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: false),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            userDefaults: isolatedDefaults.defaults
        )

        manager.setLockScreenUnlockEnabled(true)
        manager.startManualFillHotkeyRuntime()
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastManualFillResult == .filled
        }

        XCTAssertEqual(manager.lastManualFillResult, .filled)
        XCTAssertNil(manager.lastLockScreenUnlockResult)
        XCTAssertEqual(autofill.fillEvents, [
            .checkedAuthorizationPrompt,
            .checkedAuthorizationPrompt,
            .fillAuthorizationValueOnly(passwordLength: password.count)
        ])
        XCTAssertTrue(typer.events.isEmpty)
    }

    @MainActor
    func testManualFillHotkeyLockedSessionDoesNotReadOrTypeWhenLockScreenOptInIsDisabled() async {
        let userDefaults = makeIsolatedUserDefaults().defaults
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let autofill = StubPasswordAutofillService(isAccessibilityTrusted: true, result: .noFocusedPasswordField)
        let typer = RecordingLockScreenPasswordTyper()
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            hotkeyManager: HotkeyManager(runtime: runtime),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            userDefaults: userDefaults
        )

        manager.startManualFillHotkeyRuntime()
        runtime.trigger(eventID: runtime.registrations[0].eventID)
        await waitUntil {
            manager.lastLockScreenUnlockResult == .disabled
        }

        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertEqual(manager.lastLockScreenUnlockResult, .disabled)
        XCTAssertTrue(autofill.fillEvents.isEmpty)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
    }

    func testManualFillHotkeyRuntimeDoesNotRegisterOrReadPasswordWhenPrerequisitesAreMissing() {
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.denied)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            hotkeyManager: HotkeyManager(runtime: runtime)
        )

        manager.startManualFillHotkeyRuntime()

        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .disabled)
        XCTAssertTrue(runtime.registrations.isEmpty)
        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testManualFillHotkeyDisablesAndDoesNotRunWhenAppIsDisabled() {
        let runtime = RecordingHotkeyRuntime()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            hotkeyManager: HotkeyManager(runtime: runtime)
        )
        manager.startManualFillHotkeyRuntime()
        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .registered)

        manager.setEnabled(false)

        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .disabled)
        XCTAssertEqual(runtime.unregisteredEventIDs, [runtime.registrations[0].eventID])

        runtime.trigger(eventID: runtime.registrations[0].eventID)

        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
    }

    func testAllPermissionsAcquiredRequiresEveryPermissionGranted() {
        let readyManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [
                .camera(.authorized),
                .accessibility(.authorized),
                .keychain(.available)
            ]),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled)
        )
        let missingCameraManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [
                .camera(.notDetermined),
                .accessibility(.authorized),
                .keychain(.available)
            ]),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled)
        )

        XCTAssertTrue(readyManager.areAllPermissionsAcquired)
        XCTAssertFalse(missingCameraManager.areAllPermissionsAcquired)
    }

    func testRequestCameraPermissionUpdatesPermissionStatuses() async {
        let cameraPermission = StubCameraPermissionProvider(
            currentStatus: .notDetermined,
            requestedStatus: .authorized
        )
        let provider = MutablePermissionStatusProvider(statuses: [
            .camera(.notDetermined),
            .accessibility(.authorized),
            .keychain(.available)
        ])
        let manager = AppStateManager(
            permissionStatusProvider: provider,
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            cameraPermissionProvider: cameraPermission
        )

        let result = await manager.requestCameraPermission()

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(cameraPermission.requestCount, 1)
        XCTAssertEqual(manager.permissionStatuses.first { $0.kind == .camera }?.authorization, .authorized)
    }

    func testManualFillHotkeyRuntimeDisablesWhenAvailabilityChanges() throws {
        let runtime = RecordingHotkeyRuntime()
        let provider = MutablePermissionStatusProvider(statuses: [.accessibility(.authorized)])
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let manager = AppStateManager(
            permissionStatusProvider: provider,
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            hotkeyManager: HotkeyManager(runtime: runtime)
        )
        manager.startManualFillHotkeyRuntime()
        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .registered)

        provider.statuses = [.accessibility(.denied)]
        manager.refreshPermissions()

        XCTAssertEqual(manager.manualFillHotkeyStatus.runtimeRegistrationState, .disabled)
        XCTAssertEqual(runtime.unregisteredEventIDs, [runtime.registrations[0].eventID])
    }

    @MainActor
    func testStandByUnlockVerifiedRequestBypassesLocalRecognitionAndUsesLockScreenPathOnlyWhileLocked() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let secret = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: secret)
        let typer = RecordingLockScreenPasswordTyper()
        let displayWake = RecordingDisplayWakeController()
        let recognitionCapture = FailingAppStateRecognitionSampleCapture()
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: recognitionCapture
        )
        let verifier = StubStandByUnlockVerifier(result: .verified(makeVerifiedStandByUnlockRequest()))
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            standByUnlockVerifier: verifier,
            displayWakeController: displayWake,
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )

        manager.setStandByUnlockEnabled(true)
        await manager.handleStandByUnlockRequest(makeStandByUnlockRequest())

        XCTAssertEqual(verifier.verifiedRequestIds, ["standby-request-1"])
        XCTAssertEqual(displayWake.wakeCount, 1)
        XCTAssertEqual(manager.lastStandByUnlockResult, .unlockResult(.typedPasswordAndSubmitted))
        XCTAssertEqual(
            vault.events.filter { $0 == .readPassword(account: defaultPasswordAccountIdentifier) }.count,
            1
        )
        XCTAssertEqual(typer.events, [.typedPasswordAndSubmit(passwordLength: secret.count)])
        XCTAssertTrue(typer.didReceiveExpectedPassword(secret))
        XCTAssertEqual(recognitionCapture.requestedTimeouts, [])
        XCTAssertFalse(String(describing: manager.lastStandByUnlockResult).contains(secret))
    }

    @MainActor
    func testStandByUnlockDoesNotReadTypeWakeOrRunRecognitionWhenProviderDisabled() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let vault = SpyPasswordVault(storedPassword: "app-state-secret-\(UUID().uuidString)")
        let typer = RecordingLockScreenPasswordTyper()
        let displayWake = RecordingDisplayWakeController()
        let recognitionCapture = FailingAppStateRecognitionSampleCapture()
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: recognitionCapture
        )
        let verifier = StubStandByUnlockVerifier(result: .verified(makeVerifiedStandByUnlockRequest()))
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            standByUnlockVerifier: verifier,
            displayWakeController: displayWake,
            userDefaults: isolatedDefaults.defaults
        )

        await manager.handleStandByUnlockRequest(makeStandByUnlockRequest())

        XCTAssertEqual(manager.lastStandByUnlockResult, .disabled)
        XCTAssertEqual(verifier.verifiedRequestIds, [])
        XCTAssertEqual(displayWake.wakeCount, 0)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(recognitionCapture.requestedTimeouts, [])
    }

    @MainActor
    func testStandByUnlockRejectsInvalidRequestWithoutPasswordCameraOrTyping() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let secret = "app-state-secret-\(UUID().uuidString)"
        let vault = SpyPasswordVault(storedPassword: secret)
        let typer = RecordingLockScreenPasswordTyper()
        let displayWake = RecordingDisplayWakeController()
        let recognitionCapture = FailingAppStateRecognitionSampleCapture()
        let recognition = try makeRecognitionController(
            userDefaults: isolatedDefaults.defaults,
            sampleCaptureService: recognitionCapture
        )
        let verifier = StubStandByUnlockVerifier(result: .rejected(.unpairedIPhone))
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognition,
            standByUnlockVerifier: verifier,
            displayWakeController: displayWake,
            userDefaults: isolatedDefaults.defaults
        )

        manager.setStandByUnlockEnabled(true)
        await manager.handleStandByUnlockRequest(makeStandByUnlockRequest(requestId: secret))

        XCTAssertEqual(manager.lastStandByUnlockResult, .verificationFailed(.unpairedIPhone))
        XCTAssertEqual(displayWake.wakeCount, 0)
        XCTAssertFalse(vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)))
        XCTAssertTrue(typer.events.isEmpty)
        XCTAssertEqual(recognitionCapture.requestedTimeouts, [])
        XCTAssertFalse(String(describing: manager.lastStandByUnlockResult).contains(secret))
    }

    @MainActor
    func testStandByUnlockUnlockedSessionMissingPasswordAccessibilityAndConditionsDoNotType() async throws {
        let cases: [
            (
                name: String,
                statuses: [PermissionStatus],
                storedPassword: String?,
                isSessionLocked: Bool,
                conditionSnapshot: ConditionSignalSnapshot,
                configureConditions: (AppStateManager) -> Void,
                expectedResult: StandByUnlockAttemptStatus
            )
        ] = [
            (
                name: "unlocked session",
                statuses: [.accessibility(.authorized)],
                storedPassword: "app-state-secret-\(UUID().uuidString)",
                isSessionLocked: false,
                conditionSnapshot: .automationTrusted,
                configureConditions: { _ in },
                expectedResult: .authorizationPromptFillResult(.filled)
            ),
            (
                name: "missing password",
                statuses: [.accessibility(.authorized)],
                storedPassword: nil,
                isSessionLocked: true,
                conditionSnapshot: .automationTrusted,
                configureConditions: { _ in },
                expectedResult: .unlockResult(.missingPassword)
            ),
            (
                name: "accessibility denied",
                statuses: [.accessibility(.denied)],
                storedPassword: "app-state-secret-\(UUID().uuidString)",
                isSessionLocked: true,
                conditionSnapshot: .automationTrusted,
                configureConditions: { _ in },
                expectedResult: .unlockResult(.accessibilityPermissionDenied)
            ),
            (
                name: "conditions rejected",
                statuses: [.accessibility(.authorized)],
                storedPassword: "app-state-secret-\(UUID().uuidString)",
                isSessionLocked: true,
                conditionSnapshot: ConditionSignalSnapshot(
                    wifi: .unavailable,
                    externalDisplays: .connected([]),
                    power: .available(.battery),
                    bluetooth: .inconclusive
                ),
                configureConditions: {
                    $0.setAutomationConditionGateEnabled(true)
                    $0.setAutomationRequiresWiFiConnected(true)
                },
                expectedResult: .conditionsNotSatisfied
            )
        ]

        for testCase in cases {
            let isolatedDefaults = makeIsolatedUserDefaults()
            let vault = SpyPasswordVault(storedPassword: testCase.storedPassword)
            let typer = RecordingLockScreenPasswordTyper()
            let displayWake = RecordingDisplayWakeController()
            let recognitionCapture = FailingAppStateRecognitionSampleCapture()
            let recognition = try makeRecognitionController(
                userDefaults: isolatedDefaults.defaults,
                sampleCaptureService: recognitionCapture
            )
            let manager = AppStateManager(
                permissionStatusProvider: StubPermissionStatusProvider(statuses: testCase.statuses),
                passwordVault: vault,
                autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
                lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: testCase.isSessionLocked),
                lockScreenPasswordTyper: typer,
                recognitionRuntimeController: recognition,
                standByUnlockVerifier: StubStandByUnlockVerifier(result: .verified(makeVerifiedStandByUnlockRequest())),
                displayWakeController: displayWake,
                conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: testCase.conditionSnapshot),
                userDefaults: isolatedDefaults.defaults
            )

            manager.setStandByUnlockEnabled(true)
            testCase.configureConditions(manager)
            await manager.handleStandByUnlockRequest(makeStandByUnlockRequest())

            XCTAssertEqual(manager.lastStandByUnlockResult, testCase.expectedResult, testCase.name)
            XCTAssertEqual(displayWake.wakeCount, 0, testCase.name)
            XCTAssertTrue(typer.events.isEmpty, testCase.name)
            XCTAssertEqual(recognitionCapture.requestedTimeouts, [], testCase.name)
            if testCase.expectedResult == .authorizationPromptFillResult(.filled) {
                XCTAssertTrue(
                    vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)),
                    testCase.name
                )
            } else {
                XCTAssertFalse(
                    vault.events.contains(.readPassword(account: defaultPasswordAccountIdentifier)),
                    testCase.name
                )
            }
        }
    }

    func testStartStandByPairingSessionPublishesSettingsSessionFromInjectedPairingControllerWithoutPublicKey() {
        let store = RecordingStandByPairedDeviceStore()
        let statusProvider = StubStandByHTTPServerStatusProvider(
            httpStatus: .ready,
            bonjourStatusDescription: "Published on _facepass._tcp"
        )
        let pairingController = StandByUnlockPairingController(
            macDeviceId: "mac-standby-settings",
            publicKeyFingerprint: "fp:settings:1234",
            pairedDeviceStore: store,
            clock: { standbyAppStateDate("2026-04-26T10:00:00Z") },
            tokenGenerator: { "pairing-token-settings" }
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByPairingController: pairingController,
            standByPairedDeviceStore: store,
            standByHTTPServerStatusProvider: statusProvider,
            userDefaults: makeIsolatedUserDefaults().defaults
        )

        manager.startStandByPairingSession()

        XCTAssertEqual(manager.standByPairingState, .pairing)
        XCTAssertEqual(manager.standByPairingSession?.macDeviceId, "mac-standby-settings")
        XCTAssertEqual(manager.standByPairingSession?.protocolVersion, StandByUnlockPairingController.protocolVersion)
        XCTAssertEqual(manager.standByPairingSession?.publicKeyFingerprint, "fp:settings:1234")
        XCTAssertEqual(manager.standByPairingSession?.oneTimeToken, "pairing-token-settings")
        XCTAssertEqual(
            manager.standByPairingSession?.qrPayload["type"] as? String,
            "facepass_standby_pairing"
        )
        XCTAssertEqual(
            manager.standByIPhoneUnlockStatus.pairingQRCodePayload?["oneTimeToken"] as? String,
            "pairing-token-settings"
        )
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    func testStandByPairedStatusUsesStoreAsSourceOfTruthAndHidesQRCode() throws {
        let store = RecordingStandByPairedDeviceStore()
        let pairingController = StandByUnlockPairingController(
            macDeviceId: "mac-standby-settings",
            publicKeyFingerprint: "fp:settings:1234",
            pairedDeviceStore: store,
            clock: { standbyAppStateDate("2026-04-26T10:00:00Z") },
            tokenGenerator: { "pairing-token-settings" }
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByPairingController: pairingController,
            standByPairedDeviceStore: store,
            standByHTTPServerStatusProvider: StubStandByHTTPServerStatusProvider(httpStatus: .ready),
            userDefaults: makeIsolatedUserDefaults().defaults
        )

        manager.startStandByPairingSession()
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .pairing)
        XCTAssertNotNil(manager.standByIPhoneUnlockStatus.pairingQRCodePayload)

        try store.savePairedDevice(StandByPairedDevice(
            iphoneDeviceId: "iphone-settings-blank-name",
            displayName: "   ",
            publicKeyX963Representation: Data("PUBLIC-KEY-MATERIAL".utf8),
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: standbyAppStateDate("2026-04-26T10:05:00Z"),
            lastSeenAt: standbyAppStateDate("2026-04-26T10:06:00Z"),
            highestAcceptedCounter: 1
        ))
        manager.refreshStandByUnlockStatus()

        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .paired)
        XCTAssertTrue(manager.standByIPhoneUnlockStatus.isPaired)
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName, "Paired iPhone")
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairedIPhoneStatusText, "Paired iPhone")
        XCTAssertNil(manager.standByIPhoneUnlockStatus.pairingQRCodePayload)
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    func testStandByPairedStatusRecoversFromPersistedIPhoneDeviceIdWhenAggregateLookupFailsAfterRestart() throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let device = StandByPairedDevice(
            iphoneDeviceId: "iphone-restart-1",
            displayName: "Restart iPhone",
            publicKeyX963Representation: Data("PUBLIC-KEY-MATERIAL".utf8),
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: standbyAppStateDate("2026-05-03T18:58:00Z"),
            lastSeenAt: standbyAppStateDate("2026-05-03T18:59:00Z"),
            highestAcceptedCounter: 45
        )

        let initialStore = RecordingStandByPairedDeviceStore(device: device)
        let initialManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByPairedDeviceStore: initialStore,
            standByHTTPServerStatusProvider: StubStandByHTTPServerStatusProvider(httpStatus: .ready),
            userDefaults: isolatedDefaults.defaults
        )
        initialManager.refreshStandByUnlockStatus()
        XCTAssertEqual(initialManager.standByIPhoneUnlockStatus.pairingState, .paired)

        let restartedStore = RecordingStandByPairedDeviceStore(
            device: device,
            allowsCurrentLookup: false
        )
        let restartedManager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByPairedDeviceStore: restartedStore,
            standByHTTPServerStatusProvider: StubStandByHTTPServerStatusProvider(httpStatus: .ready),
            userDefaults: isolatedDefaults.defaults
        )

        XCTAssertEqual(restartedManager.standByIPhoneUnlockStatus.pairingState, .paired)
        XCTAssertTrue(restartedManager.standByIPhoneUnlockStatus.isPaired)
        XCTAssertEqual(restartedManager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName, "Restart iPhone")
        XCTAssertEqual(restartedManager.standByIPhoneUnlockStatus.lastSeenAt, device.lastSeenAt)
        XCTAssertFalse(String(describing: restartedManager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    func testForgetStandByPairedIPhoneDeletesTrustRecordAndRefreshesNonSensitiveStatus() throws {
        let pairedAt = standbyAppStateDate("2026-04-26T10:15:00Z")
        let lastSeen = standbyAppStateDate("2026-04-26T11:45:00Z")
        let publicKey = Data("PUBLIC-KEY-MATERIAL".utf8)
        let store = RecordingStandByPairedDeviceStore(
            device: StandByPairedDevice(
                iphoneDeviceId: "iphone-settings-1",
                displayName: "Yiwen's iPhone",
                publicKeyX963Representation: publicKey,
                signingAlgorithm: .p256SHA256,
                isEnabled: true,
                createdAt: pairedAt,
                lastSeenAt: lastSeen,
                highestAcceptedCounter: 42
            )
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByPairedDeviceStore: store,
            standByHTTPServerStatusProvider: StubStandByHTTPServerStatusProvider(httpStatus: .ready),
            userDefaults: makeIsolatedUserDefaults().defaults
        )

        manager.refreshStandByUnlockStatus()
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName, "Yiwen's iPhone")
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.lastSeenAt, lastSeen)

        try manager.forgetStandByPairedIPhone()

        XCTAssertEqual(store.deleteAllCount, 1)
        XCTAssertEqual(store.remainingDeviceIDs, [])
        XCTAssertNil(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName)
        XCTAssertNil(manager.standByIPhoneUnlockStatus.lastSeenAt)
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .notPaired)
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    func testForgetStandByPairedIPhoneDeletesAllHiddenTrustRecords() throws {
        let publicKey = Data("PUBLIC-KEY-MATERIAL".utf8)
        let store = RecordingStandByPairedDeviceStore(devices: [
            StandByPairedDevice(
                iphoneDeviceId: "iphone-hidden-older",
                displayName: "Older iPhone",
                publicKeyX963Representation: publicKey,
                signingAlgorithm: .p256SHA256,
                isEnabled: true,
                createdAt: standbyAppStateDate("2026-04-26T09:00:00Z"),
                lastSeenAt: nil,
                highestAcceptedCounter: 1
            ),
            StandByPairedDevice(
                iphoneDeviceId: "iphone-current-newer",
                displayName: "Current iPhone",
                publicKeyX963Representation: publicKey,
                signingAlgorithm: .p256SHA256,
                isEnabled: true,
                createdAt: standbyAppStateDate("2026-04-26T10:00:00Z"),
                lastSeenAt: standbyAppStateDate("2026-04-26T11:00:00Z"),
                highestAcceptedCounter: 2
            )
        ])
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByPairedDeviceStore: store,
            standByHTTPServerStatusProvider: StubStandByHTTPServerStatusProvider(httpStatus: .ready),
            userDefaults: makeIsolatedUserDefaults().defaults
        )

        manager.refreshStandByUnlockStatus()
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName, "Current iPhone")

        try manager.forgetStandByPairedIPhone()

        XCTAssertEqual(store.deleteAllCount, 1)
        XCTAssertEqual(store.remainingDeviceIDs, [])
        XCTAssertNil(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName)
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .notPaired)
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    @MainActor
    func testRefreshStandByUnlockStatusSurfacesRuntimePairingAndLastRequestStateWithoutSecrets() async {
        let lastSeen = standbyAppStateDate("2026-04-26T12:30:00Z")
        let secretRequestId = "standby-secret-request-\(UUID().uuidString)"
        let publicKey = Data("PUBLIC-KEY-MATERIAL".utf8)
        let store = RecordingStandByPairedDeviceStore(
            device: StandByPairedDevice(
                iphoneDeviceId: "iphone-settings-2",
                displayName: "Desk iPhone",
                publicKeyX963Representation: publicKey,
                signingAlgorithm: .p256SHA256,
                isEnabled: true,
                createdAt: standbyAppStateDate("2026-04-26T09:00:00Z"),
                lastSeenAt: lastSeen,
                highestAcceptedCounter: 9
            )
        )
        let statusProvider = StubStandByHTTPServerStatusProvider(
            httpStatus: .starting,
            bonjourStatusDescription: "Preparing Bonjour advertisement"
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: []),
            passwordVault: SpyPasswordVault(storedPassword: nil),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: false, result: .filled),
            standByUnlockVerifier: StubStandByUnlockVerifier(result: .rejected(.replayedRequestId)),
            standByPairedDeviceStore: store,
            standByHTTPServerStatusProvider: statusProvider,
            userDefaults: makeIsolatedUserDefaults().defaults
        )

        manager.setStandByUnlockEnabled(true)
        await manager.handleStandByUnlockRequest(makeStandByUnlockRequest(requestId: secretRequestId))
        manager.refreshStandByUnlockStatus()

        XCTAssertEqual(manager.standByIPhoneUnlockStatus.httpServerStatus, .starting)
        XCTAssertEqual(
            manager.standByIPhoneUnlockStatus.bonjourStatusDescription,
            "Preparing Bonjour advertisement"
        )
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .paired)
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName, "Desk iPhone")
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.lastSeenAt, lastSeen)
        XCTAssertEqual(
            manager.standByIPhoneUnlockStatus.lastRequestResult,
            .verificationFailed(.replayedRequestId)
        )
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains(secretRequestId))
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    @MainActor
    func testSuccessfulStandByUnlockRequestRecoversPairedStatusFromVerifiedTrustRecord() async throws {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let secret = "app-state-secret-\(UUID().uuidString)"
        let lastSeen = standbyAppStateDate("2026-04-27T14:05:00Z")
        let store = RecordingStandByPairedDeviceStore(
            device: StandByPairedDevice(
                iphoneDeviceId: "iphone-standby-1",
                displayName: "Verified iPhone",
                publicKeyX963Representation: Data("PUBLIC-KEY-MATERIAL".utf8),
                signingAlgorithm: .p256SHA256,
                isEnabled: true,
                createdAt: standbyAppStateDate("2026-04-27T13:55:00Z"),
                lastSeenAt: lastSeen,
                highestAcceptedCounter: 8
            ),
            allowsCurrentLookup: false
        )
        let pairingController = StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "fp:settings:1234",
            pairedDeviceStore: store,
            clock: { standbyAppStateDate("2026-04-27T14:00:00Z") },
            tokenGenerator: { "pairing-token-settings" }
        )
        let manager = AppStateManager(
            permissionStatusProvider: StubPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: SpyPasswordVault(storedPassword: secret),
            autofillService: StubPasswordAutofillService(isAccessibilityTrusted: true, result: .filled),
            lockScreenStateProvider: StubLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: RecordingLockScreenPasswordTyper(),
            standByUnlockVerifier: StubStandByUnlockVerifier(result: .verified(makeVerifiedStandByUnlockRequest())),
            standByPairingController: pairingController,
            standByPairedDeviceStore: store,
            displayWakeController: RecordingDisplayWakeController(),
            conditionSignalProvider: StubAppStateConditionSignalProvider(snapshot: .automationTrusted),
            userDefaults: isolatedDefaults.defaults
        )

        manager.startStandByPairingSession()
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .pairing)
        XCTAssertNotNil(manager.standByIPhoneUnlockStatus.pairingQRCodePayload)

        manager.setStandByUnlockEnabled(true)
        await manager.handleStandByUnlockRequest(makeStandByUnlockRequest())

        XCTAssertEqual(manager.lastStandByUnlockResult, .unlockResult(.typedPasswordAndSubmitted))
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairingState, .paired)
        XCTAssertTrue(manager.standByIPhoneUnlockStatus.isPaired)
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.pairedIPhoneDisplayName, "Verified iPhone")
        XCTAssertEqual(manager.standByIPhoneUnlockStatus.lastSeenAt, lastSeen)
        XCTAssertNil(manager.standByIPhoneUnlockStatus.pairingQRCodePayload)
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains(secret))
        XCTAssertFalse(String(describing: manager.standByIPhoneUnlockStatus).contains("PUBLIC-KEY-MATERIAL"))
    }

    private func makeIsolatedUserDefaults() -> IsolatedUserDefaults {
        let suiteName = "FacePass.AppStateManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Expected isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedUserDefaults(suiteName: suiteName, defaults: defaults)
    }

    private func makeRecognitionController(
        userDefaults: UserDefaults,
        captureResult: FaceSampleCaptureResult,
        observation: FaceRecognitionObservation = FaceRecognitionObservation(
            bestSimilarity: 0.72,
            modelVersion: "app-state-test-model",
            dimension: 3,
            comparedTemplateCount: 1,
            frame: .usable(FaceRecognitionMatchScore(
                similarity: 0.72,
                modelVersion: "app-state-test-model"
            ))
        ),
        observeError: Error? = nil
    ) throws -> FaceRecognitionRuntimeController {
        try makeRecognitionController(
            userDefaults: userDefaults,
            sampleCaptureService: QueueAppStateRecognitionSampleCapture(
                results: sensitiveGateCaptureResults(from: captureResult)
            ),
            observation: observation,
            observeError: observeError
        )
    }

    private func sensitiveGateCaptureResults(
        from result: FaceSampleCaptureResult
    ) -> [FaceSampleCaptureResult] {
        switch result {
        case .captured:
            return [result, result]
        default:
            return [result]
        }
    }

    private func makeRecognitionController(
        userDefaults: UserDefaults,
        sampleCaptureService: any FaceRecognitionSampleCapturing,
        observation: FaceRecognitionObservation = FaceRecognitionObservation(
            bestSimilarity: 0.72,
            modelVersion: "app-state-test-model",
            dimension: 3,
            comparedTemplateCount: 1,
            frame: .usable(FaceRecognitionMatchScore(
                similarity: 0.72,
                modelVersion: "app-state-test-model"
            ))
        ),
        observeError: Error? = nil,
        configureModelPath: Bool = true
    ) throws -> FaceRecognitionRuntimeController {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FacePass-AppStateManagerTests-\(UUID().uuidString).mlmodel")
        if configureModelPath {
            try Data("model".utf8).write(to: modelURL)
        }
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: sampleCaptureService,
            workflowFactory: RecordingAppStateRecognitionWorkflowFactory(
                workflow: RecordingAppStateRecognitionWorkflow(
                    observation: observation,
                    observeError: observeError
                )
            ),
            userDefaults: userDefaults,
            currentTimeProvider: { 0 }
        )
        if configureModelPath {
            controller.setRecognitionModelPath(modelURL.path)
        }
        return controller
    }

    private func makeRecognitionSample() throws -> FaceEnrollmentSample {
        FaceEnrollmentSample(
            image: try makeRecognitionImage(),
            visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    private func makeRecognitionImage() throws -> CGImage {
        let width = 112
        let height = 112
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bytes = Data(repeating: 255, count: height * bytesPerRow)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw AppStateManagerTestError.imageCreationFailed
        }

        return image
    }

    private func makeStandByUnlockRequest(
        requestId: String = "standby-request-1"
    ) -> StandByUnlockRequest {
        StandByUnlockRequest(
            type: "standby_unlock_request",
            protocolVersion: 1,
            requestId: requestId,
            iphoneDeviceId: "iphone-standby-1",
            macDeviceId: "mac-facepass-1",
            action: "unlock_screen",
            issuedAt: standbyAppStateDate("2026-04-27T14:04:30Z"),
            expiresAt: standbyAppStateDate("2026-04-27T14:05:30Z"),
            counter: 8,
            signature: Data("test-signature".utf8)
        )
    }

    private func makeVerifiedStandByUnlockRequest(
        requestId: String = "standby-request-1"
    ) -> StandByVerifiedUnlockRequest {
        StandByVerifiedUnlockRequest(
            requestId: requestId,
            macDeviceId: "mac-facepass-1",
            iphoneDeviceId: "iphone-standby-1",
            counter: 8,
            verifiedAt: standbyAppStateDate("2026-04-27T14:05:00Z")
        )
    }
}

private struct StubPermissionStatusProvider: PermissionStatusProviding {
    let statuses: [PermissionStatus]

    func currentPermissionStatuses() -> [PermissionStatus] {
        statuses
    }
}

private final class MutablePermissionStatusProvider: PermissionStatusProviding {
    var statuses: [PermissionStatus]

    init(statuses: [PermissionStatus]) {
        self.statuses = statuses
    }

    func currentPermissionStatuses() -> [PermissionStatus] {
        statuses
    }
}

private final class SequencePermissionStatusProvider: PermissionStatusProviding {
    private var statusSets: [[PermissionStatus]]
    private let fallbackStatuses: [PermissionStatus]

    init(statusSets: [[PermissionStatus]]) {
        self.statusSets = statusSets
        self.fallbackStatuses = statusSets.last ?? []
    }

    func currentPermissionStatuses() -> [PermissionStatus] {
        guard !statusSets.isEmpty else {
            return fallbackStatuses
        }

        return statusSets.removeFirst()
    }
}

private final class StubPasswordAutofillService: PasswordAutofillService {
    let isAccessibilityTrusted: Bool
    private var focusedStatus: AuthorizationPromptPasswordFieldStatus
    private let result: AccessibilityAutofillResult
    private(set) var fillEvents: [AppStateAutofillEvent] = []

    init(
        isAccessibilityTrusted: Bool,
        focusedStatus: AuthorizationPromptPasswordFieldStatus = .available,
        result: AccessibilityAutofillResult
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.focusedStatus = focusedStatus
        self.result = result
    }

    func focusedAuthorizationPromptStatus() -> AuthorizationPromptPasswordFieldStatus {
        fillEvents.append(.checkedAuthorizationPrompt)
        return focusedStatus
    }

    func fillFocusedPasswordField(with password: String) -> AccessibilityAutofillResult {
        fillEvents.append(.fillValueOnly(passwordLength: password.count))
        return result
    }

    func fillFocusedAuthorizationPasswordField(with password: String) -> AccessibilityAutofillResult {
        fillEvents.append(.fillAuthorizationValueOnly(passwordLength: password.count))
        return result
    }

    func setFocusedStatus(_ focusedStatus: AuthorizationPromptPasswordFieldStatus) {
        self.focusedStatus = focusedStatus
    }
}

private enum AppStateAutofillEvent: Equatable {
    case checkedAuthorizationPrompt
    case fillValueOnly(passwordLength: Int)
    case fillAuthorizationValueOnly(passwordLength: Int)
}

private final class QueueAppStateRecognitionSampleCapture: FaceRecognitionSampleCapturing {
    private var results: [FaceSampleCaptureResult]
    private(set) var requestedTimeouts: [TimeInterval] = []

    init(result: FaceSampleCaptureResult) {
        self.results = [result]
    }

    init(results: [FaceSampleCaptureResult]) {
        self.results = results
    }

    func captureSample(timeout: TimeInterval) async -> FaceSampleCaptureResult {
        requestedTimeouts.append(timeout)

        guard !results.isEmpty else {
            return .timedOut
        }

        return results.removeFirst()
    }
}

private final class RecordingAppStateRecognitionWorkflowFactory: FaceRecognitionRuntimeWorkflowMaking {
    private let workflow: RecordingAppStateRecognitionWorkflow

    init(workflow: RecordingAppStateRecognitionWorkflow) {
        self.workflow = workflow
    }

    func makeWorkflow(modelURL: URL) throws -> any FaceRecognitionRuntimeWorkflow {
        workflow
    }
}

private final class RecordingAppStateRecognitionWorkflow: FaceRecognitionRuntimeWorkflow {
    let modelVersion = "app-state-test-model"
    let dimension = 3
    private let observation: FaceRecognitionObservation
    private let observeError: Error?

    init(
        observation: FaceRecognitionObservation,
        observeError: Error?
    ) {
        self.observation = observation
        self.observeError = observeError
    }

    func enroll(
        samples: [FaceEnrollmentSample],
        metadata: FaceEnrollmentMetadata
    ) async throws -> FaceTemplateRecord {
        throw AppStateManagerTestError.unexpectedEnrollment
    }

    func observe(sample: FaceEnrollmentSample) async throws -> FaceRecognitionObservation {
        if let observeError {
            throw observeError
        }

        return observation
    }
}

private struct FixedAppStateBundledModelURLProvider: FaceRecognitionBundledModelURLProviding {
    let url: URL?

    func bundledModelURL() -> URL? {
        url
    }
}

private final class RecordingFacePresenceDetector: FacePresenceDetecting {
    private let result: CameraFaceDetectionResult
    private(set) var requestedTimeouts: [TimeInterval] = []

    init(result: CameraFaceDetectionResult) {
        self.result = result
    }

    func detectFace(timeout: TimeInterval) async -> CameraFaceDetectionResult {
        requestedTimeouts.append(timeout)
        return result
    }
}

private struct StubAppStateConditionSignalProvider: ConditionSignalProviding {
    let snapshot: ConditionSignalSnapshot

    func currentConditionSignals() -> ConditionSignalSnapshot {
        snapshot
    }
}

private extension ConditionSignalSnapshot {
    static let automationTrusted = ConditionSignalSnapshot(
        wifi: .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"),
        externalDisplays: .connected(["trusted-display-id"]),
        power: .available(.externalPower),
        bluetooth: .inconclusive
    )
}

private final class RecordingAutomaticLockScreenOverlayPresenter: AutomaticLockScreenOverlayPresenting {
    enum Event: Equatable {
        case scanning
        case success
        case failure
        case timeout
        case recognitionPreviewScanning
        case recognitionPreviewRecognized
        case recognitionPreviewFailure
        case dismiss
    }

    private let stateQueue = DispatchQueue(label: "FacePassTests.AutomaticLockScreenOverlayPresenter")
    private var events: [Event] = []

    @MainActor
    func showScanning() {
        stateQueue.sync {
            events.append(.scanning)
        }
    }

    @MainActor
    func showSuccess() {
        stateQueue.sync {
            events.append(.success)
        }
    }

    @MainActor
    func showFailure() {
        stateQueue.sync {
            events.append(.failure)
        }
    }

    @MainActor
    func showTimeout() {
        stateQueue.sync {
            events.append(.timeout)
        }
    }

    @MainActor
    func showRecognitionPreviewScanning() {
        stateQueue.sync {
            events.append(.recognitionPreviewScanning)
        }
    }

    @MainActor
    func showRecognitionPreviewRecognized() {
        stateQueue.sync {
            events.append(.recognitionPreviewRecognized)
        }
    }

    @MainActor
    func showRecognitionPreviewFailure() {
        stateQueue.sync {
            events.append(.recognitionPreviewFailure)
        }
    }

    @MainActor
    func dismiss() {
        stateQueue.sync {
            events.append(.dismiss)
        }
    }

    func recordedEvents() -> [Event] {
        stateQueue.sync {
            events
        }
    }
}

private final class PausingFacePresenceDetector: FacePresenceDetecting {
    let firstRequestStarted = XCTestExpectation(description: "First face presence request started")
    private let stateQueue = DispatchQueue(label: "FacePassTests.PausingFacePresenceDetector")
    private var finishContinuation: CheckedContinuation<CameraFaceDetectionResult, Never>?
    private var requestedTimeouts: [TimeInterval] = []

    func detectFace(timeout: TimeInterval) async -> CameraFaceDetectionResult {
        let requestCount = stateQueue.sync {
            requestedTimeouts.append(timeout)
            return requestedTimeouts.count
        }

        guard requestCount == 1 else {
            return .timedOut
        }

        return await withCheckedContinuation { continuation in
            stateQueue.sync {
                finishContinuation = continuation
            }
            firstRequestStarted.fulfill()
        }
    }

    func finishFirstRequest(with result: CameraFaceDetectionResult) {
        let finishContinuation = stateQueue.sync {
            let finishContinuation = self.finishContinuation
            self.finishContinuation = nil
            return finishContinuation
        }

        finishContinuation?.resume(returning: result)
    }

    func recordedTimeouts() -> [TimeInterval] {
        stateQueue.sync {
            requestedTimeouts
        }
    }
}

private final class StubCameraPermissionProvider: CameraFaceDetectionPermissionProviding {
    private(set) var currentStatus: CameraFaceDetectionPermissionStatus
    private let requestedStatus: CameraFaceDetectionPermissionStatus
    private(set) var requestCount = 0

    init(
        currentStatus: CameraFaceDetectionPermissionStatus,
        requestedStatus: CameraFaceDetectionPermissionStatus
    ) {
        self.currentStatus = currentStatus
        self.requestedStatus = requestedStatus
    }

    func cameraAuthorizationStatus() -> CameraFaceDetectionPermissionStatus {
        currentStatus
    }

    func requestCameraAuthorization() async -> CameraFaceDetectionPermissionStatus {
        requestCount += 1
        currentStatus = requestedStatus
        return requestedStatus
    }
}

private final class IsolatedUserDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(suiteName: String, defaults: UserDefaults) {
        self.suiteName = suiteName
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum AppStateManagerTestError: Error {
    case imageCreationFailed
    case unexpectedEnrollment
}

private final class RecordingAppStateUnlockScheduler: UnlockScheduler {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var scheduledActions: [() -> Void] = []

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduledDelays.append(delay)
        scheduledActions.append(action)
    }

    func runNext() {
        guard !scheduledActions.isEmpty else {
            return
        }

        scheduledActions.removeFirst()()
    }
}

private final class FailingAppStateRecognitionSampleCapture: FaceRecognitionSampleCapturing {
    private(set) var requestedTimeouts: [TimeInterval] = []

    func captureSample(timeout: TimeInterval) async -> FaceSampleCaptureResult {
        requestedTimeouts.append(timeout)
        XCTFail("StandBy Unlock must not invoke local Mac camera recognition.")
        return .timedOut
    }
}

private final class StubStandByUnlockVerifier: StandByUnlockVerifying {
    enum Result {
        case verified(StandByVerifiedUnlockRequest)
        case rejected(StandByUnlockVerificationError)
    }

    private let result: Result
    private(set) var verifiedRequestIds: [String] = []

    init(result: Result) {
        self.result = result
    }

    func verify(_ request: StandByUnlockRequest) throws -> StandByVerifiedUnlockRequest {
        switch result {
        case let .verified(verifiedRequest):
            verifiedRequestIds.append(request.requestId)
            return verifiedRequest
        case let .rejected(error):
            throw error
        }
    }
}

private final class RecordingDisplayWakeController: DisplayWakeControlling {
    private(set) var wakeCount = 0

    func wakeDisplay() {
        wakeCount += 1
    }
}

private final class RecordingStandByPairedDeviceStore: StandByPairedDeviceStoring {
    private var devices: [String: StandByPairedDevice]
    private let allowsCurrentLookup: Bool
    private(set) var savedDevices: [StandByPairedDevice] = []
    private(set) var deletedDeviceIDs: [String] = []
    private(set) var deleteAllCount = 0

    init(device: StandByPairedDevice? = nil, allowsCurrentLookup: Bool = true) {
        self.devices = device.map { [$0.iphoneDeviceId: $0] } ?? [:]
        self.allowsCurrentLookup = allowsCurrentLookup
    }

    init(devices: [StandByPairedDevice], allowsCurrentLookup: Bool = true) {
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.iphoneDeviceId, $0) })
        self.allowsCurrentLookup = allowsCurrentLookup
    }

    func pairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws -> StandByPairedDevice? {
        devices[iphoneDeviceId]
    }

    func currentPairedDevice() throws -> StandByPairedDevice? {
        guard allowsCurrentLookup else {
            return nil
        }

        return devices.values.sorted { $0.createdAt > $1.createdAt }.first
    }

    func savePairedDevice(_ device: StandByPairedDevice) throws {
        devices[device.iphoneDeviceId] = device
        savedDevices.append(device)
    }

    func deletePairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws {
        devices[iphoneDeviceId] = nil
        deletedDeviceIDs.append(iphoneDeviceId)
    }

    func deleteAllPairedDevices() throws {
        devices.removeAll()
        deleteAllCount += 1
    }

    var remainingDeviceIDs: [String] {
        devices.keys.sorted()
    }
}

private final class StubStandByHTTPServerStatusProvider: StandByHTTPServerStatusProviding {
    var httpStatus: StandByUnlockHTTPServerStatus
    var bonjourStatusDescription: String?

    init(
        httpStatus: StandByUnlockHTTPServerStatus,
        bonjourStatusDescription: String? = nil
    ) {
        self.httpStatus = httpStatus
        self.bonjourStatusDescription = bonjourStatusDescription
    }
}

private func standbyAppStateDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }
    return date
}

private extension XCTestCase {
    func waitUntil(
        timeout: TimeInterval = 1,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for async condition.", file: file, line: line)
    }
}
