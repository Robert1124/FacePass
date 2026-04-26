import AVFoundation
import Foundation
import ImageIO
import Vision

public protocol CameraFaceDetectionPermissionProviding {
    func cameraAuthorizationStatus() -> CameraFaceDetectionPermissionStatus
    func requestCameraAuthorization() async -> CameraFaceDetectionPermissionStatus
}

public protocol CameraFaceDetectionSession: AnyObject {
    func start(
        onFrame: @escaping (CameraFaceDetectionFrame) -> Void,
        onFailure: @escaping () -> Void
    ) -> CameraFaceDetectionSessionStartResult
    func stop()
}

public protocol CameraFaceDetectionRequesting {
    func detectFaces(in frame: CameraFaceDetectionFrame) async throws -> CameraFaceDetectionObservation
}

public protocol CameraFaceDetectionTimeoutScheduling {
    func scheduleTimeout(
        after timeout: TimeInterval,
        _ action: @escaping () -> Void
    ) -> CameraFaceDetectionCancellable
}

public protocol CameraFaceDetectionCancellable: AnyObject {
    func cancel()
}

public final class CameraFaceDetector {
    private let permissionProvider: any CameraFaceDetectionPermissionProviding
    private let session: any CameraFaceDetectionSession
    private let faceDetectionRequest: any CameraFaceDetectionRequesting
    private let timeoutScheduler: any CameraFaceDetectionTimeoutScheduling
    private let sessionStartQueue = DispatchQueue(label: "com.facepass.camera-face-detector.session-start")

    public init(
        permissionProvider: any CameraFaceDetectionPermissionProviding = SystemCameraFaceDetectionPermissionProvider(),
        session: any CameraFaceDetectionSession = AVCaptureCameraFaceDetectionSession(),
        faceDetectionRequest: any CameraFaceDetectionRequesting = VisionFaceDetectionRequest(),
        timeoutScheduler: any CameraFaceDetectionTimeoutScheduling = TaskCameraFaceDetectionTimeoutScheduler()
    ) {
        self.permissionProvider = permissionProvider
        self.session = session
        self.faceDetectionRequest = faceDetectionRequest
        self.timeoutScheduler = timeoutScheduler
    }

    public func detectFace(timeout: TimeInterval) async -> CameraFaceDetectionResult {
        let permissionStatus = await resolvedCameraPermissionStatus()
        guard permissionStatus == .authorized else {
            return .permissionDenied
        }

        if Task.isCancelled {
            return .cancelled
        }

        let runState = CameraFaceDetectionRunState(session: session)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                runState.setContinuation(continuation)
                guard runState.shouldContinue else {
                    return
                }

                let timeoutToken = timeoutScheduler.scheduleTimeout(after: timeout) {
                    runState.finish(.timedOut)
                }
                runState.setTimeoutToken(timeoutToken)
                guard runState.shouldContinue else {
                    return
                }

                let session = UncheckedSendable(self.session)
                let faceDetectionRequest = UncheckedSendable(self.faceDetectionRequest)
                sessionStartQueue.async {
                    guard runState.shouldContinue else {
                        return
                    }

                    let startResult = session.value.start(
                        onFrame: { frame in
                            guard let processedFrameCount = runState.beginProcessingFrame() else {
                                return
                            }

                            Task {
                                do {
                                    let observation = try await faceDetectionRequest.value.detectFaces(in: frame)
                                    if observation.faceCount > 0 {
                                        runState.finish(.detected(CameraFaceDetectionSummary(
                                            faceCount: observation.faceCount,
                                            processedFrameCount: processedFrameCount
                                        )))
                                    } else {
                                        runState.finishProcessingFrameWithoutFace()
                                    }
                                } catch {
                                    runState.finish(.failed(.faceDetectionFailed))
                                }
                            }
                        },
                        onFailure: {
                            runState.finish(.failed(.captureFailed))
                        }
                    )

                    switch startResult {
                    case .started:
                        guard runState.shouldContinue else {
                            session.value.stop()
                            return
                        }
                    case .failed:
                        runState.finish(.failed(.sessionStartFailed))
                    }
                }
            }
        } onCancel: {
            runState.finish(.cancelled)
        }
    }

    private func resolvedCameraPermissionStatus() async -> CameraFaceDetectionPermissionStatus {
        let currentStatus = permissionProvider.cameraAuthorizationStatus()
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await permissionProvider.requestCameraAuthorization()
    }
}

public enum CameraFaceDetectionPermissionStatus: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown
}

public enum CameraFaceDetectionSessionStartResult: Equatable {
    case started
    case failed
}

public struct CameraFaceDetectionFrame {
    let sampleBuffer: CMSampleBuffer?

    public init() {
        self.sampleBuffer = nil
    }

    init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

public struct CameraFaceDetectionObservation: Equatable {
    public let faceCount: Int

    public init(faceCount: Int) {
        self.faceCount = max(0, faceCount)
    }
}

public struct CameraFaceDetectionSummary: Equatable {
    public let faceCount: Int
    public let processedFrameCount: Int

    public init(faceCount: Int, processedFrameCount: Int) {
        self.faceCount = max(0, faceCount)
        self.processedFrameCount = max(0, processedFrameCount)
    }
}

public enum CameraFaceDetectionResult: Equatable {
    case detected(CameraFaceDetectionSummary)
    case permissionDenied
    case timedOut
    case cancelled
    case failed(CameraFaceDetectionFailureReason)
}

public enum CameraFaceDetectionFailureReason: Equatable {
    case sessionStartFailed
    case captureFailed
    case faceDetectionFailed
}

public struct SystemCameraFaceDetectionPermissionProvider: CameraFaceDetectionPermissionProviding {
    public init() {}

