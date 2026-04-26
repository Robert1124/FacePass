import AppKit
import FacePassCore
import SwiftUI

@main
struct FacePassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appStateManager: AppStateManager

    init() {
        let recognitionCameraCaptureController = RecognitionCameraSampleCaptureController()
        let recognitionRuntimeController = FaceRecognitionRuntimeController(
            sampleCaptureService: recognitionCameraCaptureController
        )
        let appStateManager = AppStateManager(
            hotkeyManager: .system(),
            recognitionRuntimeController: recognitionRuntimeController
        )
        _appStateManager = StateObject(wrappedValue: appStateManager)
        AppDelegate.appStateManager = appStateManager
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appStateManager)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    static var appStateManager: AppStateManager?

    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var setupWizardWindowController: SetupWizardWindowController?
    private var overlayWindowController: OverlayWindowController?
    private var screenStateMonitor: ScreenStateMonitor?
    private var screenStateNotificationObserver: ScreenStateNotificationObserver?
    private var authorizationPromptMonitor: AuthorizationPromptMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let appStateManager = Self.appStateManager else {
            return
        }

        let overlayWindowController = OverlayWindowController()
        self.overlayWindowController = overlayWindowController
        appStateManager.setAutomaticLockScreenOverlayPresenter(overlayWindowController)

        let settingsWindowController = SettingsWindowController(appStateManager: appStateManager)
        self.settingsWindowController = settingsWindowController
        self.statusItemController = StatusItemController(
            appStateManager: appStateManager,
            openSettings: { [weak settingsWindowController] in
                settingsWindowController?.showSettingsWindow()
            },
            quit: {
                NSApp.terminate(nil)
            }
        )
        let setupWizardWindowController = SetupWizardWindowController(appStateManager: appStateManager)
        self.setupWizardWindowController = setupWizardWindowController

        let screenStateMonitor = ScreenStateMonitor()
        screenStateMonitor.setEventHandler { [weak appStateManager] event in
            appStateManager?.handleScreenStateEvent(event)
        }
        let screenStateNotificationObserver = ScreenStateNotificationObserver(monitor: screenStateMonitor)
        self.screenStateMonitor = screenStateMonitor
        self.screenStateNotificationObserver = screenStateNotificationObserver
        screenStateNotificationObserver.start()
        appStateManager.setScreenStateMonitorActive(screenStateMonitor.isRuntimeObserverActive)

        let authorizationPromptMonitor = AuthorizationPromptMonitor { [weak appStateManager] in
            await appStateManager?.handleAuthorizationPromptMonitorTick()
        }
        self.authorizationPromptMonitor = authorizationPromptMonitor
        authorizationPromptMonitor.start()
        appStateManager.setAuthorizationPromptMonitorActive(authorizationPromptMonitor.isRunning)

        appStateManager.startManualFillHotkeyRuntime()
        setupWizardWindowController.showOnFirstLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopScreenStateRuntime()
        stopAuthorizationPromptMonitor()
        Self.appStateManager?.stopManualFillHotkeyRuntime()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        settingsWindowController?.showSettingsWindow()
    }

    private func stopScreenStateRuntime() {
        screenStateNotificationObserver?.stop()
        Self.appStateManager?.setScreenStateMonitorActive(
            screenStateMonitor?.isRuntimeObserverActive ?? false
        )
        screenStateNotificationObserver = nil
        screenStateMonitor = nil
    }

    private func stopAuthorizationPromptMonitor() {
        authorizationPromptMonitor?.stop()
        Self.appStateManager?.setAuthorizationPromptMonitorActive(false)
        authorizationPromptMonitor = nil
    }
}

extension OverlayWindowController: AutomaticLockScreenOverlayPresenting {}
