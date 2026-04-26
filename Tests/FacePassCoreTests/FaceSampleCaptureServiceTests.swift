import CoreGraphics
import XCTest
@testable import FacePassCore

final class FaceSampleCaptureServiceTests: XCTestCase {
    func testPermissionDeniedDoesNotStartSession() async {
        let harness = FaceSampleCaptureHarness(permissionStatus: .denied)

        let result = await harness.service.captureSample(timeout: 5)

        XCTAssertResult(result, is: .permissionDenied)
        XCTAssertEqual(harness.permissions.authorizationChecks, 1)
        XCTAssertEqual(harness.permissions.authorizationRequests, 0)
        XCTAssertEqual(harness.session.startCount, 0)
        XCTAssertEqual(harness.session.stopCount, 0)
    }

    func testNotDeterminedPermissionRequestsBeforeCapture() async {
        let harness = FaceSampleCaptureHarness(
            permissionStatus: .notDetermined,
            requestedPermissionStatus: .authorized
        )

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([singleFaceBounds]))
        harness.session.emitFrame()

        let result = await task.value

        guard case let .captured(summary) = result else {
            return XCTFail("Expected captured result, got \(result).")
        }
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.sample.visionNormalizedFaceBounds, singleFaceBounds)
        XCTAssertEqual(summary.sample.image.width, 8)
        XCTAssertEqual(summary.sample.image.height, 8)
        XCTAssertEqual(harness.permissions.authorizationChecks, 1)
        XCTAssertEqual(harness.permissions.authorizationRequests, 1)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.faceDetector.detectedFrameCount, 1)
        XCTAssertEqual(harness.imageConverter.conversionCount, 1)
    }

    func testNotDeterminedPermissionRequestDeniedDoesNotStartSession() async {
        let harness = FaceSampleCaptureHarness(
            permissionStatus: .notDetermined,
            requestedPermissionStatus: .denied
        )

        let result = await harness.service.captureSample(timeout: 5)

        XCTAssertResult(result, is: .permissionDenied)
        XCTAssertEqual(harness.permissions.authorizationChecks, 1)
        XCTAssertEqual(harness.permissions.authorizationRequests, 1)
        XCTAssertEqual(harness.session.startCount, 0)
        XCTAssertEqual(harness.session.stopCount, 0)
    }

    func testNoFaceFrameContinuesUntilUsableSingleFaceAppears() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([]))
        harness.session.emitFrame()
        await harness.faceDetector.waitUntilDetectedFrameCount(1)

        XCTAssertEqual(harness.session.events, [.started])
        XCTAssertEqual(harness.imageConverter.conversionCount, 0)

        harness.faceDetector.enqueue(.bounds([singleFaceBounds]))
        harness.session.emitFrame()

        let result = await task.value
        guard case let .captured(summary) = result else {
            return XCTFail("Expected captured result, got \(result).")
        }
        XCTAssertEqual(summary.processedFrameCount, 2)
        XCTAssertEqual(summary.sample.visionNormalizedFaceBounds, singleFaceBounds)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.faceDetector.detectedFrameCount, 2)
        XCTAssertEqual(harness.imageConverter.conversionCount, 1)
    }

    func testNoFaceFramesContinueUntilTimeoutWithoutImageConversion() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([]))
        harness.session.emitFrame()
        await harness.faceDetector.waitUntilDetectedFrameCount(1)
        harness.faceDetector.enqueue(.bounds([]))
        harness.session.emitFrame()
        await harness.faceDetector.waitUntilDetectedFrameCount(2)
        harness.timeoutScheduler.fireNextTimeout()

        let result = await task.value

        XCTAssertResult(result, is: .timedOut)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.faceDetector.detectedFrameCount, 2)
        XCTAssertEqual(harness.imageConverter.conversionCount, 0)
    }

    func testMultipleFacesStopsSessionWithoutImageConversion() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([
            singleFaceBounds,
            CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        ]))
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertResult(result, is: .multipleFaces)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.faceDetector.detectedFrameCount, 1)
        XCTAssertEqual(harness.imageConverter.conversionCount, 0)
    }

    func testRecognitionModeMultipleFacesReturnsMultipleInMemoryCandidatesFromOneFrame() async {
        let harness = FaceSampleCaptureHarness()
        let secondFaceBounds = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)

        let task = Task {
            await harness.service.captureSample(timeout: 5, mode: .recognition)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([
            singleFaceBounds,
            secondFaceBounds
        ]))
        harness.session.emitFrame()

        let result = await task.value

        guard case let .captured(summary) = result else {
            return XCTFail("Expected captured result, got \(result).")
        }
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.samples.map(\.visionNormalizedFaceBounds), [
            singleFaceBounds,
            secondFaceBounds
        ])
        XCTAssertEqual(summary.sample.visionNormalizedFaceBounds, singleFaceBounds)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.faceDetector.detectedFrameCount, 1)
        XCTAssertEqual(harness.imageConverter.conversionCount, 1)
    }

    func testImageConversionFailureStopsSessionAndReturnsNoUsableSample() async {
        let harness = FaceSampleCaptureHarness(imageConversionError: .missingSampleBuffer)

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([singleFaceBounds]))
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertResult(result, is: .noUsableSample(.missingSampleBuffer))
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.imageConverter.conversionCount, 1)
    }

    func testTimeoutStartsThenStopsSession() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.timeoutScheduler.fireNextTimeout()

        let result = await task.value

        XCTAssertResult(result, is: .timedOut)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.faceDetector.detectedFrameCount, 0)
    }

    func testCancellationStopsSession() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        task.cancel()

        let result = await task.value

        XCTAssertResult(result, is: .cancelled)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
    }

    func testDetectorFailureStopsSession() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.failure)
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertResult(result, is: .failed(.faceDetectionFailed))
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.imageConverter.conversionCount, 0)
    }

    func testInvalidSingleFaceBoundsFailsClosedWithoutImageConversion() async {
        let invalidBoundsCases = [
            CGRect(x: -0.01, y: 0.25, width: 0.5, height: 0.5),
            CGRect(x: 0.25, y: -0.01, width: 0.5, height: 0.5),
            CGRect(x: 0.25, y: 0.25, width: 0, height: 0.5),
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0),
            CGRect(x: 0.75, y: 0.25, width: 0.3, height: 0.5),
            CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.3),
            CGRect(x: .nan, y: 0.25, width: 0.5, height: 0.5),
            CGRect(x: 0.25, y: .infinity, width: 0.5, height: 0.5)
        ]

        for invalidBounds in invalidBoundsCases {
            let harness = FaceSampleCaptureHarness()

            let task = Task {
                await harness.service.captureSample(timeout: 5)
            }
            await harness.session.waitUntilStarted()
            harness.faceDetector.enqueue(.bounds([invalidBounds]))
            harness.session.emitFrame()

            let result = await task.value

            XCTAssertResult(result, is: .failed(.invalidFaceBounds))
            XCTAssertEqual(harness.session.events, [.started, .stopped])
            XCTAssertEqual(harness.faceDetector.detectedFrameCount, 1)
            XCTAssertEqual(harness.imageConverter.conversionCount, 0)
            XCTAssertFalse(mirrorContainsFramePayload(result))
        }
    }

    func testValidEdgeAlignedSingleFaceBoundsCapture() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        let fullFrameBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        harness.faceDetector.enqueue(.bounds([fullFrameBounds]))
        harness.session.emitFrame()

        let result = await task.value

        guard case let .captured(summary) = result else {
            return XCTFail("Expected captured result, got \(result).")
        }
        XCTAssertEqual(summary.sample.visionNormalizedFaceBounds, fullFrameBounds)
        XCTAssertEqual(harness.imageConverter.conversionCount, 1)
    }

    func testNonCapturedResultsDoNotPersistFramePayload() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.faceDetector.enqueue(.bounds([]))
        harness.session.emitFrame()
        await harness.faceDetector.waitUntilDetectedFrameCount(1)
        harness.timeoutScheduler.fireNextTimeout()

        let result = await task.value

        XCTAssertResult(result, is: .timedOut)
        XCTAssertFalse(mirrorContainsFramePayload(result))
    }

    func testCaptureFailureStopsSession() async {
        let harness = FaceSampleCaptureHarness()

        let task = Task {
            await harness.service.captureSample(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.session.failCapture()

        let result = await task.value

        XCTAssertResult(result, is: .failed(.captureFailed))
        XCTAssertEqual(harness.session.events, [.started, .stopped])
    }

    func testSessionStartFailureStopsSessionAndCancelsTimeout() async {
        let harness = FaceSampleCaptureHarness(sessionStartResult: .failed)

        let result = await harness.service.captureSample(timeout: 5)

        XCTAssertResult(result, is: .failed(.sessionStartFailed))
        XCTAssertEqual(harness.session.startCount, 1)
        XCTAssertEqual(harness.session.stopCallCount, 1)
        XCTAssertEqual(harness.session.stopCount, 0)
        XCTAssertEqual(harness.timeoutScheduler.cancelledTimeoutCount, 1)
    }

    private var singleFaceBounds: CGRect {
        CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    }

    private func XCTAssertResult(
        _ result: FaceSampleCaptureResult,
        is expected: ComparableFaceSampleCaptureResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.permissionDenied, .permissionDenied),
             (.timedOut, .timedOut),
             (.cancelled, .cancelled),
             (.noFace, .noFace),
             (.multipleFaces, .multipleFaces):
            return
        case let (.noUsableSample(actual), .noUsableSample(expected)):
            XCTAssertEqual(actual, expected, file: file, line: line)
        case let (.failed(actual), .failed(expected)):
            XCTAssertEqual(actual, expected, file: file, line: line)
        default:
            XCTFail("Expected \(expected), got \(result).", file: file, line: line)
        }
    }

    private func mirrorContainsFramePayload(_ value: Any) -> Bool {
        if value is CameraFaceDetectionFrame {
            return true
        }

        return Mirror(reflecting: value).children.contains { child in
            mirrorContainsFramePayload(child.value)
        }
    }
}

