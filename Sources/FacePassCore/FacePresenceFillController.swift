import Foundation

public protocol FacePresenceDetecting: AnyObject {
    func detectFace(timeout: TimeInterval) async -> CameraFaceDetectionResult
}

extension CameraFaceDetector: FacePresenceDetecting {}

public final class FacePresenceFillController {
    private let detector: any FacePresenceDetecting
    private let manualFill: () -> ManualFillResult
    private let timeout: TimeInterval

    public init(
        detector: any FacePresenceDetecting,
        manualFill: @escaping () -> ManualFillResult,
        timeout: TimeInterval
    ) {
        self.detector = detector
        self.manualFill = manualFill
        self.timeout = timeout
    }

    public func fillFocusedPasswordFieldAfterFaceCheck() async -> FacePresenceFillResult {
        switch await detector.detectFace(timeout: timeout) {
        case .detected:
            let manualFillResult = manualFill()
            return manualFillResult == .filled ? .filled : .manualFillFailed(manualFillResult)
        case .permissionDenied:
            return .cameraPermissionDenied
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cameraFailed
        case .failed:
            return .cameraFailed
        }
    }
}

public enum FacePresenceFillResult: Equatable, CustomStringConvertible {
    case checking
    case filled
    case cameraPermissionDenied
    case timedOut
    case cameraFailed
    case manualFillFailed(ManualFillResult)

    public var description: String {
        switch self {
        case .checking:
            "Checking for a visible face..."
        case .filled:
            "Visible face checked; password filled."
        case .cameraPermissionDenied:
            "Camera permission is required to check for a visible face."
        case .timedOut:
            "No visible face was detected before the check timed out."
        case .cameraFailed:
            "Face presence check could not use the camera."
        case .manualFillFailed(let result):
            result.description
        }
    }
}
