import Foundation

public protocol PermissionStatusProviding {
    func currentPermissionStatuses() -> [PermissionStatus]
}

public struct PermissionStatus: Equatable, Identifiable {
    public let kind: PermissionKind
    public let authorization: PermissionAuthorization

    public var id: PermissionKind { kind }

    public init(kind: PermissionKind, authorization: PermissionAuthorization) {
        self.kind = kind
        self.authorization = authorization
    }

    public static func camera(_ authorization: PermissionAuthorization) -> PermissionStatus {
        PermissionStatus(kind: .camera, authorization: authorization)
    }

    public static func accessibility(_ authorization: PermissionAuthorization) -> PermissionStatus {
        PermissionStatus(kind: .accessibility, authorization: authorization)
    }

    public static func keychain(_ authorization: PermissionAuthorization) -> PermissionStatus {
        PermissionStatus(kind: .keychain, authorization: authorization)
    }

    public var isGranted: Bool {
        switch authorization {
        case .authorized, .available:
            true
        case .denied, .restricted, .notDetermined, .unknown:
            false
        }
    }

    public var title: String {
        kind.title
    }

    public var statusText: String {
        authorization.statusText
    }
}

public enum PermissionKind: String, Equatable, Hashable, CaseIterable, Identifiable {
    case camera
    case accessibility
    case keychain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .camera:
            "Camera"
        case .accessibility:
            "Accessibility"
        case .keychain:
            "Keychain"
        }
    }

    public var purpose: String {
        switch self {
        case .camera:
            "Used only for short local FacePass recognition, enrollment, approved admin/System Settings prompt fill, and opt-in wake-triggered lock-screen checks. FacePass does not keep the camera running or save raw frames or photos."
        case .accessibility:
            "Used to inspect approved macOS administrator/System Settings authorization password prompts and set the saved value only. It does not click, submit, or press Return in unlocked prompts."
        case .keychain:
            "Stores the configured password in Keychain without showing it in the app UI. The user-triggered preflight reads it only to verify access and discards it immediately."
        }
    }
}

public enum PermissionAuthorization: String, Equatable {
    case authorized
    case available
    case denied
    case restricted
    case notDetermined
    case unknown

    public var statusText: String {
        switch self {
        case .authorized:
            "Allowed"
        case .available:
            "Available"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        case .notDetermined:
            "Not granted"
        case .unknown:
            "Unknown"
        }
    }
}