private final class FaceSampleCaptureHarness {
    let permissions: StubFaceSampleCapturePermissionProvider
    let session: SpyFaceSampleCaptureSession
    let faceDetector: StubFaceSampleCaptureFaceDetector
    let imageConverter: StubFaceSampleCaptureImageConverter
    let timeoutScheduler: ManualFaceSampleCaptureTimeoutScheduler
    let service: FaceSampleCaptureService

    init(
        permissionStatus: CameraFaceDetectionPermissionStatus = .authorized,
        requestedPermissionStatus: CameraFaceDetectionPermissionStatus = .authorized,
        sessionStartResult: CameraFaceDetectionSessionStartResult = .started,
        imageConversionError: FaceSampleCaptureImageConversionError? = nil
    ) {
        self.permissions = StubFaceSampleCapturePermissionProvider(
            status: permissionStatus,
            requestedStatus: requestedPermissionStatus
        )
        self.session = SpyFaceSampleCaptureSession(startResult: sessionStartResult)
        self.faceDetector = StubFaceSampleCaptureFaceDetector()
        self.imageConverter = StubFaceSampleCaptureImageConverter(error: imageConversionError)
        self.timeoutScheduler = ManualFaceSampleCaptureTimeoutScheduler()
        self.service = FaceSampleCaptureService(
            permissionProvider: permissions,
            session: session,
            faceDetector: faceDetector,
            imageConverter: imageConverter,
            timeoutScheduler: timeoutScheduler
        )
    }
}

