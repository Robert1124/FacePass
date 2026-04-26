import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

public protocol FaceSampleCaptureFaceDetecting {
    func detectFaceBounds(in frame: CameraFaceDetectionFrame) async throws -> [CGRect]
}

public protocol FaceSampleCaptureImageConverting {
    func makeCGImage(from frame: CameraFaceDetectionFrame) throws -> CGImage
}

public enum FaceSampleCaptureMode: Equatable, Sendable {
    case enrollment
    case recognition
}

public final class FaceSampleCaptureService {
    private let permissionProvider: any CameraFaceDetectionPermissionProviding
    private let session: any CameraFaceDetectionSession
    private let faceDetector: any FaceSampleCaptureFaceDetecting
    private let imageConverter: any FaceSampleCaptureImageConverting
    private let timeoutScheduler: any CameraFaceDetectionTimeoutScheduling
    private let sessionStartQueue = DispatchQueue(label: "com.facepass.face-sample-capture.session-start")

    public init(
        permissionProvider: any CameraFaceDetectionPermissionProviding = SystemCameraFaceDetectionPermissionProvider(),
        session: any CameraFaceDetectionSession = AVCaptureCameraFaceDetectionSession(),
        faceDetector: any FaceSampleCaptureFaceDetecting = VisionFaceSampleCaptureFaceDetector(),
        imageConverter: any FaceSampleCaptureImageConverting = SampleBufferFaceSampleImageConverter(),
        timeoutScheduler: any CameraFaceDetectionTimeoutScheduling = TaskCameraFaceDetectionTimeoutScheduler()
    ) {
        self.permissionProvider = permissionProvider
        self.session = session
        self.faceDetector = faceDetector
        self.imageConverter = imageConverter
        self.timeoutScheduler = timeoutScheduler
    }

    public func captureSample(timeout: TimeInterval) async -> FaceSampleCaptureResult {
        await captureSample(timeout: timeout, mode: .enrollment)
    }

    public func captureSample(
        timeout: TimeInterval,
        mode: FaceSampleCaptureMode
    ) async -> FaceSampleCaptureResult {
        let permissionStatus = await resolvedCameraPermissionStatus()
        guard permissionStatus == .authorized else {
            return .permissionDenied
        }

        if Task.isCancelled {
            return .cancelled
        }

        let runState = FaceSampleCaptureRunState(session: session)
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

                let session = FaceSampleCaptureUncheckedSendable(self.session)
                let faceDetector = FaceSampleCaptureUncheckedSendable(self.faceDetector)
                let imageConverter = FaceSampleCaptureUncheckedSendable(self.imageConverter)
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
                                    let bounds = try await faceDetector.value.detectFaceBounds(in: frame)
                                    if bounds.isEmpty {
                                        runState.completeProcessingFrame()
                                        return
                                    }

                                    if mode == .enrollment, bounds.count != 1 {
                                        runState.finish(.multipleFaces)
                                        return
                                    }

                                    guard bounds.allSatisfy(\.isValidVisionNormalizedFaceBounds) else {
                                        runState.finish(.failed(.invalidFaceBounds))
                                        return
                                    }

                                    let image = try imageConverter.value.makeCGImage(from: frame)
                                    let samples = bounds.map { bounds in
                                        FaceEnrollmentSample(
                                            image: image,
                                            visionNormalizedFaceBounds: bounds
                                        )
                                    }
                                    runState.finish(.captured(FaceSampleCaptureSummary(
                                        samples: samples,
                                        processedFrameCount: processedFrameCount
                                    )))
                                } catch let error as FaceSampleCaptureImageConversionError {
                                    runState.finish(.noUsableSample(error))
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

public struct FaceSampleCaptureSummary {
    public let samples: [FaceEnrollmentSample]
    public let processedFrameCount: Int

    public var sample: FaceEnrollmentSample {
        samples[0]
    }

    public init(sample: FaceEnrollmentSample, processedFrameCount: Int) {
        self.init(samples: [sample], processedFrameCount: processedFrameCount)
    }

    public init(samples: [FaceEnrollmentSample], processedFrameCount: Int) {
        precondition(!samples.isEmpty, "FaceSampleCaptureSummary requires at least one sample.")
        self.samples = samples
        self.processedFrameCount = max(0, processedFrameCount)
    }
}

public enum FaceSampleCaptureResult {
    case captured(FaceSampleCaptureSummary)
    case permissionDenied
    case timedOut
    case cancelled
    case noFace
    case multipleFaces
    case noUsableSample(FaceSampleCaptureImageConversionError)
    case failed(FaceSampleCaptureFailureReason)
}

public enum FaceSampleCaptureFailureReason: Equatable {
    case sessionStartFailed
    case captureFailed
    case faceDetectionFailed
    case invalidFaceBounds
}

public enum FaceSampleCaptureImageConversionError: Error, Equatable {
    case missingSampleBuffer
    case missingPixelBuffer
    case cgImageCreationFailed
}

public struct VisionFaceSampleCaptureFaceDetector: FaceSampleCaptureFaceDetecting {
    public init() {}

    public func detectFaceBounds(in frame: CameraFaceDetectionFrame) async throws -> [CGRect] {
        guard let sampleBuffer = frame.sampleBuffer else {
            return []
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])
        return request.results?.map(\.boundingBox) ?? []
    }
}

public final class SampleBufferFaceSampleImageConverter: FaceSampleCaptureImageConverting {
    private let context: CIContext

    public init(context: CIContext = CIContext(options: nil)) {
        self.context = context
    }

    public func makeCGImage(from frame: CameraFaceDetectionFrame) throws -> CGImage {
        guard frame.sampleBuffer != nil else {
            throw FaceSampleCaptureImageConversionError.missingSampleBuffer
        }

        guard let pixelBuffer = frame.pixelBuffer else {
            throw FaceSampleCaptureImageConversionError.missingPixelBuffer
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw FaceSampleCaptureImageConversionError.cgImageCreationFailed
        }

        return cgImage
    }
}

private struct FaceSampleCaptureUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class FaceSampleCaptureRunState: @unchecked Sendable {
    private let session: any CameraFaceDetectionSession
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FaceSampleCaptureResult, Never>?
    private var completedResult: FaceSampleCaptureResult?
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

    func setContinuation(_ continuation: CheckedContinuation<FaceSampleCaptureResult, Never>) {
        var resultToResume: FaceSampleCaptureResult?
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

    func completeProcessingFrame() {
        lock.lock()
        isProcessingFrame = false
        lock.unlock()
    }

    func finish(_ result: FaceSampleCaptureResult) {
        var continuationToResume: CheckedContinuation<FaceSampleCaptureResult, Never>?
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

private extension CameraFaceDetectionFrame {
    var pixelBuffer: CVPixelBuffer? {
        guard let sampleBuffer else {
            return nil
        }

        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}

private extension CGRect {
    var isValidVisionNormalizedFaceBounds: Bool {
        minX.isFinite &&
            minY.isFinite &&
            width.isFinite &&
            height.isFinite &&
            width > 0 &&
            height > 0 &&
            minX >= 0 &&
            minY >= 0 &&
            maxX <= 1 &&
            maxY <= 1
    }
}
