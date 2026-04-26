import Foundation

public protocol ConditionSignalProviding {
    func currentConditionSignals() -> ConditionSignalSnapshot
}

public struct ConditionManager {
    private let signalProvider: any ConditionSignalProviding

    public init(signalProvider: any ConditionSignalProviding = UnavailableConditionSignalProvider()) {
        self.signalProvider = signalProvider
    }

    public func evaluate(configuration: ConditionConfiguration) -> ConditionEvaluation {
        let snapshot = signalProvider.currentConditionSignals()
        var results = [
            evaluateWiFi(configuration.wifi, signal: snapshot.wifi),
            evaluateExternalDisplay(configuration.externalDisplay, signal: snapshot.externalDisplays),
            evaluatePower(configuration.power, signal: snapshot.power),
            evaluateBluetooth(configuration.bluetooth, signal: snapshot.bluetooth)
        ]

        if !configuration.hasRequiredConditions {
            results.append(ConditionCheckResult(
                type: .configuration,
                requirement: .required,
                status: .blocked,
                reason: .noRequiredConditionsConfigured
            ))
        }

        return ConditionEvaluation(results: results)
    }

    private func evaluateWiFi(
        _ configuration: WiFiConditionConfiguration,
        signal: WiFiConditionSignal
    ) -> ConditionCheckResult {
        guard configuration.requirement != .disabled else {
            return .skipped(.wifi)
        }

        guard configuration.hasCriteria else {
            return status(
                type: .wifi,
                requirement: configuration.requirement,
                requiredReason: .requiredConditionMisconfigured,
                optionalReason: .optionalConditionMisconfigured
            )
        }

        switch signal {
        case .unavailable:
            return status(
                type: .wifi,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalUnavailable,
                optionalReason: .optionalSignalUnavailable
            )
        case .inconclusive:
            return status(
                type: .wifi,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalInconclusive,
                optionalReason: .optionalSignalInconclusive
            )
        case let .available(ssid, bssid):
            if !configuration.allowedSSIDs.isEmpty {
                guard let ssid else {
                    return status(
                        type: .wifi,
                        requirement: configuration.requirement,
                        requiredReason: .requiredSignalUnavailable,
                        optionalReason: .optionalSignalUnavailable
                    )
                }
                guard configuration.allowedSSIDs.contains(ssid) else {
                    return mismatch(type: .wifi, requirement: configuration.requirement)
                }
            }

            if !configuration.allowedBSSIDs.isEmpty {
                guard let bssid else {
                    return status(
                        type: .wifi,
                        requirement: configuration.requirement,
                        requiredReason: .requiredSignalUnavailable,
                        optionalReason: .optionalSignalUnavailable
                    )
                }
                guard configuration.allowedBSSIDs.contains(bssid) else {
                    return mismatch(type: .wifi, requirement: configuration.requirement)
                }
            }

            return .satisfied(.wifi, requirement: configuration.requirement)
        }
    }

    private func evaluateExternalDisplay(
        _ configuration: ExternalDisplayConditionConfiguration,
        signal: ExternalDisplayConditionSignal
    ) -> ConditionCheckResult {
        guard configuration.requirement != .disabled else {
            return .skipped(.externalDisplay)
        }

        guard !configuration.allowedDisplayIDs.isEmpty else {
            return status(
                type: .externalDisplay,
                requirement: configuration.requirement,
                requiredReason: .requiredConditionMisconfigured,
                optionalReason: .optionalConditionMisconfigured
            )
        }

        switch signal {
        case .unavailable:
            return status(
                type: .externalDisplay,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalUnavailable,
                optionalReason: .optionalSignalUnavailable
            )
        case .inconclusive:
            return status(
                type: .externalDisplay,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalInconclusive,
                optionalReason: .optionalSignalInconclusive
            )
        case let .connected(displayIDs):
            guard !configuration.allowedDisplayIDs.isDisjoint(with: displayIDs) else {
                return mismatch(type: .externalDisplay, requirement: configuration.requirement)
            }
            return .satisfied(.externalDisplay, requirement: configuration.requirement)
        }
    }

    private func evaluatePower(
        _ configuration: PowerConditionConfiguration,
        signal: PowerConditionSignal
    ) -> ConditionCheckResult {
        guard configuration.requirement != .disabled else {
            return .skipped(.power)
        }

        guard !configuration.allowedStates.isEmpty else {
            return status(
                type: .power,
                requirement: configuration.requirement,
                requiredReason: .requiredConditionMisconfigured,
                optionalReason: .optionalConditionMisconfigured
            )
        }

        switch signal {
        case .unavailable:
            return status(
                type: .power,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalUnavailable,
                optionalReason: .optionalSignalUnavailable
            )
        case .inconclusive:
            return status(
                type: .power,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalInconclusive,
                optionalReason: .optionalSignalInconclusive
            )
        case let .available(state):
            guard configuration.allowedStates.contains(state) else {
                return mismatch(type: .power, requirement: configuration.requirement)
            }
            return .satisfied(.power, requirement: configuration.requirement)
        }
    }

