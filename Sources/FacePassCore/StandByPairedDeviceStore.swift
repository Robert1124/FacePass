import Foundation
import Security

public struct StandByPairedDevice: Equatable, Codable {
    public let iphoneDeviceId: String
    public let displayName: String
    public let publicKeyX963Representation: Data
    public let signingAlgorithm: StandBySigningAlgorithm
    public let isEnabled: Bool
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let highestAcceptedCounter: UInt64

    public init(
        iphoneDeviceId: String,
        displayName: String,
        publicKeyX963Representation: Data,
        signingAlgorithm: StandBySigningAlgorithm,
        isEnabled: Bool,
        createdAt: Date,
        lastSeenAt: Date?,
        highestAcceptedCounter: UInt64
    ) {
        self.iphoneDeviceId = iphoneDeviceId
        self.displayName = displayName
        self.publicKeyX963Representation = publicKeyX963Representation
        self.signingAlgorithm = signingAlgorithm
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.highestAcceptedCounter = highestAcceptedCounter
    }
}

public enum StandBySigningAlgorithm: String, Equatable, Codable {
    case p256SHA256
}

public protocol StandByPairedDeviceReading {
    func pairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws -> StandByPairedDevice?
}

public protocol StandByPairedDeviceStoring: StandByPairedDeviceReading {
    func currentPairedDevice() throws -> StandByPairedDevice?
    func savePairedDevice(_ device: StandByPairedDevice) throws
    func replacePairedDevice(_ device: StandByPairedDevice) throws
    func deletePairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws
    func deleteAllPairedDevices() throws
}

public final class StandByPairedDeviceStore: StandByPairedDeviceStoring {
    public static let defaultService = "com.facepass.standby-paired-devices"

    private let service: String
    private let secItemClient: StandByPairedDeviceSecItemClient

    public convenience init(service: String = StandByPairedDeviceStore.defaultService) {
        self.init(service: service, secItemClient: SystemStandByPairedDeviceSecItemClient())
    }

    init(
        service: String = StandByPairedDeviceStore.defaultService,
        secItemClient: StandByPairedDeviceSecItemClient
    ) {
        self.service = service
        self.secItemClient = secItemClient
    }

