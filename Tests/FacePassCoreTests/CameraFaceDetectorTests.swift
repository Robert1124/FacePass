import XCTest
@testable import FacePassCore

final class CameraFaceDetectorTests: XCTestCase {
    func testPermissionDeniedDoesNotStartSession() async {
        let harness = CameraFaceDetectorHarness(permissionStatus: .denied)

        let result = await harness.detector.detectFace(timeout: 5)

        XCTAssertEqual(result, .permissionDenied)
        XCTAssertEqual(harness.permissions.authorizationChecks, 1)
        XCTAssertEqual(harness.permissions.authorizationRequests, 0)
        XCTAssertEqual(harness.session.startCount, 0)
        XCTAssertEqual(harness.session.stopCount, 0)
    }

    func testNotDeterminedPermissionRequestsBeforeStartingSession() async {
        let harness = CameraFaceDetectorHarness(
            permissionStatus: .notDetermined,
            requestedPermissionStatus: .authorized
        )

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.faceCount(1))
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertEqual(result, .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        XCTAssertEqual(harness.permissions.authorizationChecks, 1)
        XCTAssertEqual(harness.permissions.authorizationRequests, 1)
        XCTAssertEqual(harness.session.startCount, 1)
        XCTAssertEqual(harness.session.stopCount, 1)
    }

    func testNotDeterminedPermissionDeniedAfterRequestDoesNotStartSession() async {
        let harness = CameraFaceDetectorHarness(
            permissionStatus: .notDetermined,
            requestedPermissionStatus: .denied
        )

        let result = await harness.detector.detectFace(timeout: 5)

        XCTAssertEqual(result, .permissionDenied)
        XCTAssertEqual(harness.permissions.authorizationChecks, 1)
        XCTAssertEqual(harness.permissions.authorizationRequests, 1)
        XCTAssertEqual(harness.session.startCount, 0)
        XCTAssertEqual(harness.session.stopCallCount, 0)
        XCTAssertEqual(harness.timeoutScheduler.cancelledTimeoutCount, 0)
    }