    private func evaluateBluetooth(
        _ configuration: BluetoothConditionConfiguration,
        signal: BluetoothConditionSignal
    ) -> ConditionCheckResult {
        guard configuration.requirement != .disabled else {
            return .skipped(.bluetooth)
        }

        guard configuration.hasCriteria else {
            return status(
                type: .bluetooth,
                requirement: configuration.requirement,
                requiredReason: .requiredConditionMisconfigured,
                optionalReason: .optionalConditionMisconfigured
            )
        }

        switch signal {
        case .unavailable:
            return status(
                type: .bluetooth,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalUnavailable,
                optionalReason: .optionalSignalUnavailable
            )
        case .inconclusive:
            return status(
                type: .bluetooth,
                requirement: configuration.requirement,
                requiredReason: .requiredSignalInconclusive,
                optionalReason: .optionalSignalInconclusive
            )
        case let .available(devices):
            guard let device = devices.first(where: { $0.deviceID == configuration.deviceID }) else {
                return status(
                    type: .bluetooth,
                    requirement: configuration.requirement,
                    requiredReason: .bluetoothDeviceNotObserved,
                    optionalReason: .optionalSignalUnavailable
                )
            }

            if let maximumDistanceMeters = configuration.maximumDistanceMeters {
                switch device.distanceMeters {
                case .unavailable:
                    return status(
                        type: .bluetooth,
                        requirement: configuration.requirement,
                        requiredReason: .requiredSignalUnavailable,
                        optionalReason: .optionalSignalUnavailable
                    )
                case .inconclusive:
                    return status(
                        type: .bluetooth,
                        requirement: configuration.requirement,
                        requiredReason: .requiredSignalInconclusive,
                        optionalReason: .optionalSignalInconclusive
                    )
                case let .available(distanceMeters):
                    guard distanceMeters <= maximumDistanceMeters else {
                        return status(
                            type: .bluetooth,
                            requirement: configuration.requirement,
                            requiredReason: .bluetoothDeviceTooFar,
                            optionalReason: .optionalValueMismatch
                        )
                    }
                }
            }

            if !configuration.acceptedProximities.isEmpty {
                switch device.proximity {
                case .unavailable:
                    return status(
                        type: .bluetooth,
                        requirement: configuration.requirement,
                        requiredReason: .requiredSignalUnavailable,
                        optionalReason: .optionalSignalUnavailable
                    )
                case .inconclusive:
                    return status(
                        type: .bluetooth,
                        requirement: configuration.requirement,
                        requiredReason: .requiredSignalInconclusive,
                        optionalReason: .optionalSignalInconclusive
                    )
                case let .available(proximity):
                    guard configuration.acceptedProximities.contains(proximity) else {
                        return mismatch(type: .bluetooth, requirement: configuration.requirement)
                    }
                }
            }

            return .satisfied(.bluetooth, requirement: configuration.requirement)
        }
    }

    private func mismatch(
        type: ConditionType,
        requirement: ConditionRequirement
    ) -> ConditionCheckResult {
        status(
            type: type,
            requirement: requirement,
            requiredReason: .valueMismatch,
            optionalReason: .optionalValueMismatch
        )
    }

    private func status(
        type: ConditionType,
        requirement: ConditionRequirement,
        requiredReason: ConditionEvaluationReason,
        optionalReason: ConditionEvaluationReason
    ) -> ConditionCheckResult {
        switch requirement {
        case .required:
            ConditionCheckResult(type: type, requirement: requirement, status: .blocked, reason: requiredReason)
        case .optional:
            ConditionCheckResult(type: type, requirement: requirement, status: .optionalNotSatisfied, reason: optionalReason)
        case .disabled:
            .skipped(type)
        }
    }
}

public struct ConditionConfiguration: Equatable {
    public let wifi: WiFiConditionConfiguration
    public let externalDisplay: ExternalDisplayConditionConfiguration
    public let power: PowerConditionConfiguration
    public let bluetooth: BluetoothConditionConfiguration

    public init(
        wifi: WiFiConditionConfiguration = .disabled,
        externalDisplay: ExternalDisplayConditionConfiguration = .disabled,
        power: PowerConditionConfiguration = .disabled,
        bluetooth: BluetoothConditionConfiguration = .disabled
    ) {
        self.wifi = wifi
        self.externalDisplay = externalDisplay
        self.power = power
        self.bluetooth = bluetooth
    }

    var hasRequiredConditions: Bool {
        wifi.requirement == .required ||
            externalDisplay.requirement == .required ||
            power.requirement == .required ||
            bluetooth.requirement == .required
    }
}

