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
        let standByPairedDeviceStore = StandByPairedDeviceStore()
        let standByIdentity = try? MacDeviceIdentityStore().loadOrCreateIdentity()
        let standByStatusProvider = StandByHTTPServerStatusProvider()
        let standByPairingController = standByIdentity.map {
            StandByUnlockPairingController(
                macDeviceId: $0.macDeviceId,
                publicKeyFingerprint: $0.publicKeyFingerprint,
                pairedDeviceStore: standByPairedDeviceStore,
                localEndpointProvider: { standByStatusProvider.localEndpoint }
            )
        }
        let standByVerifier = standByIdentity.map {
            StandByUnlockRequestVerifier(
                macDeviceId: $0.macDeviceId,
                pairedDeviceStore: standByPairedDeviceStore
            )
        }
        let appStateManager = AppStateManager(
            hotkeyManager: .system(),
            recognitionRuntimeController: recognitionRuntimeController,
            standByUnlockVerifier: standByVerifier,
            standByPairingController: standByPairingController,
            standByPairedDeviceStore: standByPairedDeviceStore,
            standByHTTPServerStatusProvider: standByStatusProvider
        )
        _appStateManager = StateObject(wrappedValue: appStateManager)
        AppDelegate.appStateManager = appStateManager
        AppDelegate.standByRuntimeConfiguration = StandByRuntimeConfiguration(
            identity: standByIdentity,
            pairedDeviceStore: standByPairedDeviceStore,
            pairingController: standByPairingController,
            statusProvider: standByStatusProvider
        )
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
    static var standByRuntimeConfiguration: StandByRuntimeConfiguration?

    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var setupWizardWindowController: SetupWizardWindowController?
    private var overlayWindowController: OverlayWindowController?
    private var screenStateMonitor: ScreenStateMonitor?
    private var screenStateNotificationObserver: ScreenStateNotificationObserver?
    private var authorizationPromptMonitor: AuthorizationPromptMonitor?
    private var standByHTTPServer: StandByUnlockHTTPServer?
    private var sparkleUpdateController: SparkleUpdateController?

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
        self.sparkleUpdateController = SparkleUpdateController()
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

        startStandByHTTPServer(appStateManager: appStateManager)
        appStateManager.startManualFillHotkeyRuntime()
        setupWizardWindowController.showOnFirstLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStandByHTTPServer()
        stopScreenStateRuntime()
        stopAuthorizationPromptMonitor()
        Self.appStateManager?.stopManualFillHotkeyRuntime()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        settingsWindowController?.showSettingsWindow()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        sparkleUpdateController?.checkForUpdates(sender)
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

    private func startStandByHTTPServer(appStateManager: AppStateManager) {
        guard let configuration = Self.standByRuntimeConfiguration else {
            return
        }

        let macDeviceId = configuration.identity?.macDeviceId ?? "unavailable"
        let publicKeyFingerprint = configuration.identity?.publicKeyFingerprint ?? "unavailable"
        let isRuntimeAvailable = configuration.identity != nil && configuration.pairingController != nil
        guard let pairingController = configuration.pairingController else {
            return
        }
        let router = StandByUnlockHTTPRouter(
            macDeviceId: macDeviceId,
            protocolVersion: StandByUnlockPairingController.protocolVersion,
            serverStatus: { isRuntimeAvailable ? configuration.statusProvider.httpStatus : .failed },
            publicKeyFingerprint: publicKeyFingerprint,
            isIPhoneUnlockEnabled: { [weak appStateManager] in
                isRuntimeAvailable &&
                    appStateManager?.isStandByUnlockEnabled == true &&
                    appStateManager?.unlockProviderPolicy.allowsAnyIPhoneAction == true
            },
            pairingController: pairingController,
            unlockHandler: { [weak appStateManager] request in
                guard isRuntimeAvailable, let appStateManager else {
                    return .disabled
                }

                await appStateManager.handleStandByUnlockRequest(request)
                return appStateManager.lastStandByUnlockResult ?? .verificationFailed(.replayStoreFailed)
            },
            pairingDidChange: { [weak appStateManager] in
                Task { @MainActor in
                    appStateManager?.refreshStandByUnlockStatus()
                }
            }
        )
        let server = StandByUnlockHTTPServer(
            router: router,
            macDeviceId: macDeviceId,
            publicKeyFingerprint: publicKeyFingerprint
        )
        configuration.statusProvider.server = server

        do {
            try server.start()
            standByHTTPServer = server
            appStateManager.refreshStandByUnlockStatus()
        } catch {
            standByHTTPServer = nil
            appStateManager.refreshStandByUnlockStatus()
        }
    }

    private func stopStandByHTTPServer() {
        standByHTTPServer?.stop()
        standByHTTPServer = nil
    }
}

extension OverlayWindowController: AutomaticLockScreenOverlayPresenting {}

private struct StandByRuntimeConfiguration {
    let identity: MacDeviceIdentity?
    let pairedDeviceStore: any StandByPairedDeviceStoring
    let pairingController: StandByUnlockPairingController?
    let statusProvider: StandByHTTPServerStatusProvider
}

private final class StandByHTTPServerStatusProvider: StandByHTTPServerStatusProviding {
    weak var server: StandByUnlockHTTPServer?

    var httpStatus: StandByUnlockHTTPServerStatus {
        server?.status ?? .failed
    }

    var bonjourStatusDescription: String? {
        switch httpStatus {
        case .ready:
            "Published on _facepass._tcp.local"
        case .starting:
            "Preparing Bonjour advertisement"
        case .failed:
            "StandBy Unlock local server is unavailable"
        case .stopped:
            "StandBy Unlock local server is stopped"
        }
    }

    var localEndpoint: StandByPairingEndpoint? {
        server?.localEndpoint
    }
}