private final class StubFaceSampleCapturePermissionProvider: CameraFaceDetectionPermissionProviding {
    private let status: CameraFaceDetectionPermissionStatus
    private let requestedStatus: CameraFaceDetectionPermissionStatus
    private(set) var authorizationChecks = 0
    private(set) var authorizationRequests = 0

    init(
        status: CameraFaceDetectionPermissionStatus,
        requestedStatus: CameraFaceDetectionPermissionStatus
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
    }

    func cameraAuthorizationStatus() -> CameraFaceDetectionPermissionStatus {
        authorizationChecks += 1
        return status
    }

    func requestCameraAuthorization() async -> CameraFaceDetectionPermissionStatus {
        authorizationRequests += 1
        return requestedStatus
    }
}

private final class SpyFaceSampleCaptureSession: CameraFaceDetectionSession {
    private let startResult: CameraFaceDetectionSessionStartResult
    private var onFrame: ((CameraFaceDetectionFrame) -> Void)?
    private var onFailure: (() -> Void)?

    private(set) var events: [FaceSampleCaptureSessionEvent] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopCallCount = 0
    private(set) var isRunning = false

    init(startResult: CameraFaceDetectionSessionStartResult = .started) {
        self.startResult = startResult
    }

    func start(
        onFrame: @escaping (CameraFaceDetectionFrame) -> Void,
        onFailure: @escaping () -> Void
    ) -> CameraFaceDetectionSessionStartResult {
        startCount += 1
        if startResult == .started {
            isRunning = true
            events.append(.started)
        }
        self.onFrame = onFrame
        self.onFailure = onFailure
        return startResult
    }

