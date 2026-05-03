import ActivityKit
import AppIntents
import Foundation
import FacePassCompanionCore

@available(iOS 17.0, *)
public struct StandByUnlockIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Unlock Mac"
    public static var description = IntentDescription("Sends a signed local FacePass StandBy Unlock request to a paired Mac.")
    public static var openAppWhenRun = false
    public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    public func perform() async throws -> some IntentResult {
        await Self.updateActivities(.sending)

        do {
            let client = try StandByIntentDependencies.makeUnlockClient()
            let result = try await client.requestUnlock()
            let presentation = StandByUnlockPresentation(result: result)
            await Self.updateActivities(presentation)
            return .result(dialog: presentation.dialog)
        } catch {
            let presentation = StandByUnlockPresentation(error: error)
            await Self.updateActivities(presentation)
            return .result(dialog: presentation.dialog)
        }
    }

    private static func updateActivities(_ presentation: StandByUnlockPresentation) async {
        let state = StandByUnlockActivityAttributes.ContentState(
            status: presentation.statusText,
            lastRequestAt: presentation.lastRequestAt,
            isRequestInFlight: presentation.isRequestInFlight
        )
        let content = ActivityContent(state: state, staleDate: nil)

        for activity in Activity<StandByUnlockActivityAttributes>.activities {
            await activity.update(content)
        }
    }
}

@available(iOS 17.0, *)
public struct FacePassCompanionShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StandByUnlockIntent(),
            phrases: [
                "Unlock Mac with \(.applicationName)",
                "Send FacePass unlock with \(.applicationName)",
                "\(.applicationName) unlock Mac"
            ],
            shortTitle: "Unlock Mac",
            systemImageName: "lock.open"
        )
    }
}

@available(iOS 17.0, *)
private enum StandByUnlockPresentation {
    case sending
    case unlockSent
    case notPaired
    case macNotLocked
    case disabled
    case conditionsNotSatisfied
    case accessibilityDenied
    case passwordMissing
    case macNotReachable
    case requestRejected
    case failed

    init(result: StandByUnlockResult) {
        guard result.ok else {
            self = Self.failure(for: result.errorCode)
            return
        }

        self = .unlockSent
    }

    init(error: Error) {
        if let error = error as? BonjourRediscoveryError {
            switch error {
            case .notFound, .timeout, .searchFailed:
                self = .macNotReachable
            }
            return
        }

        if error is URLError {
            self = .macNotReachable
            return
        }

        self = .failed
    }

    var statusText: String {
        switch self {
        case .sending:
            "Sending unlock..."
        case .unlockSent:
            "Unlock sent"
        case .notPaired:
            "Pair Mac first"
        case .macNotLocked:
            "Mac not locked"
        case .disabled:
            "StandBy Unlock disabled"
        case .conditionsNotSatisfied:
            "Conditions not met"
        case .accessibilityDenied:
            "Mac permission needed"
        case .passwordMissing:
            "Mac password missing"
        case .macNotReachable:
            "Mac not reachable"
        case .requestRejected:
            "Request rejected"
        case .failed:
            "Unlock request failed"
        }
    }

    var dialog: IntentDialog {
        switch self {
        case .sending:
            "Sending unlock"
        case .unlockSent:
            "Unlock sent"
        case .notPaired:
            "Pair FacePass with your Mac first"
        case .macNotLocked:
            "Mac not locked"
        case .disabled:
            "StandBy Unlock disabled"
        case .conditionsNotSatisfied:
            "Conditions not met"
        case .accessibilityDenied:
            "Mac permission needed"
        case .passwordMissing:
            "Mac password missing"
        case .macNotReachable:
            "Mac not reachable"
        case .requestRejected:
            "Request rejected"
        case .failed:
            "Unlock request failed"
        }
    }

    var isRequestInFlight: Bool {
        self == .sending
    }

    var lastRequestAt: Date? {
        isRequestInFlight ? nil : Date()
    }

    private static func failure(for code: String?) -> Self {
        switch code {
        case "not_paired":
            .notPaired
        case "mac_not_locked":
            .macNotLocked
        case "disabled":
            .disabled
        case "conditions_not_satisfied":
            .conditionsNotSatisfied
        case "accessibility_denied":
            .accessibilityDenied
        case "password_missing":
            .passwordMissing
        case "invalid_endpoint", "network_error", "request_failed":
            .macNotReachable
        case "invalid_signature", "expired", "replay_detected", "wrong_mac", "invalid_request":
            .requestRejected
        default:
            .failed
        }
    }
}
