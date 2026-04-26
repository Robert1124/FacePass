import AppKit
import FacePassCore
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let appStateManager: AppStateManager

    init(appStateManager: AppStateManager) {
        self.appStateManager = appStateManager

        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(appStateManager)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "FacePass Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 500))
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showSettingsWindow() {
        appStateManager.refreshPermissions()
        appStateManager.refreshPasswordConfigurationStatus()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window?.centerIfOffscreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private extension NSWindow {
    func centerIfOffscreen() {
        guard let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            center()
            return
        }

        if !screenFrame.intersects(frame) {
            center()
        }
    }
}
