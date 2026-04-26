import CoreGraphics
import CoreWLAN
import ColorSync
import Foundation
import IOKit.ps

public protocol WiFiConditionSignalProviding {
    func currentWiFiSignal() -> WiFiConditionSignal
}

public protocol ExternalDisplayConditionSignalProviding {
    func currentExternalDisplaySignal() -> ExternalDisplayConditionSignal
}

public protocol PowerConditionSignalProviding {
    func currentPowerSignal() -> PowerConditionSignal
}

public protocol BluetoothConditionSignalProviding {
    func currentBluetoothSignal() -> BluetoothConditionSignal
}

public struct MacConditionSignalProvider: ConditionSignalProviding {
    private let wifiProvider: any WiFiConditionSignalProviding
    private let externalDisplayProvider: any ExternalDisplayConditionSignalProviding
    private let powerProvider: any PowerConditionSignalProviding
    private let bluetoothProvider: any BluetoothConditionSignalProviding

    public init(
        wifiProvider: any WiFiConditionSignalProviding = CoreWLANWiFiConditionSignalProvider(),
        externalDisplayProvider: any ExternalDisplayConditionSignalProviding = CoreGraphicsExternalDisplayConditionSignalProvider(),
        powerProvider: any PowerConditionSignalProviding = IOKitPowerConditionSignalProvider(),
        bluetoothProvider: any BluetoothConditionSignalProviding = MacBluetoothConditionSignalProvider()
    ) {
        self.wifiProvider = wifiProvider
        self.externalDisplayProvider = externalDisplayProvider
        self.powerProvider = powerProvider
        self.bluetoothProvider = bluetoothProvider
    }

    public func currentConditionSignals() -> ConditionSignalSnapshot {
        ConditionSignalSnapshot(
            wifi: wifiProvider.currentWiFiSignal(),
            externalDisplays: externalDisplayProvider.currentExternalDisplaySignal(),
            power: powerProvider.currentPowerSignal(),
            bluetooth: bluetoothProvider.currentBluetoothSignal()
        )
    }
}

public struct CoreWLANWiFiConditionSignalProvider: WiFiConditionSignalProviding {
    public init() {}

    public func currentWiFiSignal() -> WiFiConditionSignal {
        guard let interface = CWWiFiClient.shared().interface() else {
            return .unavailable
        }

        let ssid = nonEmpty(interface.ssid())
        let bssid = nonEmpty(interface.bssid())

        guard ssid != nil || bssid != nil else {
            return .inconclusive
        }

        return .available(ssid: ssid, bssid: bssid)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct CoreGraphicsExternalDisplayConditionSignalProvider: ExternalDisplayConditionSignalProviding {
    private let displaySnapshots: () -> Result<[MacDisplaySnapshot], MacDisplaySnapshotError>

    public init() {
        self.init(
            onlineDisplayIDs: Self.currentOnlineDisplayIDs,
            isBuiltInDisplay: { CGDisplayIsBuiltin($0) != 0 },
            displayUUIDString: Self.displayUUIDString
        )
    }

    init(_ displaySnapshots: @escaping () -> Result<[MacDisplaySnapshot], MacDisplaySnapshotError>) {
        self.displaySnapshots = displaySnapshots
    }

    init(
        onlineDisplayIDs: @escaping () -> Result<[CGDirectDisplayID], MacDisplaySnapshotError>,
        isBuiltInDisplay: @escaping (CGDirectDisplayID) -> Bool,
        displayUUIDString: @escaping (CGDirectDisplayID) -> String?
    ) {
        self.displaySnapshots = {
            onlineDisplayIDs().map { displayIDs in
                displayIDs.map { displayID in
                    MacDisplaySnapshot(
                        displayID: displayUUIDString(displayID) ?? String(displayID),
                        isBuiltIn: isBuiltInDisplay(displayID)
                    )
                }
            }
        }
    }

    public func currentExternalDisplaySignal() -> ExternalDisplayConditionSignal {
        switch displaySnapshots() {
        case let .success(displays):
            let externalDisplayIDs = displays
                .filter { !$0.isBuiltIn }
                .map(\.displayID)
            return .connected(Set(externalDisplayIDs))
        case .failure:
            return .inconclusive
        }
    }

    private static func currentOnlineDisplayIDs() -> Result<[CGDirectDisplayID], MacDisplaySnapshotError> {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
            return .failure(.unavailable)
        }

        guard displayCount > 0 else {
            return .success([])
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listError = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }

        guard listError == .success else {
            return .failure(.unavailable)
        }

        return .success(Array(displayIDs.prefix(Int(displayCount))))
    }

    private static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID),
              let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) else {
            return nil
        }

        return uuidString as NSString as String
    }
}

struct MacDisplaySnapshot: Equatable {
    let displayID: String
    let isBuiltIn: Bool
}

enum MacDisplaySnapshotError: Error, Equatable {
    case unavailable
}

public struct IOKitPowerConditionSignalProvider: PowerConditionSignalProviding {
    public init() {}

    public func currentPowerSignal() -> PowerConditionSignal {
        guard let sourceType = currentPowerSourceType() else {
            return .inconclusive
        }

        if sourceType == kIOPSACPowerValue {
            guard let isCharging = isAnyPowerSourceCharging() else {
                return .inconclusive
            }
            return isCharging ? .available(.charging) : .available(.externalPower)
        }

        if sourceType == kIOPSBatteryPowerValue {
            return .available(.battery)
        }

        return .inconclusive
    }

    private func currentPowerSourceType() -> String? {
        guard let sourceType = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else {
            return nil
        }
        return sourceType as NSString as String
    }

    private func isAnyPowerSourceCharging() -> Bool? {
        guard let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [Any] else {
            return nil
        }

        let chargingKey = kIOPSIsChargingKey
        var observedPowerSourceDescription = false
        for powerSource in powerSources {
            guard let description = IOPSGetPowerSourceDescription(
                powerSourcesInfo,
                powerSource as CFTypeRef
            )?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            observedPowerSourceDescription = true
            if description[chargingKey] as? Bool == true {
                return true
            }
        }

        return powerSources.isEmpty || observedPowerSourceDescription ? false : nil
    }
}

public struct MacBluetoothConditionSignalProvider: BluetoothConditionSignalProviding {
    public init() {}

    public func currentBluetoothSignal() -> BluetoothConditionSignal {
        // A safe Bluetooth trust signal needs a short-window sampler with explicit device policy.
        // This provider intentionally does not start background scans or treat RSSI as distance.
        .inconclusive
    }
}
