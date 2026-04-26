import ApplicationServices
import AVFoundation
import Foundation

public struct SystemPermissionStatusProvider: PermissionStatusProviding {
    public init() {}

    public func currentPermissionStatuses() -> [PermissionStatus] {
        [
            .camera(cameraAuthorization()),
            .accessibility(accessibilityAuthorization()),
            .keychain(.available)
        ]
    }

    private func cameraAuthorization() -> PermissionAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .unknown
        }
    }

    private func accessibilityAuthorization() -> PermissionAuthorization {
        AXIsProcessTrusted() ? .authorized : .notDetermined
    }
}
