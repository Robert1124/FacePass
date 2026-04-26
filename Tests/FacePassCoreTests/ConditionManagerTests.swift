import XCTest
@testable import FacePassCore

final class ConditionManagerTests: XCTestCase {
    func testMacConditionSignalProviderAggregatesSubproviderSnapshots() {
        let wifiProvider = SpyWiFiConditionSignalProvider(signal: .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"))
        let displayProvider = SpyExternalDisplayConditionSignalProvider(signal: .connected(["studio-display"]))
        let powerProvider = SpyPowerConditionSignalProvider(signal: .available(.externalPower))
        let bluetoothProvider = SpyBluetoothConditionSignalProvider(signal: .inconclusive)
        let provider = MacConditionSignalProvider(
            wifiProvider: wifiProvider,
            externalDisplayProvider: displayProvider,
            powerProvider: powerProvider,
            bluetoothProvider: bluetoothProvider
        )

        let snapshot = provider.currentConditionSignals()

        XCTAssertEqual(snapshot.wifi, .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"))
        XCTAssertEqual(snapshot.externalDisplays, .connected(["studio-display"]))
        XCTAssertEqual(snapshot.power, .available(.externalPower))
        XCTAssertEqual(snapshot.bluetooth, .inconclusive)
        XCTAssertEqual(wifiProvider.callCount, 1)
        XCTAssertEqual(displayProvider.callCount, 1)
        XCTAssertEqual(powerProvider.callCount, 1)
        XCTAssertEqual(bluetoothProvider.callCount, 1)
    }

    func testCoreGraphicsExternalDisplayProviderReturnsConnectedEmptySetWhenOnlyBuiltInDisplaysExist() {
        let provider = CoreGraphicsExternalDisplayConditionSignalProvider {
            .success([
                MacDisplaySnapshot(displayID: "built-in", isBuiltIn: true)
            ])
        }

        let signal = provider.currentExternalDisplaySignal()

        XCTAssertEqual(signal, .connected([]))
    }

    func testCoreGraphicsExternalDisplayProviderPrefersUUIDDisplayIdentifier() {
        let provider = CoreGraphicsExternalDisplayConditionSignalProvider(
            onlineDisplayIDs: { .success([42]) },
            isBuiltInDisplay: { _ in false },
            displayUUIDString: { displayID in
                displayID == 42 ? "stable-display-uuid" : nil
            }
        )

        let signal = provider.currentExternalDisplaySignal()

        XCTAssertEqual(signal, .connected(["stable-display-uuid"]))
    }

    func testCoreGraphicsExternalDisplayProviderFallsBackToNumericIdentifierWhenUUIDIsUnavailable() {
        let provider = CoreGraphicsExternalDisplayConditionSignalProvider(
            onlineDisplayIDs: { .success([42]) },
            isBuiltInDisplay: { _ in false },
            displayUUIDString: { _ in nil }
        )

        let signal = provider.currentExternalDisplaySignal()

        XCTAssertEqual(signal, .connected(["42"]))
    }

    func testCoreGraphicsExternalDisplayProviderReturnsInconclusiveWhenDisplaySnapshotFails() {
        let provider = CoreGraphicsExternalDisplayConditionSignalProvider {
            .failure(.unavailable)
        }

        let signal = provider.currentExternalDisplaySignal()

        XCTAssertEqual(signal, .inconclusive)
    }

    func testMacBluetoothConditionSignalProviderReturnsInconclusiveWithoutSampling() {
        let provider = MacBluetoothConditionSignalProvider()

        XCTAssertEqual(provider.currentBluetoothSignal(), .inconclusive)
    }

    func testNoConfiguredRequiredConditionsDeniesEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: .trusted))

