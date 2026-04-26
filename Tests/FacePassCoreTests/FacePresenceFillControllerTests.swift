import XCTest
@testable import FacePassCore

final class FacePresenceFillControllerTests: XCTestCase {
    func testDetectedFaceRunsManualFillAndReturnsFilled() async {
        let detector = StubFacePresenceDetector(result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        let manualFill = SpyFacePresenceManualFill(result: .filled)
        let controller = FacePresenceFillController(
            detector: detector,
            manualFill: manualFill.fillFocusedPasswordField,
            timeout: 3
        )

        let result = await controller.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(result, .filled)
        XCTAssertEqual(detector.requestedTimeouts, [3])
        XCTAssertEqual(manualFill.callCount, 1)
    }

    func testCameraPermissionDeniedDoesNotRunManualFill() async {
        let detector = StubFacePresenceDetector(result: .permissionDenied)
        let manualFill = SpyFacePresenceManualFill(result: .filled)
        let controller = FacePresenceFillController(
            detector: detector,
            manualFill: manualFill.fillFocusedPasswordField,
            timeout: 3
        )

        let result = await controller.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(result, .cameraPermissionDenied)
        XCTAssertEqual(detector.requestedTimeouts, [3])
        XCTAssertEqual(manualFill.callCount, 0)
    }

    func testTimedOutFaceCheckDoesNotRunManualFill() async {
        let detector = StubFacePresenceDetector(result: .timedOut)
        let manualFill = SpyFacePresenceManualFill(result: .filled)
        let controller = FacePresenceFillController(
            detector: detector,
            manualFill: manualFill.fillFocusedPasswordField,
            timeout: 3
        )

        let result = await controller.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(detector.requestedTimeouts, [3])
        XCTAssertEqual(manualFill.callCount, 0)
    }

    func testCameraFailureDoesNotRunManualFill() async {
        let detector = StubFacePresenceDetector(result: .failed(.captureFailed))
        let manualFill = SpyFacePresenceManualFill(result: .filled)
        let controller = FacePresenceFillController(
            detector: detector,
            manualFill: manualFill.fillFocusedPasswordField,
            timeout: 3
        )

        let result = await controller.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(result, .cameraFailed)
        XCTAssertEqual(detector.requestedTimeouts, [3])
        XCTAssertEqual(manualFill.callCount, 0)
    }

    func testManualFillFailureIsMappedWithoutRunningAnySubmitAction() async {
        let detector = StubFacePresenceDetector(result: .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        let manualFill = SpyFacePresenceManualFill(result: .noFocusedPasswordField)
        let controller = FacePresenceFillController(
            detector: detector,
            manualFill: manualFill.fillFocusedPasswordField,
            timeout: 3
        )

        let result = await controller.fillFocusedPasswordFieldAfterFaceCheck()

        XCTAssertEqual(result, .manualFillFailed(.noFocusedPasswordField))
        XCTAssertEqual(detector.requestedTimeouts, [3])
        XCTAssertEqual(manualFill.callCount, 1)
        XCTAssertEqual(manualFill.forbiddenConfirmationActionCount, 0)
    }
}

private final class StubFacePresenceDetector: FacePresenceDetecting {
    private let result: CameraFaceDetectionResult
    private(set) var requestedTimeouts: [TimeInterval] = []

    init(result: CameraFaceDetectionResult) {
        self.result = result
    }

    func detectFace(timeout: TimeInterval) async -> CameraFaceDetectionResult {
        requestedTimeouts.append(timeout)
        return result
    }
}

private final class SpyFacePresenceManualFill {
    private let result: ManualFillResult
    private(set) var callCount = 0
    private(set) var forbiddenConfirmationActionCount = 0

    init(result: ManualFillResult) {
        self.result = result
    }

    func fillFocusedPasswordField() -> ManualFillResult {
        callCount += 1
        return result
    }
}
