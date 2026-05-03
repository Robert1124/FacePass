import Foundation

public struct FacePassCompanionConfiguration: Sendable {
    public static let defaultAppGroupIdentifier = "group.com.facepass.companion"
    public static let keychainAccessGroupInfoKey = "FacePassKeychainAccessGroup"

    public let appGroupIdentifier: String?
    public let keychainService: String
    public let keychainAccessGroup: String?
    public let iphoneDisplayName: String

    public init(
        appGroupIdentifier: String? = Self.defaultAppGroupIdentifier,
        keychainService: String = "com.facepass.companion.standby-unlock",
        keychainAccessGroup: String? = Self.defaultKeychainAccessGroup(),
        iphoneDisplayName: String = "iPhone"
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainService = keychainService
        self.keychainAccessGroup = keychainAccessGroup
        self.iphoneDisplayName = iphoneDisplayName
    }

    public static let `default` = FacePassCompanionConfiguration()

    public static func defaultKeychainAccessGroup(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: keychainAccessGroupInfoKey) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }

        return trimmed
    }

    public func userDefaults() -> UserDefaults {
        guard let appGroupIdentifier,
              let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return .standard
        }

        return defaults
    }

    public func counterLockFileURL() -> URL {
        if let appGroupIdentifier,
           let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
           ) {
            return containerURL.appending(path: "StandByUnlockCounterStore.lock")
        }

        return FileManager.default.temporaryDirectory.appending(path: "StandByUnlockCounterStore.lock")
    }
}