    func stop() {
        stopCallCount += 1
        guard isRunning else {
            return
        }
        stopCount += 1
        isRunning = false
        events.append(.stopped)
    }

    func emitFrame() {
        onFrame?(CameraFaceDetectionFrame())
    }

    func failCapture() {
        onFailure?()
    }

    func waitUntilStarted(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if startCount > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTFail("Timed out waiting for face sample capture session to start.", file: file, line: line)
    }
}

private enum FaceSampleCaptureSessionEvent: Equatable {
    case started
    case stopped
}

private final class StubFaceSampleCaptureFaceDetector: FaceSampleCaptureFaceDetecting {
    enum NextResult {
        case bounds([CGRect])
        case failure
    }

    private var queuedResults: [NextResult] = []
    private(set) var detectedFrameCount = 0

    func enqueue(_ result: NextResult) {
        queuedResults.append(result)
    }

    func detectFaceBounds(in frame: CameraFaceDetectionFrame) async throws -> [CGRect] {
        detectedFrameCount += 1
        switch queuedResults.isEmpty ? .bounds([]) : queuedResults.removeFirst() {
        case let .bounds(bounds):
            return bounds
        case .failure:
            throw StubFaceSampleCaptureError.failed
        }
    }

    func waitUntilDetectedFrameCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if detectedFrameCount >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTFail("Timed out waiting for \(expectedCount) face sample detections.", file: file, line: line)
    }
}

private final class StubFaceSampleCaptureImageConverter: FaceSampleCaptureImageConverting {
    private let image: CGImage
    private let error: FaceSampleCaptureImageConversionError?
    private(set) var conversionCount = 0

    init(error: FaceSampleCaptureImageConversionError? = nil) {
        self.image = StubFaceSampleCaptureImageConverter.makeImage()
        self.error = error
    }

    func makeCGImage(from frame: CameraFaceDetectionFrame) throws -> CGImage {
        conversionCount += 1
        if let error {
            throw error
        }
        return image
    }

    private static func makeImage() -> CGImage {
        let width = 8
        let height = 8
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bytes = Data(repeating: 255, count: height * bytesPerRow)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            fatalError("Failed to create synthetic test image.")
        }

        return image
    }
}

private final class ManualFaceSampleCaptureTimeoutScheduler: CameraFaceDetectionTimeoutScheduling {
    private var scheduledTimeouts: [() -> Void] = []
    private(set) var cancelledTimeoutCount = 0

    func scheduleTimeout(
        after timeout: TimeInterval,
        _ action: @escaping () -> Void
    ) -> CameraFaceDetectionCancellable {
        scheduledTimeouts.append(action)
        return ManualFaceSampleCaptureCancellable { [weak self] in
            self?.cancelledTimeoutCount += 1
        }
    }

    func fireNextTimeout() {
        guard !scheduledTimeouts.isEmpty else {
            return
        }

        scheduledTimeouts.removeFirst()()
    }
}

private final class ManualFaceSampleCaptureCancellable: CameraFaceDetectionCancellable {
    private let onCancel: () -> Void
    private var isCancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else {
            return
        }

        isCancelled = true
        onCancel()
    }
}

private enum ComparableFaceSampleCaptureResult: CustomStringConvertible {
    case permissionDenied
    case timedOut
    case cancelled
    case noFace
    case multipleFaces
    case noUsableSample(FaceSampleCaptureImageConversionError)
    case failed(FaceSampleCaptureFailureReason)

    var description: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied"
        case .timedOut:
            return "timedOut"
        case .cancelled:
            return "cancelled"
        case .noFace:
            return "noFace"
        case .multipleFaces:
            return "multipleFaces"
        case let .noUsableSample(reason):
            return "noUsableSample(\(reason))"
        case let .failed(reason):
            return "failed(\(reason))"
        }
    }
}

private enum StubFaceSampleCaptureError: Error {
    case failed
}