public struct WiFiConditionConfiguration: Equatable {
    public let requirement: ConditionRequirement
    public let allowedSSIDs: Set<String>
    public let allowedBSSIDs: Set<String>

    public init(
        requirement: ConditionRequirement,
        allowedSSIDs: Set<String> = [],
        allowedBSSIDs: Set<String> = []
    ) {
        self.requirement = requirement
        self.allowedSSIDs = allowedSSIDs
        self.allowedBSSIDs = allowedBSSIDs
    }

    public static let disabled = WiFiConditionConfiguration(requirement: .disabled)

    public static func required(
        allowedSSIDs: Set<String> = [],
        allowedBSSIDs: Set<String> = []
    ) -> WiFiConditionConfiguration {
        WiFiConditionConfiguration(requirement: .required, allowedSSIDs: allowedSSIDs, allowedBSSIDs: allowedBSSIDs)
    }

    public static func optional(
        allowedSSIDs: Set<String> = [],
        allowedBSSIDs: Set<String> = []
    ) -> WiFiConditionConfiguration {
        WiFiConditionConfiguration(requirement: .optional, allowedSSIDs: allowedSSIDs, allowedBSSIDs: allowedBSSIDs)
    }

    var hasCriteria: Bool {
        !allowedSSIDs.isEmpty || !allowedBSSIDs.isEmpty
    }
}

public struct ExternalDisplayConditionConfiguration: Equatable {
    public let requirement: ConditionRequirement
    public let allowedDisplayIDs: Set<String>

    public init(requirement: ConditionRequirement, allowedDisplayIDs: Set<String> = []) {
        self.requirement = requirement
        self.allowedDisplayIDs = allowedDisplayIDs
    }

    public static let disabled = ExternalDisplayConditionConfiguration(requirement: .disabled)

    public static func required(allowedDisplayIDs: Set<String>) -> ExternalDisplayConditionConfiguration {
        ExternalDisplayConditionConfiguration(requirement: .required, allowedDisplayIDs: allowedDisplayIDs)
    }

    public static func optional(allowedDisplayIDs: Set<String>) -> ExternalDisplayConditionConfiguration {
        ExternalDisplayConditionConfiguration(requirement: .optional, allowedDisplayIDs: allowedDisplayIDs)
    }
}

public struct PowerConditionConfiguration: Equatable {
    public let requirement: ConditionRequirement
    public let allowedStates: Set<PowerState>

    public init(requirement: ConditionRequirement, allowedStates: Set<PowerState> = []) {
        self.requirement = requirement
        self.allowedStates = allowedStates
    }

    public static let disabled = PowerConditionConfiguration(requirement: .disabled)

    public static func required(allowedStates: Set<PowerState>) -> PowerConditionConfiguration {
        PowerConditionConfiguration(requirement: .required, allowedStates: allowedStates)
    }

    public static func optional(allowedStates: Set<PowerState>) -> PowerConditionConfiguration {
        PowerConditionConfiguration(requirement: .optional, allowedStates: allowedStates)
    }
}

public struct BluetoothConditionConfiguration: Equatable {
    public let requirement: ConditionRequirement
    public let deviceID: String
    public let maximumDistanceMeters: Double?
    public let acceptedProximities: Set<BluetoothProximity>

    public init(
        requirement: ConditionRequirement,
        deviceID: String = "",
        maximumDistanceMeters: Double? = nil,
        acceptedProximities: Set<BluetoothProximity> = []
    ) {
        self.requirement = requirement
        self.deviceID = deviceID
        self.maximumDistanceMeters = maximumDistanceMeters
        self.acceptedProximities = acceptedProximities
    }

    public static let disabled = BluetoothConditionConfiguration(requirement: .disabled)

    public static func required(
        deviceID: String,
        maximumDistanceMeters: Double? = nil,
        acceptedProximities: Set<BluetoothProximity> = []
    ) -> BluetoothConditionConfiguration {
        BluetoothConditionConfiguration(
            requirement: .required,
            deviceID: deviceID,
            maximumDistanceMeters: maximumDistanceMeters,
            acceptedProximities: acceptedProximities
        )
    }

    public static func optional(
        deviceID: String,
        maximumDistanceMeters: Double? = nil,
        acceptedProximities: Set<BluetoothProximity> = []
    ) -> BluetoothConditionConfiguration {
        BluetoothConditionConfiguration(
            requirement: .optional,
            deviceID: deviceID,
            maximumDistanceMeters: maximumDistanceMeters,
            acceptedProximities: acceptedProximities
        )
    }

    var hasCriteria: Bool {
        guard !deviceID.isEmpty else {
            return false
        }
        if let maximumDistanceMeters {
            return maximumDistanceMeters >= 0
        }
        return !acceptedProximities.isEmpty
    }
}