        let result = manager.evaluate(configuration: .allDisabled)

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertTrue(result.reasons.contains(.noRequiredConditionsConfigured))
    }

    func testAllRequiredConditionsSatisfiedAllowsEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: .trusted))
        let configuration = ConditionConfiguration(
            wifi: .required(allowedSSIDs: ["TrustedWiFi"], allowedBSSIDs: ["AA:BB:CC:DD:EE:FF"]),
            externalDisplay: .required(allowedDisplayIDs: ["studio-display"]),
            power: .required(allowedStates: [.externalPower]),
            bluetooth: .required(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        )

        let result = manager.evaluate(configuration: configuration)

        XCTAssertTrue(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.results.filter { $0.status == .satisfied }.count, 4)
    }

    func testMissingRequiredWiFiDeniesEligibility() {
        let snapshot = ConditionSignalSnapshot(
            wifi: .unavailable,
            externalDisplays: .connected(["studio-display"]),
            power: .available(.externalPower),
            bluetooth: .available([.init(deviceID: "trusted-watch", distanceMeters: .available(1.2), proximity: .inconclusive)])
        )
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: snapshot))

        let result = manager.evaluate(configuration: .requiredWiFi)

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .blocked)
        XCTAssertEqual(result.result(for: .wifi)?.reason, .requiredSignalUnavailable)
    }

    func testDefaultUnavailableSignalsDenyRequiredConditions() {
        let manager = ConditionManager()

        let result = manager.evaluate(configuration: .requiredWiFi)

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .blocked)
        XCTAssertEqual(result.result(for: .wifi)?.reason, .requiredSignalUnavailable)
    }

    func testBSSIDMismatchDeniesEligibilityWithoutExposingObservedValues() {
        let snapshot = ConditionSignalSnapshot(
            wifi: .available(ssid: "TrustedWiFi", bssid: "11:22:33:44:55:66"),
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .unavailable
        )
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: snapshot))

        let result = manager.evaluate(configuration: .requiredWiFi)

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .blocked)
        XCTAssertEqual(result.result(for: .wifi)?.reason, .valueMismatch)
        XCTAssertFalse(String(describing: result).contains("11:22:33:44:55:66"))
        XCTAssertFalse(String(describing: result).contains("TrustedWiFi"))
    }

    func testExternalDisplayUnavailableDeniesWhenRequired() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .unavailable,
            externalDisplays: .unavailable,
            power: .available(.externalPower),
            bluetooth: .unavailable
        )))

        let result = manager.evaluate(configuration: ConditionConfiguration(
            externalDisplay: .required(allowedDisplayIDs: ["studio-display"])
        ))

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .externalDisplay)?.status, .blocked)
        XCTAssertEqual(result.result(for: .externalDisplay)?.reason, .requiredSignalUnavailable)
    }

    func testRequiredPowerStateMissingDeniesEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .unavailable,
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .unavailable
        )))

        let result = manager.evaluate(configuration: ConditionConfiguration(
            power: .required(allowedStates: [.externalPower])
        ))

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .power)?.status, .blocked)
        XCTAssertEqual(result.result(for: .power)?.reason, .requiredSignalUnavailable)
    }

    func testBluetoothTooFarDeniesEligibilityWhenRequired() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .unavailable,
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .available([
                .init(deviceID: "trusted-watch", distanceMeters: .available(4.8), proximity: .available(.far))
            ])
        )))

        let result = manager.evaluate(configuration: ConditionConfiguration(
            bluetooth: .required(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        ))

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .bluetooth)?.status, .blocked)
        XCTAssertEqual(result.result(for: .bluetooth)?.reason, .bluetoothDeviceTooFar)
    }

    func testBluetoothUnavailableDeniesEligibilityWhenRequired() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .unavailable,
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .unavailable
        )))

        let result = manager.evaluate(configuration: ConditionConfiguration(
            bluetooth: .required(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        ))

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .bluetooth)?.status, .blocked)
        XCTAssertEqual(result.result(for: .bluetooth)?.reason, .requiredSignalUnavailable)
    }

    func testOptionalMissingConditionDoesNotBlockSatisfiedRequiredCondition() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"),
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .unavailable
        )))
        let configuration = ConditionConfiguration(
            wifi: .required(allowedSSIDs: ["TrustedWiFi"], allowedBSSIDs: ["AA:BB:CC:DD:EE:FF"]),
            externalDisplay: .optional(allowedDisplayIDs: ["studio-display"]),
            power: .optional(allowedStates: [.externalPower]),
            bluetooth: .optional(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        )

        let result = manager.evaluate(configuration: configuration)

        XCTAssertTrue(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .satisfied)
        XCTAssertEqual(result.result(for: .externalDisplay)?.status, .optionalNotSatisfied)
        XCTAssertEqual(result.result(for: .power)?.status, .optionalNotSatisfied)
        XCTAssertEqual(result.result(for: .bluetooth)?.status, .optionalNotSatisfied)
    }

    func testOptionalMismatchedConditionsDoNotBlockSatisfiedRequiredCondition() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"),
            externalDisplays: .connected(["untrusted-display"]),
            power: .available(.battery),
            bluetooth: .available([
                .init(deviceID: "trusted-watch", distanceMeters: .available(8.4), proximity: .available(.far))
            ])
        )))
        let configuration = ConditionConfiguration(
            wifi: .required(allowedSSIDs: ["TrustedWiFi"], allowedBSSIDs: ["AA:BB:CC:DD:EE:FF"]),
            externalDisplay: .optional(allowedDisplayIDs: ["studio-display"]),
            power: .optional(allowedStates: [.externalPower]),
            bluetooth: .optional(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        )

        let result = manager.evaluate(configuration: configuration)

        XCTAssertTrue(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .satisfied)
        XCTAssertEqual(result.result(for: .externalDisplay)?.status, .optionalNotSatisfied)
        XCTAssertEqual(result.result(for: .power)?.status, .optionalNotSatisfied)
        XCTAssertEqual(result.result(for: .bluetooth)?.status, .optionalNotSatisfied)
    }

    func testInconclusiveRequiredSignalDeniesEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .inconclusive,
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .unavailable
        )))

        let result = manager.evaluate(configuration: .requiredWiFi)

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .blocked)
        XCTAssertEqual(result.result(for: .wifi)?.reason, .requiredSignalInconclusive)
    }

    func testInconclusiveRequiredNonWiFiSignalsDenyEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"),
            externalDisplays: .inconclusive,
            power: .inconclusive,
            bluetooth: .inconclusive
        )))
        let configuration = ConditionConfiguration(
            wifi: .required(allowedSSIDs: ["TrustedWiFi"], allowedBSSIDs: ["AA:BB:CC:DD:EE:FF"]),
            externalDisplay: .required(allowedDisplayIDs: ["studio-display"]),
            power: .required(allowedStates: [.externalPower]),
            bluetooth: .required(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        )

        let result = manager.evaluate(configuration: configuration)

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .externalDisplay)?.status, .blocked)
        XCTAssertEqual(result.result(for: .externalDisplay)?.reason, .requiredSignalInconclusive)
        XCTAssertEqual(result.result(for: .power)?.status, .blocked)
        XCTAssertEqual(result.result(for: .power)?.reason, .requiredSignalInconclusive)
        XCTAssertEqual(result.result(for: .bluetooth)?.status, .blocked)
        XCTAssertEqual(result.result(for: .bluetooth)?.reason, .requiredSignalInconclusive)
    }

    func testRequiredWiFiMissingConfiguredObservedValueDeniesEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .available(ssid: nil, bssid: "AA:BB:CC:DD:EE:FF"),
            externalDisplays: .unavailable,
            power: .unavailable,
            bluetooth: .unavailable
        )))

        let result = manager.evaluate(configuration: ConditionConfiguration(
            wifi: .required(allowedSSIDs: ["TrustedWiFi"])
        ))

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .blocked)
        XCTAssertEqual(result.result(for: .wifi)?.reason, .requiredSignalUnavailable)
    }

    func testDiagnosticsDoNotExposeObservedDisplayOrBluetoothValues() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: ConditionSignalSnapshot(
            wifi: .available(ssid: "ObservedWiFi", bssid: "11:22:33:44:55:66"),
            externalDisplays: .connected(["observed-display"]),
            power: .available(.battery),
            bluetooth: .available([
                .init(deviceID: "observed-watch", distanceMeters: .available(7.9), proximity: .available(.far))
            ])
        )))
        let configuration = ConditionConfiguration(
            wifi: .required(allowedSSIDs: ["TrustedWiFi"], allowedBSSIDs: ["AA:BB:CC:DD:EE:FF"]),
            externalDisplay: .required(allowedDisplayIDs: ["studio-display"]),
            power: .required(allowedStates: [.externalPower]),
            bluetooth: .required(deviceID: "trusted-watch", maximumDistanceMeters: 2.0)
        )

        let resultDescription = String(describing: manager.evaluate(configuration: configuration))

        XCTAssertFalse(resultDescription.contains("ObservedWiFi"))
        XCTAssertFalse(resultDescription.contains("11:22:33:44:55:66"))
        XCTAssertFalse(resultDescription.contains("observed-display"))
        XCTAssertFalse(resultDescription.contains("observed-watch"))
        XCTAssertFalse(resultDescription.contains("7.9"))
    }

    func testMisconfiguredRequiredConditionDeniesEligibility() {
        let manager = ConditionManager(signalProvider: StubConditionSignalProvider(snapshot: .trusted))

        let result = manager.evaluate(configuration: ConditionConfiguration(
            wifi: .required(allowedSSIDs: [], allowedBSSIDs: [])
        ))

        XCTAssertFalse(result.isEligibleForAutoUnlock)
        XCTAssertEqual(result.result(for: .wifi)?.status, .blocked)
        XCTAssertEqual(result.result(for: .wifi)?.reason, .requiredConditionMisconfigured)
    }
}

