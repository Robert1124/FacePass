import Foundation

public struct AutomationConditionSettings: Equatable {
    public var isAutomaticAuthorizationPromptFillEnabled: Bool
    public var isConditionGateEnabled: Bool
    public var matchMode: AutomationConditionMatchMode
    public var requiresWiFiConnected: Bool
    public var requiresExternalDisplayConnected: Bool
    public var allowedPowerStates: Set<PowerState>

    public init(
        isAutomaticAuthorizationPromptFillEnabled: Bool = true,
        isConditionGateEnabled: Bool = false,
        matchMode: AutomationConditionMatchMode = .any,
        requiresWiFiConnected: Bool = false,
        requiresExternalDisplayConnected: Bool = false,
        allowedPowerStates: Set<PowerState> = []
    ) {
        self.isAutomaticAuthorizationPromptFillEnabled = isAutomaticAuthorizationPromptFillEnabled
        self.isConditionGateEnabled = isConditionGateEnabled
        self.matchMode = matchMode
        self.requiresWiFiConnected = requiresWiFiConnected
        self.requiresExternalDisplayConnected = requiresExternalDisplayConnected
        self.allowedPowerStates = allowedPowerStates
    }

    public var selectedConditionCount: Int {
        var count = 0
        if requiresWiFiConnected {
            count += 1
        }
        if requiresExternalDisplayConnected {
            count += 1
        }
        if !allowedPowerStates.isEmpty {
            count += 1
        }
        return count
    }
}

public enum AutomationConditionMatchMode: String, CaseIterable, Equatable, CustomStringConvertible {
    case any
    case all

    public var description: String {
        switch self {
        case .any:
            "Any selected condition"
        case .all:
            "All selected conditions"
        }
    }
}

public final class AutomationConditionSettingsStore {
    private enum Key {
        static let automaticAuthorizationPromptFillEnabled = "FacePass.automation.automaticAuthorizationPromptFillEnabled"
        static let conditionGateEnabled = "FacePass.automation.conditionGateEnabled"
        static let matchMode = "FacePass.automation.matchMode"
        static let requiresWiFiConnected = "FacePass.automation.requiresWiFiConnected"
        static let requiresExternalDisplayConnected = "FacePass.automation.requiresExternalDisplayConnected"
        static let allowedPowerStates = "FacePass.automation.allowedPowerStates"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> AutomationConditionSettings {
        AutomationConditionSettings(
            isAutomaticAuthorizationPromptFillEnabled: bool(
                forKey: Key.automaticAuthorizationPromptFillEnabled,
                defaultValue: true
            ),
            isConditionGateEnabled: userDefaults.bool(forKey: Key.conditionGateEnabled),
            matchMode: (userDefaults.string(forKey: Key.matchMode))
                .flatMap(AutomationConditionMatchMode.init(rawValue:)) ?? .any,
            requiresWiFiConnected: userDefaults.bool(forKey: Key.requiresWiFiConnected),
            requiresExternalDisplayConnected: userDefaults.bool(forKey: Key.requiresExternalDisplayConnected),
            allowedPowerStates: Set(
                userDefaults.stringArray(forKey: Key.allowedPowerStates)?
                    .compactMap(PowerState.init(storageValue:)) ?? []
            )
        )
    }

    public func save(_ settings: AutomationConditionSettings) {
        userDefaults.set(
            settings.isAutomaticAuthorizationPromptFillEnabled,
            forKey: Key.automaticAuthorizationPromptFillEnabled
        )
        userDefaults.set(settings.isConditionGateEnabled, forKey: Key.conditionGateEnabled)
        userDefaults.set(settings.matchMode.rawValue, forKey: Key.matchMode)
        userDefaults.set(settings.requiresWiFiConnected, forKey: Key.requiresWiFiConnected)
        userDefaults.set(
            settings.requiresExternalDisplayConnected,
            forKey: Key.requiresExternalDisplayConnected
        )
        userDefaults.set(
            settings.allowedPowerStates
                .map(\.storageValue)
                .sorted(),
            forKey: Key.allowedPowerStates
        )
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return userDefaults.bool(forKey: key)
    }
}

public struct AutomationConditionEvaluator {
    private let signalProvider: any ConditionSignalProviding

    public init(signalProvider: any ConditionSignalProviding = UnavailableConditionSignalProvider()) {
        self.signalProvider = signalProvider
    }

    public func evaluate(settings: AutomationConditionSettings) -> AutomationConditionEvaluation {
        guard settings.isConditionGateEnabled else {
            return AutomationConditionEvaluation(
                isAllowed: true,
                matchMode: settings.matchMode,
                results: [],
                summary: "Trusted conditions are off for automatic actions."
            )
        }

        guard settings.selectedConditionCount > 0 else {
            return AutomationConditionEvaluation(
                isAllowed: false,
                matchMode: settings.matchMode,
                results: [],
                summary: "No trusted conditions selected; automatic actions are disabled."
            )
        }

        let snapshot = signalProvider.currentConditionSignals()
        var results: [AutomationConditionCheckResult] = []

        if settings.requiresWiFiConnected {
            results.append(evaluateWiFi(snapshot.wifi))
        }

        if settings.requiresExternalDisplayConnected {
            results.append(evaluateExternalDisplay(snapshot.externalDisplays))
        }

        if !settings.allowedPowerStates.isEmpty {
            results.append(evaluatePower(snapshot.power, allowedStates: settings.allowedPowerStates))
        }

        let isAllowed: Bool
        switch settings.matchMode {
        case .any:
            isAllowed = results.contains { $0.status == .satisfied }
        case .all:
            isAllowed = results.allSatisfy { $0.status == .satisfied }
        }

        return AutomationConditionEvaluation(
            isAllowed: isAllowed,
            matchMode: settings.matchMode,
            results: results,
            summary: summary(isAllowed: isAllowed, matchMode: settings.matchMode, results: results)
        )
    }

