import Foundation

public enum OverlayPhase: String, CaseIterable, Equatable, Sendable {
    case idle
    case scanning
    case success
    case failure
    case timeout
    case recognitionPreviewScanning
    case recognitionPreviewRecognized
    case recognitionPreviewFailure

    public var title: String {
        switch self {
        case .idle:
            "FacePass"
        case .scanning:
            "Scanning"
        case .success:
            "Unlocked"
        case .failure:
            "Not Unlocked"
        case .timeout:
            "Timed Out"
        case .recognitionPreviewScanning:
            "Preview Scan"
        case .recognitionPreviewRecognized:
            "Preview Matched"
        case .recognitionPreviewFailure:
            "Preview Failed"
        }
    }

    public var detail: String {
        switch self {
        case .idle:
            "Waiting for a FacePass feedback request."
        case .scanning:
            "Checking the local unlock window."
        case .success:
            "FacePass feedback completed."
        case .failure:
            "FacePass could not complete this request."
        case .timeout:
            "The request ended before completion."
        case .recognitionPreviewScanning:
            "Visual preview only. No camera or model is running."
        case .recognitionPreviewRecognized:
            "Visual preview only. No unlock or password fill ran."
        case .recognitionPreviewFailure:
            "Visual preview only. No recognition decision ran."
        }
    }

    public var systemImageName: String {
        switch self {
        case .idle:
            "lock.shield"
        case .scanning:
            "viewfinder"
        case .success:
            "checkmark"
        case .failure:
            "xmark"
        case .timeout:
            "hourglass"
        case .recognitionPreviewScanning:
            "viewfinder"
        case .recognitionPreviewRecognized:
            "person.crop.circle.badge.checkmark"
        case .recognitionPreviewFailure:
            "person.crop.circle.badge.xmark"
        }
    }

    public var accessibilityLabel: String {
        "\(title). \(detail)"
    }
}

public struct OverlayState: Equatable, Sendable {
    public var isVisible: Bool
    public var phase: OverlayPhase

    public init(isVisible: Bool = false, phase: OverlayPhase = .idle) {
        self.isVisible = isVisible
        self.phase = phase
    }

    public mutating func showScanning() {
        show(.scanning)
    }

    public mutating func showSuccess() {
        show(.success)
    }

    public mutating func showFailure() {
        show(.failure)
    }

    public mutating func showTimeout() {
        show(.timeout)
    }

    public mutating func showRecognitionPreviewScanning() {
        show(.recognitionPreviewScanning)
    }

    public mutating func showRecognitionPreviewRecognized() {
        show(.recognitionPreviewRecognized)
    }

    public mutating func showRecognitionPreviewFailure() {
        show(.recognitionPreviewFailure)
    }

    public mutating func dismiss() {
        isVisible = false
        phase = .idle
    }

    private mutating func show(_ phase: OverlayPhase) {
        isVisible = true
        self.phase = phase
    }
}