    public func pairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws -> StandByPairedDevice? {
        var query = baseQuery(forIPhoneDeviceId: iphoneDeviceId)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = secItemClient.copyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw StandByPairedDeviceStoreError.invalidStoredDevice
            }
            do {
                return try JSONDecoder().decode(StandByPairedDevice.self, from: data)
            } catch {
                throw StandByPairedDeviceStoreError.invalidStoredDevice
            }
        case errSecItemNotFound:
            return nil
        default:
            throw StandByPairedDeviceStoreError.keychainFailure(status)
        }
    }

    public func currentPairedDevice() throws -> StandByPairedDevice? {
        var query = baseServiceQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = secItemClient.copyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            if let currentDevice = currentPairedDevice(fromDataResult: result) {
                return currentDevice
            }

            if let currentDevice = try currentPairedDeviceFromAccountAttributes() {
                return currentDevice
            }

            throw StandByPairedDeviceStoreError.invalidStoredDevice
        case errSecItemNotFound:
            return try currentPairedDeviceFromAccountAttributes()
        default:
            if let currentDevice = try currentPairedDeviceFromAccountAttributes() {
                return currentDevice
            }
            throw StandByPairedDeviceStoreError.keychainFailure(status)
        }
    }

    public func savePairedDevice(_ device: StandByPairedDevice) throws {
        let data = try JSONEncoder().encode(device)
        var query = baseQuery(forIPhoneDeviceId: device.iphoneDeviceId)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = secItemClient.add(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = secItemClient.update(
                baseQuery(forIPhoneDeviceId: device.iphoneDeviceId) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw StandByPairedDeviceStoreError.keychainFailure(updateStatus)
            }
        default:
            throw StandByPairedDeviceStoreError.keychainFailure(status)
        }
    }

    public func replacePairedDevice(_ device: StandByPairedDevice) throws {
        try deleteAllPairedDevices()
        try savePairedDevice(device)
    }

    public func deletePairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws {
        let status = secItemClient.delete(baseQuery(forIPhoneDeviceId: iphoneDeviceId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StandByPairedDeviceStoreError.keychainFailure(status)
        }
    }

    public func deleteAllPairedDevices() throws {
        let status = secItemClient.delete(baseServiceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StandByPairedDeviceStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(forIPhoneDeviceId iphoneDeviceId: String) -> [String: Any] {
        var query = baseServiceQuery()
        query[kSecAttrAccount as String] = iphoneDeviceId
        return query
    }

    private func baseServiceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func currentPairedDevice(fromDataResult result: CFTypeRef?) -> StandByPairedDevice? {
        let devices: [StandByPairedDevice]
        if let data = result as? Data {
            devices = decodeCurrentDevice(from: data).map { [$0] } ?? []
        } else if let records = result as? [Data] {
            devices = records.compactMap(decodeCurrentDevice)
        } else if let record = result as? [String: Any],
                  let data = record[kSecValueData as String] as? Data {
            devices = decodeCurrentDevice(from: data).map { [$0] } ?? []
        } else if let records = result as? [[String: Any]] {
            devices = records.compactMap { record in
                guard let data = record[kSecValueData as String] as? Data else {
                    return nil
                }

                return decodeCurrentDevice(from: data)
            }
            if devices.isEmpty, !records.isEmpty {
                return nil
            }
        } else {
            return nil
        }

        return devices.sorted { $0.createdAt > $1.createdAt }.first
    }

    private func decodeCurrentDevice(from data: Data) -> StandByPairedDevice? {
        try? JSONDecoder().decode(StandByPairedDevice.self, from: data)
    }

    private func currentPairedDeviceFromAccountAttributes() throws -> StandByPairedDevice? {
        var query = baseServiceQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        let status = secItemClient.copyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            var devices: [StandByPairedDevice] = []
            for accountIdentifier in accountIdentifiers(fromAttributesResult: result) {
                do {
                    if let device = try pairedDevice(forIPhoneDeviceId: accountIdentifier) {
                        devices.append(device)
                    }
                } catch StandByPairedDeviceStoreError.invalidStoredDevice {
                    continue
                }
            }
            return devices.sorted { $0.createdAt > $1.createdAt }.first
        case errSecItemNotFound:
            return nil
        default:
            throw StandByPairedDeviceStoreError.keychainFailure(status)
        }
    }

    private func accountIdentifiers(fromAttributesResult result: CFTypeRef?) -> [String] {
        if let record = result as? [String: Any] {
            return accountIdentifier(from: record).map { [$0] } ?? []
        }

        guard let records = result as? [[String: Any]] else {
            return []
        }

        return records.compactMap(accountIdentifier)
    }

    private func accountIdentifier(from record: [String: Any]) -> String? {
        let account = record[kSecAttrAccount as String] as? String
        let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAccount?.isEmpty == false ? trimmedAccount : nil
    }
}

protocol StandByPairedDeviceSecItemClient {
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemStandByPairedDeviceSecItemClient: StandByPairedDeviceSecItemClient {
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

public extension StandByPairedDeviceStoring {
    func currentPairedDevice() throws -> StandByPairedDevice? {
        nil
    }

    func replacePairedDevice(_ device: StandByPairedDevice) throws {
        try deleteAllPairedDevices()
        try savePairedDevice(device)
    }

    func deleteAllPairedDevices() throws {
        if let currentDevice = try currentPairedDevice() {
            try deletePairedDevice(forIPhoneDeviceId: currentDevice.iphoneDeviceId)
        }
    }
}

public enum StandByPairedDeviceStoreError: Error, Equatable, CustomStringConvertible {
    case invalidStoredDevice
    case keychainFailure(OSStatus)

    public var description: String {
        switch self {
        case .invalidStoredDevice:
            "Stored StandBy paired-device record is invalid."
        case .keychainFailure:
            "StandBy paired-device Keychain operation failed."
        }
    }
}
