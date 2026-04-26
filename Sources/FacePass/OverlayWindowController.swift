import AppKit
import FacePassCore
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let viewModel = OverlayViewModel()
    private var panel: NSPanel?
    private let panelSize = NSSize(width: 184, height: 184)
    private let topInset: CGFloat = 42

    var state: OverlayState {
        viewModel.state
    }

    func showScanning() {
        var nextState = viewModel.state
        nextState.showScanning()
        present(nextState)
    }

    func showSuccess() {
        var nextState = viewModel.state
        nextState.showSuccess()
        present(nextState)
    }

    func showFailure() {
        var nextState = viewModel.state
        nextState.showFailure()
        present(nextState)
    }

    func showTimeout() {
        var nextState = viewModel.state
        nextState.showTimeout()
        present(nextState)
    }

    func showRecognitionPreviewScanning() {
        var nextState = viewModel.state
        nextState.showRecognitionPreviewScanning()
        present(nextState)
    }

    func showRecognitionPreviewRecognized() {
        var nextState = viewModel.state
        nextState.showRecognitionPreviewRecognized()
        present(nextState)
    }

    func showRecognitionPreviewFailure() {
        var nextState = viewModel.state
        nextState.showRecognitionPreviewFailure()
        present(nextState)
    }

    func dismiss() {
        viewModel.state.dismiss()
        panel?.orderOut(nil)
    }

    private func present(_ state: OverlayState) {
        viewModel.state = state

        let panel = ensurePanel()
        let targetFrame = targetFrame(on: panel.screen ?? NSScreen.main)
        let startFrame = targetFrame.offsetBy(dx: 0, dy: panelSize.height + topInset)

        if !panel.isVisible {
            panel.setFrame(startFrame, display: false)
        }

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        self.panel = panel
        return panel
    }

    private func targetFrame(on screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - panelSize.height - topInset

        return NSRect(
            x: x.rounded(.toNearestOrAwayFromZero),
            y: y.rounded(.toNearestOrAwayFromZero),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