    func testDetectionSuccessStartsThenStopsSession() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.faceCount(1))
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertEqual(result, .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 1)
        XCTAssertResultDoesNotPersistFramePayload(result)
    }

    func testTimeoutStartsThenStopsSessionAndReturnsTimeout() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.timeoutScheduler.fireNextTimeout()

        let result = await task.value

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 0)
    }

    func testTimeoutCanCompleteWhileSessionStartIsBlocked() async {
        let permissions = StubCameraFaceDetectionPermissionProvider(
            status: .authorized,
            requestedStatus: .authorized
        )
        let session = BlockingStartCameraFaceDetectionSession()
        let detectorAdapter = StubVisionFaceDetectionRequest()
        let timeoutScheduler = ManualCameraFaceDetectionTimeoutScheduler()
        let detector = CameraFaceDetector(
            permissionProvider: permissions,
            session: session,
            faceDetectionRequest: detectorAdapter,
            timeoutScheduler: timeoutScheduler
        )

        let task = Task {
            await detector.detectFace(timeout: 5)
        }
        await fulfillment(of: [session.startEntered], timeout: 1)
        await timeoutScheduler.waitUntilTimeoutScheduled()

        timeoutScheduler.fireNextTimeout()
        let result = await task.value

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(session.stopCallCount, 1)

        session.releaseStart()
        await fulfillment(of: [session.startReturned], timeout: 1)
        await waitForBlockedStartSessionToStop(session)

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.stopCallCount, 2)
    }

    func testNonFaceFrameKeepsSessionRunningUntilTimeout() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.faceCount(0))
        harness.session.emitFrame()
        await waitForDetectedFrameCount(1, in: harness)

        XCTAssertTrue(harness.session.isRunning)
        XCTAssertEqual(harness.session.stopCount, 0)

        harness.timeoutScheduler.fireNextTimeout()
        let result = await task.value

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 1)
    }

    func testCancellationStopsSessionAndReturnsCancelled() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        task.cancel()

        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
    }

    func testNonFaceFrameKeepsSessionRunningUntilCancellation() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.faceCount(0))
        harness.session.emitFrame()
        await waitForDetectedFrameCount(1, in: harness)

        XCTAssertTrue(harness.session.isRunning)
        XCTAssertEqual(harness.session.stopCount, 0)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 1)
    }

    func testDetectorFailureStopsSessionAndReturnsFailed() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.failure)
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertEqual(result, .failed(.faceDetectionFailed))
        XCTAssertEqual(harness.session.events, [.started, .stopped])
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 1)
    }

    func testCaptureFailureStopsSessionAndReturnsFailed() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.session.failCapture()

        let result = await task.value

        XCTAssertEqual(result, .failed(.captureFailed))
        XCTAssertEqual(harness.session.events, [.started, .stopped])
    }

    func testSessionStartFailureStopsSessionAndReturnsFailed() async {
        let harness = CameraFaceDetectorHarness(sessionStartResult: .failed)

        let result = await harness.detector.detectFace(timeout: 5)

        XCTAssertEqual(result, .failed(.sessionStartFailed))
        XCTAssertEqual(harness.session.startCount, 1)
        XCTAssertEqual(harness.session.stopCallCount, 1)
        XCTAssertEqual(harness.session.stopCount, 0)
        XCTAssertFalse(harness.session.isRunning)
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 0)
        XCTAssertEqual(harness.timeoutScheduler.cancelledTimeoutCount, 1)
    }

    func testMultipleFramesStopAfterFirstFace() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.faceCount(1))
        harness.detectorAdapter.enqueue(.faceCount(1))
        harness.session.emitFrame()
        harness.session.emitFrame()

        let result = await task.value

        XCTAssertEqual(result, .detected(CameraFaceDetectionSummary(faceCount: 1, processedFrameCount: 1)))
        XCTAssertEqual(harness.session.stopCount, 1)
        XCTAssertEqual(harness.detectorAdapter.detectedFrameCount, 1)
    }

    func testSessionIsNotPersistentAfterCompletion() async {
        let harness = CameraFaceDetectorHarness()

        let task = Task {
            await harness.detector.detectFace(timeout: 5)
        }
        await harness.session.waitUntilStarted()
        harness.detectorAdapter.enqueue(.faceCount(1))
        harness.session.emitFrame()
        _ = await task.value

        XCTAssertFalse(harness.session.isRunning)
        XCTAssertEqual(harness.timeoutScheduler.cancelledTimeoutCount, 1)
    }

    private func XCTAssertResultDoesNotPersistFramePayload(
        _ result: CameraFaceDetectionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            mirrorContainsFramePayload(result),
            "Detection result must not retain raw frames or frame payload wrappers.",
            file: file,
            line: line
        )
    }

    private func mirrorContainsFramePayload(_ value: Any) -> Bool {
        if value is CameraFaceDetectionFrame {
            return true
        }

        return Mirror(reflecting: value).children.contains { child in
            guard let childValue = child.value as Any? else {
                return false
            }
            return mirrorContainsFramePayload(childValue)
        }
    }

    private func waitForDetectedFrameCount(
        _ expectedCount: Int,
        in harness: CameraFaceDetectorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if harness.detectorAdapter.detectedFrameCount >= expectedCount {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for frame detection count \(expectedCount).", file: file, line: line)
    }

    private func waitForBlockedStartSessionToStop(
        _ session: BlockingStartCameraFaceDetectionSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !session.isRunning, session.stopCallCount >= 2 {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for blocked start session to stop.", file: file, line: line)
    }
}

private final class CameraFaceDetectorHarness {
    let permissions: StubCameraFaceDetectionPermissionProvider
    let session: SpyCameraFaceDetectionSession
    let detectorAdapter: StubVisionFaceDetectionRequest
    let timeoutScheduler: ManualCameraFaceDetectionTimeoutScheduler
    let detector: CameraFaceDetector

    init(
        permissionStatus: CameraFaceDetectionPermissionStatus = .authorized,
        requestedPermissionStatus: CameraFaceDetectionPermissionStatus = .authorized,
        sessionStartResult: CameraFaceDetectionSessionStartResult = .started
    ) {
        self.permissions = StubCameraFaceDetectionPermissionProvider(
            status: permissionStatus,
            requestedStatus: requestedPermissionStatus
        )
        self.session = SpyCameraFaceDetectionSession(startResult: sessionStartResult)
        self.detectorAdapter = StubVisionFaceDetectionRequest()
        self.timeoutScheduler = ManualCameraFaceDetectionTimeoutScheduler()
        self.detector = CameraFaceDetector(
            permissionProvider: permissions,
            session: session,
            faceDetectionRequest: detectorAdapter,
            timeoutScheduler: timeoutScheduler
        )
    }
}

private final class StubCameraFaceDetectionPermissionProvider: CameraFaceDetectionPermissionProviding {
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

private final class SpyCameraFaceDetectionSession: CameraFaceDetectionSession {
    private let startResult: CameraFaceDetectionSessionStartResult
    private var onFrame: ((CameraFaceDetectionFrame) -> Void)?
    private var onFailure: (() -> Void)?

    private(set) var events: [CameraFaceDetectionSessionEvent] = []
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

        XCTFail("Timed out waiting for camera face detection session to start.", file: file, line: line)
    }
}

private final class BlockingStartCameraFaceDetectionSession: CameraFaceDetectionSession {
    let startEntered = XCTestExpectation(description: "Blocking camera session start entered")
    let startReturned = XCTestExpectation(description: "Blocking camera session start returned")

    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var onFrame: ((CameraFaceDetectionFrame) -> Void)?
    private var onFailure: (() -> Void)?
    private var storedStopCallCount = 0
    private var storedIsRunning = false

    var stopCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedStopCallCount
    }

    var isRunning: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedIsRunning
    }

    func start(
        onFrame: @escaping (CameraFaceDetectionFrame) -> Void,
        onFailure: @escaping () -> Void
    ) -> CameraFaceDetectionSessionStartResult {
        lock.lock()
        self.onFrame = onFrame
        self.onFailure = onFailure
        lock.unlock()

        startEntered.fulfill()
        releaseSemaphore.wait()

        lock.lock()
        storedIsRunning = true
        lock.unlock()

        startReturned.fulfill()
        return .started
    }

    func stop() {
        lock.lock()
        storedStopCallCount += 1
        storedIsRunning = false
        lock.unlock()
    }

    func releaseStart() {
        releaseSemaphore.signal()
    }
}

