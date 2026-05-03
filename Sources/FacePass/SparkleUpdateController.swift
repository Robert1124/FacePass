import AppKit
import Sparkle

@MainActor
final class SparkleUpdateController: NSObject {
    private static let feedURL = "https://facepass.app/updates/appcast.xml"

    private lazy var standardUpdaterController: SPUStandardUpdaterController? = {
        guard isRuntimeConfigured else {
            return nil
        }

        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    func checkForUpdates(_ sender: Any?) {
        guard let standardUpdaterController else {
            showMissingConfigurationAlert()
            return
        }

        standardUpdaterController.checkForUpdates(sender)
    }

    private var isRuntimeConfigured: Bool {
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            feedURL == Self.feedURL,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showMissingConfigurationAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates are not configured for this build."
        alert.informativeText = """
        This local FacePass build does not include a Sparkle update-signing public key. Release packaging must provide FACEPASS_SPARKLE_PUBLIC_ED_KEY.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
