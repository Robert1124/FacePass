import AppKit
import Combine
import FacePassCore

final class StatusItemController: NSObject {
    private let appStateManager: AppStateManager
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let statusItem: NSStatusItem
    private var presentedMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    init(
        appStateManager: AppStateManager,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.appStateManager = appStateManager
        self.openSettings = openSettings
        self.quit = quit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        observeAppState()
        updateButton()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func observeAppState() {
        appStateManager.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateButton()
                }
            }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem.button else {
            return
        }

        let image = NSImage(
            systemSymbolName: "faceid",
            accessibilityDescription: "FacePass"
        )
        image?.isTemplate = true
        button.image = image
        button.alphaValue = appStateManager.isEnabled ? 1.0 : 0.45
        button.toolTip = appStateManager.isEnabled
            ? "FacePass is enabled. Left-click to disable; right-click for menu."
            : "FacePass is disabled. Left-click to enable; right-click for menu."
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showRightClickMenu()
        default:
            appStateManager.toggleEnabled()
            updateButton()
        }
    }

    private func showRightClickMenu() {
        let menu = makeMenu()
        menu.delegate = self
        presentedMenu = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    private func makeMenu() -> NSMenu {
        appStateManager.refreshPermissions()
        appStateManager.refreshPasswordConfigurationStatus()

        let menu = NSMenu(title: "FacePass")
        menu.autoenablesItems = false

        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabledFromMenu(_:)),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = appStateManager.isEnabled ? .on : .off
        menu.addItem(enabledItem)

        let permissionsItem = NSMenuItem(
            title: appStateManager.areAllPermissionsAcquired
                ? "Permissions: Complete"
                : "Permissions: Needs Attention",
            action: nil,
            keyEquivalent: ""
        )
        permissionsItem.isEnabled = false
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit FacePass",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleEnabledFromMenu(_ sender: NSMenuItem) {
        appStateManager.toggleEnabled()
        updateButton()
    }

    @objc private func openSettingsFromMenu(_ sender: NSMenuItem) {
        openSettings()
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        quit()
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        presentedMenu = nil
    }
}
