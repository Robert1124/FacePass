import CryptoKit
import Foundation

public protocol FaceRecognitionSampleCapturing {
    func captureSample(timeout: TimeInterval) async -> FaceSampleCaptureResult
}

public protocol FaceRecognitionModeSampleCapturing: FaceRecognitionSampleCapturing {
    func captureSample(
        timeout: TimeInterval,
        mode: FaceSampleCaptureMode
    ) async -> FaceSampleCaptureResult
}

public extension FaceRecognitionSampleCapturing {
    func captureSample(
        timeout: TimeInterval,
        mode: FaceSampleCaptureMode
    ) async -> FaceSampleCaptureResult {
        if let modeCapturing = self as? any FaceRecognitionModeSampleCapturing {
            return await modeCapturing.captureSample(timeout: timeout, mode: mode)
        }

        return await captureSample(timeout: timeout)
    }
}

extension FaceSampleCaptureService: FaceRecognitionModeSampleCapturing {}

public protocol FaceRecognitionRuntimeWorkflow {
    var modelVersion: String { get }
    var dimension: Int { get }

    func enroll(
        samples: [FaceEnrollmentSample],
        metadata: FaceEnrollmentMetadata
    ) async throws -> FaceTemplateRecord

    func observe(sample: FaceEnrollmentSample) async throws -> FaceRecognitionObservation
    func observe(samples: [FaceEnrollmentSample]) async throws -> FaceRecognitionObservation
}