private enum CameraFaceDetectionSessionEvent: Equatable {
    case started
    case stopped
}

private final class StubVisionFaceDetectionRequest: CameraFaceDetectionRequesting {
    enum NextResult {
        case faceCount(Int)
        case failure
    }

    private var queuedResults: [NextResult] = []
    private(set) var detectedFrameCount = 0

    func enqueue(_ result: NextResult) {
        queuedResults.append(result)
    }

    func detectFaces(in frame: CameraFaceDetectionFrame) async throws -> CameraFaceDetectionObservation {
        detectedFrameCount += 1
        switch queuedResults.isEmpty ? .faceCount(0) : queuedResults.removeFirst() {
        case let .faceCount(count):
            return CameraFaceDetectionObservation(faceCount: count)
        case .failure:
            throw StubVisionFaceDetectionError.failed
        }
    }
}

private enum StubVisionFaceDetectionError: Error {
    case failed
}

private final class ManualCameraFaceDetectionTimeoutScheduler: CameraFaceDetectionTimeoutScheduling {
    private var scheduledTimeouts: [() -> Void] = []
    private(set) var cancelledTimeoutCount = 0

    func scheduleTimeout(
        after timeout: TimeInterval,
        _ action: @escaping () -> Void
    ) -> CameraFaceDetectionCancellable {
        scheduledTimeouts.append(action)
        return ManualCameraFaceDetectionCancellable { [weak self] in
            self?.cancelledTimeoutCount += 1
        }
    }

    func fireNextTimeout() {
        guard !scheduledTimeouts.isEmpty else {
            return
        }

        scheduledTimeouts.removeFirst()()
    }

    func waitUntilTimeoutScheduled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !scheduledTimeouts.isEmpty {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for camera face detection timeout to be scheduled.", file: file, line: line)
    }
}

private final class ManualCameraFaceDetectionCancellable: CameraFaceDetectionCancellable {
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
