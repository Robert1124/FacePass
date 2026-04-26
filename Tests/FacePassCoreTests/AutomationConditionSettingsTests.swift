import XCTest
@testable import FacePassCore

final class AutomationConditionSettingsTests: XCTestCase {
    func testDefaultsEnableAutomaticPromptFillButDoNotGateAutomaticActions() {
        let settings = AutomationConditionSettings()
        let evaluator = AutomationConditionEvaluator(
            signalProvider: StubAutomationConditionSignalProvider(snapshot: .automationTrusted)
        )

        let evaluation = evaluator.evaluate(settings: settings)

        XCTAssertTrue(settings.isAutomaticAuthorizationPromptFillEnabled)
        XCTAssertFalse(settings.isConditionGateEnabled)
        XCTAssertEqual(settings.matchMode, .any)
        XCTAssertFalse(settings.requiresWiFiConnected)
        XCTAssertFalse(settings.requiresExternalDisplayConnected)
        XCTAssertTrue(settings.allowedPowerStates.isEmpty)
        XCTAssertTrue(evaluation.isAllowed)
        XCTAssertEqual(evaluation.summary, "Trusted conditions are off for automatic actions.")
    }

    func testConditionGateWithNoSelectedConditionsFailsClosed() {
        let settings = AutomationConditionSettings(isConditionGateEnabled: true)
        let evaluator = AutomationConditionEvaluator(
            signalProvider: StubAutomationConditionSignalProvider(snapshot: .automationTrusted)
        )

        let evaluation = evaluator.evaluate(settings: settings)

        XCTAssertFalse(evaluation.isAllowed)
        XCTAssertEqual(evaluation.summary, "No trusted conditions selected; automatic actions are disabled.")
    }

    func testAnyModeAllowsAutomaticActionsWhenOneSelectedConditionPasses() {
        let settings = AutomationConditionSettings(
            isConditionGateEnabled: true,
            matchMode: .any,
            requiresWiFiConnected: true,
            requiresExternalDisplayConnected: true,
            allowedPowerStates: [.externalPower]
        )
        let evaluator = AutomationConditionEvaluator(
            signalProvider: StubAutomationConditionSignalProvider(snapshot: ConditionSignalSnapshot(
                wifi: .unavailable,
                externalDisplays: .connected([]),
                power: .available(.externalPower),
                bluetooth: .inconclusive
            ))
        )

        let evaluation = evaluator.evaluate(settings: settings)

        XCTAssertTrue(evaluation.isAllowed)
        XCTAssertEqual(settings.matchMode.description, "Any selected condition")
        XCTAssertTrue(evaluation.summary.contains("Power"))
        XCTAssertFalse(evaluation.summary.contains("TrustedWiFi"))
        XCTAssertFalse(evaluation.summary.contains("AA:BB:CC:DD:EE:FF"))
    }

    func testAllModeRequiresEverySelectedConditionCategoryToPass() {
        let settings = AutomationConditionSettings(
            isConditionGateEnabled: true,
            matchMode: .all,
            requiresWiFiConnected: true,
            requiresExternalDisplayConnected: true,
            allowedPowerStates: [.externalPower, .charging]
        )
        let blockedEvaluator = AutomationConditionEvaluator(
            signalProvider: StubAutomationConditionSignalProvider(snapshot: ConditionSignalSnapshot(
                wifi: .available(ssid: "ObservedWiFi", bssid: "11:22:33:44:55:66"),
                externalDisplays: .connected(["observed-display-id"]),
                power: .available(.battery),
                bluetooth: .available([BluetoothDeviceSignal(deviceID: "observed-watch")])
            ))
        )
        let allowedEvaluator = AutomationConditionEvaluator(
            signalProvider: StubAutomationConditionSignalProvider(snapshot: ConditionSignalSnapshot(
                wifi: .available(ssid: "ObservedWiFi", bssid: "11:22:33:44:55:66"),
                externalDisplays: .connected(["observed-display-id"]),
                power: .available(.charging),
                bluetooth: .available([BluetoothDeviceSignal(deviceID: "observed-watch")])
            ))
        )

        let blockedEvaluation = blockedEvaluator.evaluate(settings: settings)
        let allowedEvaluation = allowedEvaluator.evaluate(settings: settings)

        XCTAssertFalse(blockedEvaluation.isAllowed)
        XCTAssertTrue(allowedEvaluation.isAllowed)
        XCTAssertEqual(settings.matchMode.description, "All selected conditions")
        XCTAssertFalse(String(describing: blockedEvaluation).contains("ObservedWiFi"))
        XCTAssertFalse(String(describing: blockedEvaluation).contains("11:22:33:44:55:66"))
        XCTAssertFalse(String(describing: blockedEvaluation).contains("observed-display-id"))
        XCTAssertFalse(String(describing: blockedEvaluation).contains("observed-watch"))
    }

    func testUserDefaultsStorePersistsOnlyNonSensitiveAutomationPolicy() {
        let isolatedDefaults = makeIsolatedUserDefaults()
        let store = AutomationConditionSettingsStore(userDefaults: isolatedDefaults.defaults)
        let settings = AutomationConditionSettings(
            isAutomaticAuthorizationPromptFillEnabled: false,
            isConditionGateEnabled: true,
            matchMode: .all,
            requiresWiFiConnected: true,
            requiresExternalDisplayConnected: true,
            allowedPowerStates: [.externalPower, .battery]
        )

        store.save(settings)
        let reloadedSettings = store.load()

        XCTAssertEqual(reloadedSettings, settings)
        let persistedValues = isolatedDefaults.defaults
            .persistentDomain(forName: isolatedDefaults.suiteName)?
            .values
            .map { String(describing: $0) }
            .joined(separator: " ") ?? ""
        XCTAssertFalse(persistedValues.contains("TrustedWiFi"))
        XCTAssertFalse(persistedValues.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(persistedValues.contains("observed-display-id"))
    }

    private func makeIsolatedUserDefaults() -> IsolatedUserDefaults {
        let suiteName = "FacePass.AutomationConditionSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Expected isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedUserDefaults(suiteName: suiteName, defaults: defaults)
    }
}

private struct StubAutomationConditionSignalProvider: ConditionSignalProviding {
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