private struct StubConditionSignalProvider: ConditionSignalProviding {
    let snapshot: ConditionSignalSnapshot

    func currentConditionSignals() -> ConditionSignalSnapshot {
        snapshot
    }
}

private final class SpyWiFiConditionSignalProvider: WiFiConditionSignalProviding {
    private let signal: WiFiConditionSignal
    private(set) var callCount = 0

    init(signal: WiFiConditionSignal) {
        self.signal = signal
    }

    func currentWiFiSignal() -> WiFiConditionSignal {
        callCount += 1
        return signal
    }
}

private final class SpyExternalDisplayConditionSignalProvider: ExternalDisplayConditionSignalProviding {
    private let signal: ExternalDisplayConditionSignal
    private(set) var callCount = 0

    init(signal: ExternalDisplayConditionSignal) {
        self.signal = signal
    }

    func currentExternalDisplaySignal() -> ExternalDisplayConditionSignal {
        callCount += 1
        return signal
    }
}

private final class SpyPowerConditionSignalProvider: PowerConditionSignalProviding {
    private let signal: PowerConditionSignal
    private(set) var callCount = 0

    init(signal: PowerConditionSignal) {
        self.signal = signal
    }

    func currentPowerSignal() -> PowerConditionSignal {
        callCount += 1
        return signal
    }
}

private final class SpyBluetoothConditionSignalProvider: BluetoothConditionSignalProviding {
    private let signal: BluetoothConditionSignal
    private(set) var callCount = 0

    init(signal: BluetoothConditionSignal) {
        self.signal = signal
    }

    func currentBluetoothSignal() -> BluetoothConditionSignal {
        callCount += 1
        return signal
    }
}

private extension ConditionConfiguration {
    static let allDisabled = ConditionConfiguration()

    static let requiredWiFi = ConditionConfiguration(
        wifi: .required(allowedSSIDs: ["TrustedWiFi"], allowedBSSIDs: ["AA:BB:CC:DD:EE:FF"])
    )
}

private extension ConditionSignalSnapshot {
    static let trusted = ConditionSignalSnapshot(
        wifi: .available(ssid: "TrustedWiFi", bssid: "AA:BB:CC:DD:EE:FF"),
        externalDisplays: .connected(["studio-display"]),
        power: .available(.externalPower),
        bluetooth: .available([
            .init(deviceID: "trusted-watch", distanceMeters: .available(1.2), proximity: .available(.near))
        ])
    )
}