public extension FaceRecognitionRuntimeWorkflow {
    func observe(samples: [FaceEnrollmentSample]) async throws -> FaceRecognitionObservation {
        guard !samples.isEmpty else {
            throw FaceRecognitionObserveServiceError.emptyCandidateSamples
        }

        var bestObservation: FaceRecognitionObservation?
        var firstError: Error?

        for sample in samples {
            do {
                let observation = try await observe(sample: sample)
                if bestObservation == nil || observation.bestSimilarity > bestObservation!.bestSimilarity {
                    bestObservation = observation
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let bestObservation {
            return bestObservation
        }

        throw firstError ?? FaceRecognitionObserveServiceError.emptyCandidateSamples
    }
}

public protocol FaceRecognitionRuntimeWorkflowMaking {
    func makeWorkflow(modelURL: URL) throws -> any FaceRecognitionRuntimeWorkflow
}

public protocol FaceRecognitionModelFileHashing {
    func sha256HexDigest(forFileAt url: URL) throws -> String
}

public protocol FaceRecognitionBundledModelURLProviding {
    func bundledModelURL() -> URL?
}

public final class FaceRecognitionRuntimeController {
    public static let modelPathDefaultsKey = "FacePass.recognitionPrototype.modelPath"
    public static let unlockMinimumSimilarityDefaultsKey = "FacePass.recognitionPrototype.unlockMinimumSimilarity"
    public static let defaultCaptureTimeout: TimeInterval = 1
    public static let defaultUnlockCaptureTimeout: TimeInterval = 10
    public static let defaultUnlockMinimumSimilarity: Float = 0.35
    public static let minimumAllowedUnlockSimilarity: Float = 0.20
    public static let maximumAllowedUnlockSimilarity: Float = 0.75
    private static let defaultUnlockRequiredAcceptedMatches = 2
    private static let defaultUnlockMaximumUsableFrames = 3
    private static let defaultUnlockFollowUpCaptureTimeout: TimeInterval = defaultCaptureTimeout
    public static var defaultMaximumEnrollmentSampleCount: Int {
        FaceEnrollmentService<CoreMLFaceEmbeddingProvider>.defaultMinimumSampleCount
    }

    public private(set) var state: FaceRecognitionRuntimeState

    private let sampleCaptureService: any FaceRecognitionSampleCapturing
    private let workflowFactory: any FaceRecognitionRuntimeWorkflowMaking
    private let fileHasher: any FaceRecognitionModelFileHashing
    private let bundledModelURLProvider: any FaceRecognitionBundledModelURLProviding
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let savedTemplateStateProvider: () -> Bool
    private let captureTimeout: TimeInterval
    private let currentTimeProvider: () -> TimeInterval
    private let minimumEnrollmentSampleCount: Int
    private let maximumEnrollmentSampleCount: Int
    // In-process hook for tests and local development only. Normal app runtime uses the bundled model.
    private var developmentModelURLOverride: URL?
    private var capturedEnrollmentSamples: [FaceEnrollmentSample] = []
    private var isEnrollmentCaptureInFlight = false
    private var isEnrollmentSaveInFlight = false
    private var isObserveInFlight = false

    public init(
        sampleCaptureService: any FaceRecognitionSampleCapturing = FaceSampleCaptureService(),
        workflowFactory: any FaceRecognitionRuntimeWorkflowMaking = CoreMLFaceRecognitionRuntimeWorkflowFactory(),
        fileHasher: any FaceRecognitionModelFileHashing = SHA256ModelFileHasher(),
        bundledModelURLProvider: any FaceRecognitionBundledModelURLProviding = MainBundleAuraFaceModelURLProvider(),
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        savedTemplateStateProvider: (() -> Bool)? = nil,
        developmentModelURLOverride: URL? = nil,
        captureTimeout: TimeInterval = FaceRecognitionRuntimeController.defaultCaptureTimeout,
        minimumEnrollmentSampleCount: Int = FaceEnrollmentService<CoreMLFaceEmbeddingProvider>.defaultMinimumSampleCount,
        maximumEnrollmentSampleCount: Int = FaceRecognitionRuntimeController.defaultMaximumEnrollmentSampleCount,
        currentTimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sampleCaptureService = sampleCaptureService
        self.workflowFactory = workflowFactory
        self.fileHasher = fileHasher
        self.bundledModelURLProvider = bundledModelURLProvider
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        let resolvedSavedTemplateStateProvider = savedTemplateStateProvider ?? {
            guard let store = try? FaceTemplateStore(fileManager: fileManager) else {
                return false
            }

            return fileManager.fileExists(atPath: store.encryptedFileURL.path)
        }
        self.savedTemplateStateProvider = resolvedSavedTemplateStateProvider
        self.captureTimeout = max(0, captureTimeout)
        self.currentTimeProvider = currentTimeProvider
        self.minimumEnrollmentSampleCount = max(1, minimumEnrollmentSampleCount)
        self.maximumEnrollmentSampleCount = max(self.minimumEnrollmentSampleCount, maximumEnrollmentSampleCount)
        self.developmentModelURLOverride = developmentModelURLOverride
        self.userDefaults.removeObject(forKey: Self.modelPathDefaultsKey)
        self.state = FaceRecognitionRuntimeState(
            modelPath: developmentModelURLOverride?.path ?? "",
            capturedEnrollmentSampleCount: 0,
            requiredEnrollmentSampleCount: max(1, minimumEnrollmentSampleCount),
            hasSavedEnrollmentTemplate: resolvedSavedTemplateStateProvider(),
            unlockMinimumSimilarity: Self.sanitizedUnlockMinimumSimilarity(
                userDefaults.object(forKey: Self.unlockMinimumSimilarityDefaultsKey).map { _ in
                    Float(userDefaults.double(forKey: Self.unlockMinimumSimilarityDefaultsKey))
                } ?? Self.defaultUnlockMinimumSimilarity
            ),
            lastModelChecksumSHA256: nil,
            status: .idle
        )
    }

    public func refreshStoredTemplateState() {
        state.hasSavedEnrollmentTemplate = savedTemplateStateProvider()
    }

    public func setModelPath(_ path: String) {
        setDevelopmentModelPathOverride(path)
    }

    /// Sets a non-persisted model override for tests and local development.
    public func setDevelopmentModelPathOverride(_ path: String) {
        let sanitizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitizedPath != state.modelPath {
            clearCapturedEnrollmentSamplesForPrivacy()
        }
        state.modelPath = sanitizedPath
        state.lastModelChecksumSHA256 = nil
        developmentModelURLOverride = sanitizedPath.isEmpty ? nil : URL(fileURLWithPath: sanitizedPath)
        userDefaults.removeObject(forKey: Self.modelPathDefaultsKey)

        if sanitizedPath.isEmpty {
            state.status = .idle
        } else {
            state.status = .modelPathUpdated
        }
    }

    public func setRecognitionModelPath(_ path: String) {
        setDevelopmentModelPathOverride(path)
    }

    public func clearCapturedEnrollmentSamples() {
        clearCapturedEnrollmentSamplesForPrivacy()
        state.status = .enrollmentSamplesCleared
    }

    public func clearEnrollment() {
        clearCapturedEnrollmentSamplesForPrivacy()
        do {
            try FaceTemplateStore(fileManager: fileManager).delete()
            state.lastModelChecksumSHA256 = nil
            state.hasSavedEnrollmentTemplate = false
            state.status = .enrollmentSamplesCleared
        } catch {
            refreshStoredTemplateState()
            state.status = .enrollmentSaveFailed(reason: .unknown)
        }
    }

    public func setUnlockMinimumSimilarity(_ minimumSimilarity: Float) {
        let sanitized = Self.sanitizedUnlockMinimumSimilarity(minimumSimilarity)
        state.unlockMinimumSimilarity = sanitized
        userDefaults.set(Double(sanitized), forKey: Self.unlockMinimumSimilarityDefaultsKey)
    }

    public func captureEnrollmentSample() async {
        guard !isEnrollmentCaptureInFlight, !isEnrollmentSaveInFlight, !isObserveInFlight else {
            state.status = .busy
            return
        }

        guard modelURLIfAvailable() != nil else {
            state.status = .missingModelPath
            return
        }

        isEnrollmentCaptureInFlight = true
        state.status = .capturingEnrollmentSample
        defer {
            isEnrollmentCaptureInFlight = false
        }

        switch await sampleCaptureService.captureSample(timeout: captureTimeout, mode: .enrollment) {
        case let .captured(summary):
            capturedEnrollmentSamples.append(summary.sample)
            if capturedEnrollmentSamples.count > maximumEnrollmentSampleCount {
                capturedEnrollmentSamples.removeFirst(
                    capturedEnrollmentSamples.count - maximumEnrollmentSampleCount
                )
            }
            state.capturedEnrollmentSampleCount = capturedEnrollmentSamples.count
            if capturedEnrollmentSamples.count >= minimumEnrollmentSampleCount {
                isEnrollmentCaptureInFlight = false
                await saveEnrollment()
            } else {
                state.status = .enrollmentSampleCaptured(
                    captured: capturedEnrollmentSamples.count,
                    required: minimumEnrollmentSampleCount
                )
            }
        case .permissionDenied:
            state.status = .cameraPermissionDenied
        case .timedOut:
            state.status = .cameraTimedOut
        case .cancelled:
            state.status = .cameraCancelled
        case .noFace:
            state.status = .noFaceFound
        case .multipleFaces:
            state.status = .multipleFacesFound
        case .noUsableSample:
            state.status = .sampleUnavailable
        case .failed:
            state.status = .cameraFailed
        }
    }

    public func saveEnrollment() async {
        guard !isEnrollmentCaptureInFlight, !isEnrollmentSaveInFlight, !isObserveInFlight else {
            state.status = .busy
            return
        }

        guard capturedEnrollmentSamples.count >= minimumEnrollmentSampleCount else {
            state.status = .tooFewEnrollmentSamples(
                captured: capturedEnrollmentSamples.count,
                required: minimumEnrollmentSampleCount
            )
            return
        }

        guard let modelURL = modelURLIfAvailable() else {
            clearCapturedEnrollmentSamplesForPrivacy()
            state.status = .missingModelPath
            return
        }

        let checksum: String
        do {
            checksum = try fileHasher.sha256HexDigest(forFileAt: modelURL)
        } catch {
            clearCapturedEnrollmentSamplesForPrivacy()
            state.status = .modelChecksumFailed
            return
        }

        let workflow: any FaceRecognitionRuntimeWorkflow
        do {
            workflow = try workflowFactory.makeWorkflow(modelURL: modelURL)
        } catch {
            clearCapturedEnrollmentSamplesForPrivacy()
            state.status = .modelLoadFailed
            return
        }

        isEnrollmentSaveInFlight = true
        state.status = .savingEnrollment
        defer {
            isEnrollmentSaveInFlight = false
        }

        do {
            let record = try await workflow.enroll(
                samples: capturedEnrollmentSamples,
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: checksum)
            )
            clearCapturedEnrollmentSamplesForPrivacy()
            state.lastModelChecksumSHA256 = checksum
            state.hasSavedEnrollmentTemplate = true
            state.status = .enrollmentSaved(
                sampleCount: record.embeddings.count,
                modelVersion: record.modelVersion
            )
        } catch let error as FaceEnrollmentServiceError {
            clearCapturedEnrollmentSamplesForPrivacy()
            state.status = .enrollmentSaveFailed(reason: .serviceError(error))
        } catch {
            clearCapturedEnrollmentSamplesForPrivacy()
            state.status = .enrollmentSaveFailed(reason: .unknown)
        }
    }

    public func observeOnce() async {
        guard !isEnrollmentCaptureInFlight, !isEnrollmentSaveInFlight, !isObserveInFlight else {
            state.status = .busy
            return
        }

        guard let modelURL = modelURLIfAvailable() else {
            state.status = .missingModelPath
            return
        }

        let workflow: any FaceRecognitionRuntimeWorkflow
        do {
            workflow = try workflowFactory.makeWorkflow(modelURL: modelURL)
        } catch {
            state.status = .modelLoadFailed
            return
        }

        isObserveInFlight = true
        state.status = .capturingObserveSample
        defer {
            isObserveInFlight = false
        }

        let samples: [FaceEnrollmentSample]
        switch await sampleCaptureService.captureSample(timeout: captureTimeout, mode: .recognition) {
        case let .captured(summary):
            samples = summary.samples
        case .permissionDenied:
            state.status = .cameraPermissionDenied
            return
        case .timedOut:
            state.status = .cameraTimedOut
            return
        case .cancelled:
            state.status = .cameraCancelled
            return
        case .noFace:
            state.status = .noFaceFound
            return
        case .multipleFaces:
            state.status = .multipleFacesFound
            return
        case .noUsableSample:
            state.status = .sampleUnavailable
            return
        case .failed:
            state.status = .cameraFailed
            return
        }

        do {
            let observation = try await workflow.observe(samples: samples)
            state.status = .observeSucceeded(
                similarity: observation.bestSimilarity,
                templateCount: observation.comparedTemplateCount,
                modelVersion: observation.modelVersion
            )
        } catch FaceRecognitionRuntimeWorkflowError.noTemplate {
            state.status = .missingTemplate
        } catch {
            state.status = .observeFailed
        }
    }

    public func evaluateUnlockRecognition(
        timeout: TimeInterval = FaceRecognitionRuntimeController.defaultUnlockCaptureTimeout
    ) async -> FaceRecognitionUnlockGateResult {
        guard !isEnrollmentCaptureInFlight, !isEnrollmentSaveInFlight, !isObserveInFlight else {
            state.status = .busy
            return .rejected(.busy)
        }

        guard let modelURL = modelURLIfAvailable() else {
            state.status = .missingModelPath
            return .rejected(.missingModel)
        }

        let workflow: any FaceRecognitionRuntimeWorkflow
        do {
            workflow = try workflowFactory.makeWorkflow(modelURL: modelURL)
        } catch {
            state.status = .modelLoadFailed
            return .rejected(.modelLoadFailed)
        }

        isObserveInFlight = true
        state.status = .capturingObserveSample
        defer {
            isObserveInFlight = false
        }

        let policy = FaceRecognitionPolicy(
            threshold: FaceRecognitionThreshold(
                minimumSimilarity: state.unlockMinimumSimilarity,
                modelVersion: workflow.modelVersion
            ),
            requiredAcceptedMatches: Self.defaultUnlockRequiredAcceptedMatches,
            maximumUsableFrames: Self.defaultUnlockMaximumUsableFrames
        )
        let unlockCaptureTimeout = max(0, timeout)
        let unlockCaptureDeadline = currentTimeProvider() + unlockCaptureTimeout
        var hasRequestedUnlockCapture = false
        var acceptedMatchCount = 0
        var frames: [FaceRecognitionFrame] = []
        var bestObservation: FaceRecognitionObservation?

        for _ in 0..<policy.maximumUsableFrames {
            let remainingCaptureTimeout = nextUnlockCaptureTimeout(
                initialTimeout: unlockCaptureTimeout,
                deadline: unlockCaptureDeadline,
                hasRequestedCapture: hasRequestedUnlockCapture,
                acceptedMatchCount: acceptedMatchCount,
                requiredAcceptedMatches: policy.requiredAcceptedMatches
            )

            guard remainingCaptureTimeout > 0 else {
                if frames.isEmpty {
                    state.status = .cameraTimedOut
                    return .rejected(.timedOut)
                }
                return rejectUnlockRecognition(policy.evaluate(frames))
            }

            let samples: [FaceEnrollmentSample]
            hasRequestedUnlockCapture = true
            switch await sampleCaptureService.captureSample(timeout: remainingCaptureTimeout, mode: .recognition) {
            case let .captured(summary):
                samples = summary.samples
            case .permissionDenied:
                state.status = .cameraPermissionDenied
                return .rejected(.cameraPermissionDenied)
            case .timedOut:
                if frames.isEmpty {
                    state.status = .cameraTimedOut
                    return .rejected(.timedOut)
                }
                return rejectUnlockRecognition(policy.evaluate(frames))
            case .cancelled:
                if frames.isEmpty {
                    state.status = .cameraCancelled
                    return .rejected(.cancelled)
                }
                return rejectUnlockRecognition(policy.evaluate(frames))
            case .noFace:
                state.status = .noFaceFound
                return .rejected(.noFace)
            case .multipleFaces:
                state.status = .multipleFacesFound
                return .rejected(.multipleFaces)
            case .noUsableSample:
                state.status = .sampleUnavailable
                return .rejected(.sampleUnavailable)
            case .failed:
                state.status = .cameraFailed
                return .rejected(.cameraFailed)
            }

            let observation: FaceRecognitionObservation
            do {
                observation = try await workflow.observe(samples: samples)
            } catch FaceRecognitionRuntimeWorkflowError.noTemplate {
                state.status = .missingTemplate
                return .rejected(.missingTemplate)
            } catch FaceRecognitionObserveServiceError.modelVersionMismatch {
                state.status = .observeFailed
                return .rejected(.staleModel)
            } catch {
                state.status = .observeFailed
                return .rejected(.observeFailed)
            }

            frames.append(observation.frame)
            if isAcceptedUnlockFrame(observation.frame, threshold: policy.threshold) {
                acceptedMatchCount += 1
            }
            if bestObservation == nil || observation.bestSimilarity > bestObservation!.bestSimilarity {
                bestObservation = observation
            }

            switch policy.evaluate(frames) {
            case .accepted:
                let statusObservation = bestObservation ?? observation
                state.status = .observeSucceeded(
                    similarity: statusObservation.bestSimilarity,
                    templateCount: statusObservation.comparedTemplateCount,
                    modelVersion: statusObservation.modelVersion
                )
                return .accepted
            case .observeOnly:
                state.status = .observeFailed
                return .rejected(.observeFailed)
            case let .rejected(reason):
                if shouldStopUnlockRecognition(for: reason, collectedFrameCount: frames.count, policy: policy) {
                    return rejectUnlockRecognition(.rejected(reason))
                }
            }
        }

        return rejectUnlockRecognition(policy.evaluate(frames))
    }

    private func nextUnlockCaptureTimeout(
        initialTimeout: TimeInterval,
        deadline: TimeInterval,
        hasRequestedCapture: Bool,
        acceptedMatchCount: Int,
        requiredAcceptedMatches: Int
    ) -> TimeInterval {
        guard hasRequestedCapture else {
            return initialTimeout
        }

        guard initialTimeout.isFinite else {
            return initialTimeout
        }

        let remainingInitialSearchTimeout = max(0, deadline - currentTimeProvider())
        if remainingInitialSearchTimeout > 0 {
            return remainingInitialSearchTimeout
        }

        guard acceptedMatchCount > 0, acceptedMatchCount < requiredAcceptedMatches else {
            return 0
        }

        return Self.defaultUnlockFollowUpCaptureTimeout
    }

    private func isAcceptedUnlockFrame(
        _ frame: FaceRecognitionFrame,
        threshold: FaceRecognitionThreshold?
    ) -> Bool {
        guard let threshold, case let .usable(score) = frame else {
            return false
        }

        return score.modelVersion == threshold.modelVersion
            && score.similarity.isFinite
            && score.similarity >= -1
            && score.similarity <= 1
            && score.similarity >= threshold.minimumSimilarity
    }

    private func shouldStopUnlockRecognition(
        for reason: FaceRecognitionRejectionReason,
        collectedFrameCount: Int,
        policy: FaceRecognitionPolicy
    ) -> Bool {
        switch reason {
        case .tooFewUsableFrames, .fewerThanRequiredMatches:
            return collectedFrameCount >= policy.maximumUsableFrames
        case .thresholdUnset,
             .invalidConfiguration,
             .invalidScore,
             .noFace,
             .multipleFaces,
             .badQuality,
             .modelError,
             .staleModelVersion,
             .inconsistentMatches:
            return true
        }
    }

    private func rejectUnlockRecognition(
        _ decision: FaceRecognitionDecision
    ) -> FaceRecognitionUnlockGateResult {
        switch decision {
        case .accepted:
            return .accepted
        case .observeOnly:
            state.status = .observeFailed
            return .rejected(.observeFailed)
        case let .rejected(reason):
            state.status = .observeFailed
            return .rejected(FaceRecognitionUnlockGateRejectionReason(policyReason: reason))
        }
    }

    private func modelURLIfAvailable() -> URL? {
        if let developmentModelURLOverride {
            guard fileManager.fileExists(atPath: developmentModelURLOverride.path) else {
                return nil
            }

            return developmentModelURLOverride
        }

        guard let bundledURL = bundledModelURLProvider.bundledModelURL(),
              fileManager.fileExists(atPath: bundledURL.path) else {
            return nil
        }

        return bundledURL
    }

    private func clearCapturedEnrollmentSamplesForPrivacy() {
        capturedEnrollmentSamples.removeAll()
        state.capturedEnrollmentSampleCount = 0
    }

    private static func sanitizedUnlockMinimumSimilarity(_ value: Float) -> Float {
        guard value.isFinite else {
            return defaultUnlockMinimumSimilarity
        }

        return min(max(value, minimumAllowedUnlockSimilarity), maximumAllowedUnlockSimilarity)
    }
}

public struct MainBundleAuraFaceModelURLProvider: FaceRecognitionBundledModelURLProviding {
    public init() {}

    public func bundledModelURL() -> URL? {
        Bundle.main.url(
            forResource: "glintr100-legacy",
            withExtension: "mlmodelc",
            subdirectory: "Models/AuraFace-v1/af6d057c9b0ec4071d4c49c80e3539258798b609"
        )
    }
}

public enum FaceRecognitionUnlockGateResult: Equatable, CustomStringConvertible {
    case accepted
    case rejected(FaceRecognitionUnlockGateRejectionReason)

    public var isAccepted: Bool {
        self == .accepted
    }

    public var description: String {
        switch self {
        case .accepted:
            return "Face recognition accepted the short lock-screen gate."
        case let .rejected(reason):
            return reason.description
        }
    }
}

public enum FaceRecognitionUnlockGateRejectionReason: Equatable, CustomStringConvertible {
    case busy
    case missingModel
    case missingTemplate
    case cameraPermissionDenied
    case timedOut
    case cancelled
    case noFace
    case multipleFaces
    case sampleUnavailable
    case cameraFailed
    case modelLoadFailed
    case observeFailed
    case staleModel
    case invalidScore
    case rejected

    init(policyReason: FaceRecognitionRejectionReason) {
        switch policyReason {
        case .invalidScore:
            self = .invalidScore
        case .staleModelVersion:
            self = .staleModel
        case .noFace:
            self = .noFace
        case .multipleFaces:
            self = .multipleFaces
        case .modelError:
            self = .observeFailed
        default:
            self = .rejected
        }
    }

    public var description: String {
        switch self {
        case .busy:
            return "Recognition is already running."
        case .missingModel:
            return "Recognition model is unavailable."
        case .missingTemplate:
            return "Recognition template is unavailable."
        case .cameraPermissionDenied:
            return "Camera permission is required for recognition."
        case .timedOut:
            return "Recognition timed out before a usable sample was captured."
        case .cancelled:
            return "Recognition was cancelled."
        case .noFace:
            return "Recognition found no face."
        case .multipleFaces:
            return "Recognition found more than one face."
        case .sampleUnavailable:
            return "Recognition could not create a usable in-memory sample."
        case .cameraFailed:
            return "Recognition camera capture failed."
        case .modelLoadFailed:
            return "Recognition model could not be loaded."
        case .observeFailed:
            return "Recognition observation failed."
        case .staleModel:
            return "Recognition template does not match the active model."
        case .invalidScore:
            return "Recognition produced an invalid score."
        case .rejected:
            return "Recognition did not meet the local unlock threshold."
        }
    }
}

public struct FaceRecognitionRuntimeState: Equatable {
    public var modelPath: String
    public var capturedEnrollmentSampleCount: Int
    public let requiredEnrollmentSampleCount: Int
    public var hasSavedEnrollmentTemplate: Bool
    public var unlockMinimumSimilarity: Float
    public var lastModelChecksumSHA256: String?
    public var status: FaceRecognitionRuntimeStatus

    public init(
        modelPath: String,
        capturedEnrollmentSampleCount: Int,
        requiredEnrollmentSampleCount: Int,
        hasSavedEnrollmentTemplate: Bool = false,
        unlockMinimumSimilarity: Float = FaceRecognitionRuntimeController.defaultUnlockMinimumSimilarity,
        lastModelChecksumSHA256: String?,
        status: FaceRecognitionRuntimeStatus
    ) {
        self.modelPath = modelPath
        self.capturedEnrollmentSampleCount = max(0, capturedEnrollmentSampleCount)
        self.requiredEnrollmentSampleCount = max(1, requiredEnrollmentSampleCount)
        self.hasSavedEnrollmentTemplate = hasSavedEnrollmentTemplate
        self.unlockMinimumSimilarity = unlockMinimumSimilarity
        self.lastModelChecksumSHA256 = lastModelChecksumSHA256
        self.status = status
    }

    public var canSaveEnrollment: Bool {
        capturedEnrollmentSampleCount >= requiredEnrollmentSampleCount
    }

    public var isBusy: Bool {
        switch status {
        case .capturingEnrollmentSample, .savingEnrollment, .capturingObserveSample:
            return true
        default:
            return false
        }
    }
}

public enum FaceRecognitionRuntimeStatus: Equatable, CustomStringConvertible {
    case idle
    case modelPathUpdated
    case missingModelPath
    case busy
    case capturingEnrollmentSample
    case enrollmentSampleCaptured(captured: Int, required: Int)
    case tooFewEnrollmentSamples(captured: Int, required: Int)
    case savingEnrollment
    case enrollmentSaved(sampleCount: Int, modelVersion: String)
    case enrollmentSamplesCleared
    case enrollmentSaveFailed(reason: FaceRecognitionEnrollmentSaveFailureReason)
    case capturingObserveSample
    case observeSucceeded(similarity: Float, templateCount: Int, modelVersion: String)
    case missingTemplate
    case observeFailed
    case cameraPermissionDenied
    case cameraTimedOut
    case cameraCancelled
    case noFaceFound
    case multipleFacesFound
    case sampleUnavailable
    case cameraFailed
    case modelLoadFailed
    case modelChecksumFailed

    public var description: String {
        switch self {
        case .idle:
            return "Recognition runtime is idle. Settings actions stay local; the opt-in wake-triggered lock-screen path may use the local recognition gate. Ordinary autofill remains value-only and does not submit."
        case .modelPathUpdated:
            return "Development recognition model override is set for this app run."
        case .missingModelPath:
            return "Bundled local recognition model is unavailable."
        case .busy:
            return "Recognition prototype is already running a short explicit action."
        case .capturingEnrollmentSample:
            return "Capturing one short enrollment sample..."
        case let .enrollmentSampleCaptured(captured, required):
            return "Captured enrollment sample \(captured) of \(required). Save is available after the required samples are captured."
        case let .tooFewEnrollmentSamples(captured, required):
            return "Capture at least \(required) enrollment samples before saving. Current samples: \(captured)."
        case .savingEnrollment:
            return "Saving encrypted local enrollment template..."
        case let .enrollmentSaved(sampleCount, modelVersion):
            return "Enrollment saved locally with \(sampleCount) embeddings for model \(modelVersion)."
        case .enrollmentSamplesCleared:
            return "In-memory enrollment samples cleared."
        case let .enrollmentSaveFailed(reason):
            return reason.description
        case .capturingObserveSample:
            return "Capturing a short observe-only recognition sample..."
        case let .observeSucceeded(similarity, templateCount, modelVersion):
            return "Settings similarity \(Self.format(similarity)) against \(templateCount) encrypted local templates for model \(modelVersion). Settings actions stay local; wake-triggered lock-screen may use this local recognition gate, while ordinary autofill remains value-only and does not submit."
        case .missingTemplate:
            return "No encrypted local enrollment template is available."
        case .observeFailed:
            return "Observe-only recognition could not complete."
        case .cameraPermissionDenied:
            return "Camera permission is required for this explicit short action."
        case .cameraTimedOut:
            return "No usable face sample was captured before timeout."
        case .cameraCancelled:
            return "Camera capture was cancelled."
        case .noFaceFound:
            return "No face was found in the short camera window."
        case .multipleFacesFound:
            return "More than one face was visible, so FacePass stopped this action."
        case .sampleUnavailable:
            return "The camera frame could not be converted into a usable in-memory sample."
        case .cameraFailed:
            return "Camera capture failed."
        case .modelLoadFailed:
            return "The active local recognition model could not be loaded."
        case .modelChecksumFailed:
            return "The active local recognition model checksum could not be computed."
        }
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.4f", Double(value))
    }
}

public enum FaceRecognitionEnrollmentSaveFailureReason: Equatable, CustomStringConvertible {
    case preprocessingFailed
    case embeddingProviderFailed
    case templateStoreValidationFailed
    case unknown

    static func serviceError(_ error: FaceEnrollmentServiceError) -> Self {
        switch error {
        case .preprocessingFailed:
            return .preprocessingFailed
        case .embeddingProviderFailed:
            return .embeddingProviderFailed
        case .templateStoreValidationFailed:
            return .templateStoreValidationFailed
        default:
            return .unknown
        }
    }

    public var description: String {
        switch self {
        case .preprocessingFailed:
            return "Enrollment could not be saved because face preprocessing failed. In-memory samples were cleared; capture new samples and try again."
        case .embeddingProviderFailed:
            return "Enrollment could not be saved because local embedding generation failed. In-memory samples were cleared; check that the bundled model is available and compatible."
        case .templateStoreValidationFailed:
            return "Enrollment could not be saved because the encrypted local template store rejected the record. In-memory samples were cleared."
        case .unknown:
            return "Enrollment could not be saved because an unknown local enrollment error occurred. In-memory samples were cleared."
        }
    }
}

public enum FaceRecognitionRuntimeWorkflowError: Error, Equatable {
    case noTemplate
}

public struct CoreMLFaceRecognitionRuntimeWorkflowFactory: FaceRecognitionRuntimeWorkflowMaking {
    private let templateStoreFactory: () throws -> FaceTemplateStore

    public init(templateStoreFactory: @escaping () throws -> FaceTemplateStore = { try FaceTemplateStore() }) {
        self.templateStoreFactory = templateStoreFactory
    }

    public func makeWorkflow(modelURL: URL) throws -> any FaceRecognitionRuntimeWorkflow {
        try CoreMLFaceRecognitionRuntimeWorkflow(
            modelURL: modelURL,
            templateStore: templateStoreFactory()
        )
    }
}

public final class CoreMLFaceRecognitionRuntimeWorkflow: FaceRecognitionRuntimeWorkflow {
    private let provider: CoreMLFaceEmbeddingProvider
    private let enrollmentService: FaceEnrollmentService<CoreMLFaceEmbeddingProvider>
    private let observeService: FaceRecognitionObserveService<CoreMLFaceEmbeddingProvider>
    private let templateStore: FaceTemplateStore

    public init(modelURL: URL, templateStore: FaceTemplateStore) {
        let provider = CoreMLFaceEmbeddingProvider(modelURL: modelURL)
        let embeddingService = FaceEmbeddingService(provider: provider)
        self.provider = provider
        self.templateStore = templateStore
        self.enrollmentService = FaceEnrollmentService(
            embeddingService: embeddingService,
            templateStore: templateStore
        )
        self.observeService = FaceRecognitionObserveService(embeddingService: embeddingService)
    }

    public var modelVersion: String {
        provider.modelVersion
    }

    public var dimension: Int {
        provider.dimension
    }

    public func enroll(
        samples: [FaceEnrollmentSample],
        metadata: FaceEnrollmentMetadata
    ) async throws -> FaceTemplateRecord {
        try await enrollmentService.enroll(samples: samples, metadata: metadata)
    }

    public func observe(sample: FaceEnrollmentSample) async throws -> FaceRecognitionObservation {
        guard let templateRecord = try templateStore.load() else {
            throw FaceRecognitionRuntimeWorkflowError.noTemplate
        }

        return try await observeService.observe(
            sample: sample,
            templateRecord: templateRecord
        )
    }

    public func observe(samples: [FaceEnrollmentSample]) async throws -> FaceRecognitionObservation {
        guard let templateRecord = try templateStore.load() else {
            throw FaceRecognitionRuntimeWorkflowError.noTemplate
        }

        return try await observeService.observe(
            samples: samples,
            templateRecord: templateRecord
        )
    }
}

public struct SHA256ModelFileHasher: FaceRecognitionModelFileHashing {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func sha256HexDigest(forFileAt url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SHA256ModelFileHasherError.missingFile
        }

        if isDirectory.boolValue {
            return try directoryDigest(for: url)
        }

        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func directoryDigest(for url: URL) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SHA256ModelFileHasherError.missingFile
        }

        let fileURLs = try enumerator.compactMap { item -> URL? in
            guard let fileURL = item as? URL else {
                return nil
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? fileURL : nil
        }.sorted { $0.path < $1.path }

        guard !fileURLs.isEmpty else {
            throw SHA256ModelFileHasherError.missingFile
        }

        var hasher = SHA256()
        for fileURL in fileURLs {
            let relativePath = fileURL.path.replacingOccurrences(
                of: url.path.hasSuffix("/") ? url.path : "\(url.path)/",
                with: ""
            )
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: fileURL))
            hasher.update(data: Data([0]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum SHA256ModelFileHasherError: Error, Equatable {
    case missingFile
}