    public func cameraAuthorizationStatus() -> CameraFaceDetectionPermissionStatus {
        AVCaptureDevice.authorizationStatus(for: .video).cameraFaceDetectionStatus
    }

    public func requestCameraAuthorization() async -> CameraFaceDetectionPermissionStatus {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { isGranted in
                continuation.resume(returning: isGranted ? .authorized : .denied)
            }
        }
    }
}

public final class AVCaptureCameraFaceDetectionSession: NSObject, CameraFaceDetectionSession {
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.facepass.camera-face-detector.capture")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var frameHandler: ((CameraFaceDetectionFrame) -> Void)?
    private var failureHandler: (() -> Void)?

    public override init() {
        super.init()
    }

    public func start(
        onFrame: @escaping (CameraFaceDetectionFrame) -> Void,
        onFailure: @escaping () -> Void
    ) -> CameraFaceDetectionSessionStartResult {
        frameHandler = onFrame
        failureHandler = onFailure

        do {
            try configureCaptureSession()
        } catch {
            stop()
            return .failed
        }

        captureSession.startRunning()
        return captureSession.isRunning ? .started : .failed
    }

    public func stop() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }

        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        captureSession.commitConfiguration()

        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoOutput = nil
        frameHandler = nil
        failureHandler = nil
    }

    private func configureCaptureSession() throws {
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }

        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        captureSession.sessionPreset = .low

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraFaceDetectionCaptureError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw CameraFaceDetectionCaptureError.cannotAddInput
        }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard captureSession.canAddOutput(output) else {
            throw CameraFaceDetectionCaptureError.cannotAddOutput
        }
        captureSession.addOutput(output)
        videoOutput = output
    }
}

extension AVCaptureCameraFaceDetectionSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameHandler?(CameraFaceDetectionFrame(sampleBuffer: sampleBuffer))
    }
}

public struct VisionFaceDetectionRequest: CameraFaceDetectionRequesting {
    public init() {}

    public func detectFaces(in frame: CameraFaceDetectionFrame) async throws -> CameraFaceDetectionObservation {
        guard let sampleBuffer = frame.sampleBuffer else {
            return CameraFaceDetectionObservation(faceCount: 0)
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])

        return CameraFaceDetectionObservation(faceCount: request.results?.count ?? 0)
    }
}

public struct TaskCameraFaceDetectionTimeoutScheduler: CameraFaceDetectionTimeoutScheduling {
    public init() {}

    public func scheduleTimeout(
        after timeout: TimeInterval,
        _ action: @escaping () -> Void
    ) -> CameraFaceDetectionCancellable {
        TaskCameraFaceDetectionTimeout(timeout: timeout, action: action)
    }
}

private final class TaskCameraFaceDetectionTimeout: CameraFaceDetectionCancellable {
    private let task: Task<Void, Never>

    init(timeout: TimeInterval, action: @escaping () -> Void) {
        self.task = Task {
            let nanoseconds = Self.nanoseconds(for: timeout)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }
            action()
        }
    }

    func cancel() {
        task.cancel()
    }

    private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        guard timeout.isFinite, timeout > 0 else {
            return 0
        }

        let maximumSeconds = TimeInterval(UInt64.max) / 1_000_000_000
        let boundedTimeout = min(timeout, maximumSeconds)
        return UInt64(boundedTimeout * 1_000_000_000)
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class CameraFaceDetectionRunState: @unchecked Sendable {
    private let session: any CameraFaceDetectionSession
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CameraFaceDetectionResult, Never>?
    private var completedResult: CameraFaceDetectionResult?
    private var timeoutToken: (any CameraFaceDetectionCancellable)?
    private var isFinished = false
    private var isProcessingFrame = false
    private var processedFrameCount = 0

    init(session: any CameraFaceDetectionSession) {
        self.session = session
    }

    var shouldContinue: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return !isFinished
    }

    func setContinuation(_ continuation: CheckedContinuation<CameraFaceDetectionResult, Never>) {
        var resultToResume: CameraFaceDetectionResult?
        lock.lock()
        if let completedResult {
            resultToResume = completedResult
        } else {
            self.continuation = continuation
        }
        lock.unlock()

        if let resultToResume {
            continuation.resume(returning: resultToResume)
        }
    }

    func setTimeoutToken(_ token: any CameraFaceDetectionCancellable) {
        var shouldCancel = false
        lock.lock()
        if isFinished {
            shouldCancel = true
        } else {
            timeoutToken = token
        }
        lock.unlock()

        if shouldCancel {
            token.cancel()
        }
    }

    func beginProcessingFrame() -> Int? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !isFinished, !isProcessingFrame else {
            return nil
        }

        isProcessingFrame = true
        processedFrameCount += 1
        return processedFrameCount
    }

    func finishProcessingFrameWithoutFace() {
        lock.lock()
        if !isFinished {
            isProcessingFrame = false
        }
        lock.unlock()
    }

    func finish(_ result: CameraFaceDetectionResult) {
        var continuationToResume: CheckedContinuation<CameraFaceDetectionResult, Never>?
        var timeoutTokenToCancel: (any CameraFaceDetectionCancellable)?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        isProcessingFrame = false
        completedResult = result
        continuationToResume = continuation
        continuation = nil
        timeoutTokenToCancel = timeoutToken
        timeoutToken = nil
        lock.unlock()

        timeoutTokenToCancel?.cancel()
        session.stop()
        continuationToResume?.resume(returning: result)
    }
}

private enum CameraFaceDetectionCaptureError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
}

private extension AVAuthorizationStatus {
    var cameraFaceDetectionStatus: CameraFaceDetectionPermissionStatus {
        switch self {
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
}