    private func evaluateWiFi(_ signal: WiFiConditionSignal) -> AutomationConditionCheckResult {
        switch signal {
        case let .available(ssid, bssid):
            let isConnected = ssid?.isEmpty == false || bssid?.isEmpty == false
            return AutomationConditionCheckResult(
                condition: .wifiConnected,
                status: isConnected ? .satisfied : .notSatisfied,
                reason: isConnected ? .satisfied : .notConnected
            )
        case .unavailable:
            return AutomationConditionCheckResult(
                condition: .wifiConnected,
                status: .notSatisfied,
                reason: .signalUnavailable
            )
        case .inconclusive:
            return AutomationConditionCheckResult(
                condition: .wifiConnected,
                status: .notSatisfied,
                reason: .signalInconclusive
            )
        }
    }

    private func evaluateExternalDisplay(
        _ signal: ExternalDisplayConditionSignal
    ) -> AutomationConditionCheckResult {
        switch signal {
        case let .connected(displayIDs):
            let hasExternalDisplay = !displayIDs.isEmpty
            return AutomationConditionCheckResult(
                condition: .externalDisplayConnected,
                status: hasExternalDisplay ? .satisfied : .notSatisfied,
                reason: hasExternalDisplay ? .satisfied : .notConnected
            )
        case .unavailable:
            return AutomationConditionCheckResult(
                condition: .externalDisplayConnected,
                status: .notSatisfied,
                reason: .signalUnavailable
            )
        case .inconclusive:
            return AutomationConditionCheckResult(
                condition: .externalDisplayConnected,
                status: .notSatisfied,
                reason: .signalInconclusive
            )
        }
    }

    private func evaluatePower(
        _ signal: PowerConditionSignal,
        allowedStates: Set<PowerState>
    ) -> AutomationConditionCheckResult {
        switch signal {
        case let .available(state):
            let isAllowedState = allowedStates.contains(state)
            return AutomationConditionCheckResult(
                condition: .powerState,
                status: isAllowedState ? .satisfied : .notSatisfied,
                reason: isAllowedState ? .satisfied : .valueMismatch
            )
        case .unavailable:
            return AutomationConditionCheckResult(
                condition: .powerState,
                status: .notSatisfied,
                reason: .signalUnavailable
            )
        case .inconclusive:
            return AutomationConditionCheckResult(
                condition: .powerState,
                status: .notSatisfied,
                reason: .signalInconclusive
            )
        }
    }

    private func summary(
        isAllowed: Bool,
        matchMode: AutomationConditionMatchMode,
        results: [AutomationConditionCheckResult]
    ) -> String {
        let matchingLabels = results
            .filter { $0.status == .satisfied }
            .map { $0.condition.title }
        let blockedLabels = results
            .filter { $0.status != .satisfied }
            .map { $0.condition.title }

        if isAllowed {
            let labels = matchingLabels.isEmpty ? "selected conditions" : matchingLabels.joined(separator: ", ")
            return "\(matchMode.description) passed: \(labels)."
        }

        let labels = blockedLabels.isEmpty ? "selected conditions" : blockedLabels.joined(separator: ", ")
        return "\(matchMode.description) not met: \(labels)."
    }
}

public struct AutomationConditionEvaluation: Equatable, CustomStringConvertible {
    public let isAllowed: Bool
    public let matchMode: AutomationConditionMatchMode
    public let results: [AutomationConditionCheckResult]
    public let summary: String

    public var description: String {
        "AutomationConditionEvaluation(isAllowed: \(isAllowed), matchMode: \(matchMode), results: \(results.map(\.safeDescription)), summary: \(summary))"
    }
}

public struct AutomationConditionCheckResult: Equatable {
    public let condition: AutomationConditionKind
    public let status: AutomationConditionStatus
    public let reason: AutomationConditionReason

    fileprivate var safeDescription: String {
        "\(condition.title): \(status) (\(reason))"
    }
}

public enum AutomationConditionKind: Equatable {
    case wifiConnected
    case externalDisplayConnected
    case powerState

    public var title: String {
        switch self {
        case .wifiConnected:
            "Wi-Fi connected"
        case .externalDisplayConnected:
            "External monitor connected"
        case .powerState:
            "Power state"
        }
    }
}

public enum AutomationConditionStatus: Equatable {
    case satisfied
    case notSatisfied
}

public enum AutomationConditionReason: Equatable {
    case satisfied
    case notConnected
    case signalUnavailable
    case signalInconclusive
    case valueMismatch
}

private extension PowerState {
    var storageValue: String {
        switch self {
        case .externalPower:
            "externalPower"
        case .battery:
            "battery"
        case .charging:
            "charging"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "externalPower":
            self = .externalPower
        case "battery":
            self = .battery
        case "charging":
            self = .charging
        default:
            return nil
        }
    }
}