public enum ConditionRequirement: Equatable {
    case disabled
    case optional
    case required
}

public struct ConditionSignalSnapshot: Equatable {
    public let wifi: WiFiConditionSignal
    public let externalDisplays: ExternalDisplayConditionSignal
    public let power: PowerConditionSignal
    public let bluetooth: BluetoothConditionSignal

    public init(
        wifi: WiFiConditionSignal = .unavailable,
        externalDisplays: ExternalDisplayConditionSignal = .unavailable,
        power: PowerConditionSignal = .unavailable,
        bluetooth: BluetoothConditionSignal = .unavailable
    ) {
        self.wifi = wifi
        self.externalDisplays = externalDisplays
        self.power = power
        self.bluetooth = bluetooth
    }
}

public struct UnavailableConditionSignalProvider: ConditionSignalProviding {
    public init() {}

    public func currentConditionSignals() -> ConditionSignalSnapshot {
        ConditionSignalSnapshot()
    }
}

public enum WiFiConditionSignal: Equatable {
    case available(ssid: String?, bssid: String?)
    case unavailable
    case inconclusive
}

public enum ExternalDisplayConditionSignal: Equatable {
    case connected(Set<String>)
    case unavailable
    case inconclusive
}

public enum PowerConditionSignal: Equatable {
    case available(PowerState)
    case unavailable
    case inconclusive
}

public enum BluetoothConditionSignal: Equatable {
    case available([BluetoothDeviceSignal])
    case unavailable
    case inconclusive
}

public struct BluetoothDeviceSignal: Equatable {
    public let deviceID: String
    public let distanceMeters: SignalValue<Double>
    public let proximity: SignalValue<BluetoothProximity>

    public init(
        deviceID: String,
        distanceMeters: SignalValue<Double> = .unavailable,
        proximity: SignalValue<BluetoothProximity> = .unavailable
    ) {
        self.deviceID = deviceID
        self.distanceMeters = distanceMeters
        self.proximity = proximity
    }
}

public enum SignalValue<Value: Equatable>: Equatable {
    case available(Value)
    case unavailable
    case inconclusive
}

public enum PowerState: Equatable, Hashable {
    case externalPower
    case battery
    case charging
}

public enum BluetoothProximity: Equatable, Hashable {
    case immediate
    case near
    case far
}

public struct ConditionEvaluation: Equatable, CustomStringConvertible {
    public let isEligibleForAutoUnlock: Bool
    public let results: [ConditionCheckResult]
    public let reasons: [ConditionEvaluationReason]

    init(results: [ConditionCheckResult]) {
        self.results = results
        self.reasons = results.map(\.reason)
        self.isEligibleForAutoUnlock = !results.contains { $0.status == .blocked }
    }

    public func result(for type: ConditionType) -> ConditionCheckResult? {
        results.first { $0.type == type }
    }

    public var description: String {
        "ConditionEvaluation(isEligibleForAutoUnlock: \(isEligibleForAutoUnlock), results: \(results))"
    }
}

public struct ConditionCheckResult: Equatable, CustomStringConvertible {
    public let type: ConditionType
    public let requirement: ConditionRequirement
    public let status: ConditionEvaluationStatus
    public let reason: ConditionEvaluationReason

    init(
        type: ConditionType,
        requirement: ConditionRequirement,
        status: ConditionEvaluationStatus,
        reason: ConditionEvaluationReason
    ) {
        self.type = type
        self.requirement = requirement
        self.status = status
        self.reason = reason
    }

    static func satisfied(_ type: ConditionType, requirement: ConditionRequirement) -> ConditionCheckResult {
        ConditionCheckResult(type: type, requirement: requirement, status: .satisfied, reason: .satisfied)
    }

    static func skipped(_ type: ConditionType) -> ConditionCheckResult {
        ConditionCheckResult(type: type, requirement: .disabled, status: .skipped, reason: .disabled)
    }

    public var description: String {
        "ConditionCheckResult(type: \(type), requirement: \(requirement), status: \(status), reason: \(reason))"
    }
}

public enum ConditionType: Equatable {
    case wifi
    case externalDisplay
    case power
    case bluetooth
    case configuration
}

public enum ConditionEvaluationStatus: Equatable {
    case satisfied
    case blocked
    case skipped
    case optionalNotSatisfied
}

public enum ConditionEvaluationReason: Equatable {
    case satisfied
    case disabled
    case noRequiredConditionsConfigured
    case requiredConditionMisconfigured
    case optionalConditionMisconfigured
    case requiredSignalUnavailable
    case requiredSignalInconclusive
    case optionalSignalUnavailable
    case optionalSignalInconclusive
    case valueMismatch
    case optionalValueMismatch
    case bluetoothDeviceNotObserved
    case bluetoothDeviceTooFar
}
