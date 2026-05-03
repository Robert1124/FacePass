import Foundation

public enum FacePassUnlockProviderPolicy: String, CaseIterable, Equatable, Identifiable {
    case faceOnly
    case iPhoneOnly
    case both
    case faceUnlockIPhonePassword

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .faceOnly:
            "Face only"
        case .iPhoneOnly:
            "iPhone only"
        case .both:
            "Both"
        case .faceUnlockIPhonePassword:
            "Face unlock + iPhone approval"
        }
    }

    public var description: String {
        switch self {
        case .faceOnly:
            "Use local FacePass recognition for lock-screen unlock and approved admin/System Settings prompt fill. Reject iPhone requests."
        case .iPhoneOnly:
            "Use paired iPhone approval for lock-screen unlock and approved admin/System Settings prompt fill. Disable local recognition actions."
        case .both:
            "Allow local FacePass recognition and paired iPhone approval for supported lock-screen and admin/System Settings prompt contexts."
        case .faceUnlockIPhonePassword:
            "Use local FacePass recognition for lock-screen unlock, and paired iPhone approval for approved admin/System Settings prompt fill."
        }
    }

    public var allowsLocalFaceLockScreenUnlock: Bool {
        switch self {
        case .faceOnly, .both, .faceUnlockIPhonePassword:
            true
        case .iPhoneOnly:
            false
        }
    }

    public var allowsLocalFaceAuthorizationPromptFill: Bool {
        switch self {
        case .faceOnly, .both:
            true
        case .iPhoneOnly, .faceUnlockIPhonePassword:
            false
        }
    }

    public var allowsIPhoneLockScreenUnlock: Bool {
        switch self {
        case .iPhoneOnly, .both:
            true
        case .faceOnly, .faceUnlockIPhonePassword:
            false
        }
    }

    public var allowsIPhoneAuthorizationPromptFill: Bool {
        switch self {
        case .iPhoneOnly, .both, .faceUnlockIPhonePassword:
            true
        case .faceOnly:
            false
        }
    }

    public var allowsAnyIPhoneAction: Bool {
        allowsIPhoneLockScreenUnlock || allowsIPhoneAuthorizationPromptFill
    }
}

public struct StandByUnlockSettings: Equatable {
    public var isEnabled: Bool
    public var providerPolicy: FacePassUnlockProviderPolicy

    public init(
        isEnabled: Bool = false,
        providerPolicy: FacePassUnlockProviderPolicy = .both
    ) {
        self.isEnabled = isEnabled
        self.providerPolicy = providerPolicy
    }
}

public final class StandByUnlockSettingsStore {
    private enum Key {
        static let enabled = "FacePass.standByUnlock.enabled"
        static let providerPolicy = "FacePass.unlockProviderPolicy"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> StandByUnlockSettings {
        let policy = userDefaults.string(forKey: Key.providerPolicy)
            .flatMap(FacePassUnlockProviderPolicy.init(rawValue:)) ?? .both
        return StandByUnlockSettings(
            isEnabled: userDefaults.bool(forKey: Key.enabled),
            providerPolicy: policy
        )
    }

    public func save(_ settings: StandByUnlockSettings) {
        userDefaults.set(settings.isEnabled, forKey: Key.enabled)
        userDefaults.set(settings.providerPolicy.rawValue, forKey: Key.providerPolicy)
    }
}
