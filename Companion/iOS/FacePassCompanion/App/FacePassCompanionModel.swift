import FacePassCompanionCore
import Combine
import Foundation

@MainActor
final class FacePassCompanionModel: ObservableObject {
    @Published private(set) var pairedMac: PairedMac?
    @Published private(set) var setupErrorMessage: String?
    @Published private(set) var lastUnlockStatus = "No unlock request sent yet."
    @Published private(set) var lastLiveActivityStatus = "Live Activity card has not been started."
    @Published var isPairingPresented = false

    private let endpointCache: EndpointCaching?
    private let pairingClient: PairingClient?
    private let unlockClient: StandByUnlockClient?
    private let liveActivityController: StandByLiveActivityController

    init(configuration: FacePassCompanionConfiguration) {
        let endpointCache = EndpointCache(configuration: configuration)
        self.endpointCache = endpointCache
        self.liveActivityController = StandByLiveActivityController()

        do {
            let keyStore = try CompanionKeyStore(configuration: configuration)
            let rediscoveryService = BonjourRediscoveryService()
            let counterStore = UserDefaultsStandByUnlockCounterStore(configuration: configuration)
            self.pairingClient = PairingClient(
                endpointCache: endpointCache,
                rediscoveryService: rediscoveryService,
                keyStore: keyStore,
                configuration: configuration
            )
            self.unlockClient = StandByUnlockClient(
                endpointCache: endpointCache,
                rediscoveryService: rediscoveryService,
                keyStore: keyStore,
                counterStore: counterStore
            )
            reloadPairedMac()
        } catch {
            self.pairingClient = nil
            self.unlockClient = nil
            self.setupErrorMessage = Self.startupMessage(for: error)
        }
    }

    func reloadPairedMac() {
        guard let endpointCache else {
            return
        }

        do {
            pairedMac = try endpointCache.loadPairedMac()
            if pairedMac == nil {
                isPairingPresented = true
            }
        } catch {
            setupErrorMessage = "FacePass could not read the saved Mac pairing. Pair the Mac again to continue."
        }
    }

    func pair(with payload: PairingQRCodePayload) async throws {
        guard let pairingClient else {
            throw FacePassCompanionModelError.servicesUnavailable
        }

        let mac = try await pairingClient.pair(with: payload)
        pairedMac = mac
        isPairingPresented = false
        lastUnlockStatus = "No unlock request sent yet."
        lastLiveActivityStatus = "Live Activity card has not been started."
    }

    func requestUnlock() async {
        guard let unlockClient else {
            lastUnlockStatus = Self.displayText(for: "request_failed")
            return
        }

        lastUnlockStatus = "Requesting unlock from paired Mac..."

        do {
            let result = try await unlockClient.requestUnlock()
            lastUnlockStatus = Self.displayText(for: result)
            reloadPairedMac()
        } catch {
            lastUnlockStatus = Self.displayText(for: "request_failed")
        }
    }

    func startOrRefreshLiveActivity() async {
        guard let pairedMac else {
            lastLiveActivityStatus = "Pair a Mac before starting the Live Activity card."
            return
        }

        do {
            lastLiveActivityStatus = try await liveActivityController.startOrUpdate(
                for: pairedMac,
                status: "FacePass Ready"
            )
        } catch {
            lastLiveActivityStatus = Self.displayText(forLiveActivityError: error)
        }
    }

    func forgetPairedMac() {
        guard let endpointCache else {
            return
        }

        do {
            try endpointCache.clearPairedMac()
            pairedMac = nil
            isPairingPresented = true
            lastUnlockStatus = "No unlock request sent yet."
            lastLiveActivityStatus = "Live Activity card has not been started."
        } catch {
            setupErrorMessage = "FacePass could not forget the paired Mac. Try again from Settings."
        }
    }

    private static func startupMessage(for error: Error) -> String {
        if error is CompanionKeyStoreError {
            return "FacePass could not prepare its iPhone signing key in Keychain. Unlock this iPhone and reopen the app."
        }

        return "FacePass could not finish setup. Reopen the app and pair the Mac again if the problem continues."
    }

    private static func displayText(for result: StandByUnlockResult) -> String {
        if result.ok {
            return displayText(for: result.result ?? "unlock_requested")
        }

        return displayText(for: result.errorCode ?? "request_failed")
    }

    private static func displayText(for code: String) -> String {
        switch code {
        case "unlock_requested":
            "Unlock request sent to the paired Mac."
        case "mac_not_locked":
            "The paired Mac is not locked."
        case "not_paired":
            "Pair a Mac before requesting unlock."
        case "invalid_endpoint":
            "The saved Mac address is no longer valid. Pair the Mac again."
        case "request_failed", "discovery_failed", "timeout":
            "Request failed. Check that the paired Mac is awake and nearby."
        case "disabled":
            "StandBy Unlock is disabled on the paired Mac."
        case "locked_session_required":
            "The Mac rejected the request because it is not at the lock screen."
        default:
            "The Mac returned: \(code.replacingOccurrences(of: "_", with: " "))."
        }
    }

    private static func displayText(forLiveActivityError error: Error) -> String {
        if let error = error as? StandByLiveActivityError {
            return error.localizedDescription
        }

        return "The Live Activity card could not be updated."
    }
}

enum FacePassCompanionModelError: Error {
    case servicesUnavailable
}
