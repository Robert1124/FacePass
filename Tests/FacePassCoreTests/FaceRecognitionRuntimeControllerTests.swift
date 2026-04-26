import CoreGraphics
import Foundation
import XCTest
@testable import FacePassCore

final class FaceRecognitionRuntimeControllerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var userDefaultsSuiteName: String!
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceRecognitionRuntimeControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        userDefaultsSuiteName = "FaceRecognitionRuntimeControllerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        if let userDefaults, let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        temporaryDirectory = nil
        userDefaultsSuiteName = nil
        userDefaults = nil
        try super.tearDownWithError()
    }

    func testDefaultCaptureTimeoutKeepsSettingsRecognitionUIToTwoSecondAttempts() {
        XCTAssertEqual(FaceRecognitionRuntimeController.defaultCaptureTimeout, 1)
        XCTAssertEqual(FaceRecognitionRuntimeController.defaultUnlockCaptureTimeout, 1)
    }

    func testMissingModelPathDoesNotStartCameraOrWorkflow() async {
        let capture = QueueRecognitionSampleCapture()
        let factory = RecordingRecognitionWorkflowFactory()
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: factory,
            userDefaults: userDefaults
        )

        await controller.captureEnrollmentSample()
        await controller.observeOnce()

        XCTAssertEqual(controller.state.status, .missingModelPath)
        XCTAssertEqual(capture.requestedTimeouts, [])
        XCTAssertEqual(factory.requestedModelURLs, [])
    }

    func testBundledModelURLIsUsedWhenNoTestModelPathIsSet() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let factory = RecordingRecognitionWorkflowFactory()
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: factory,
            bundledModelURLProvider: FixedBundledModelURLProvider(url: modelURL),
            userDefaults: userDefaults
        )

        await controller.observeOnce()

        XCTAssertEqual(factory.requestedModelURLs, [modelURL])
        XCTAssertEqual(capture.requestedTimeouts, [FaceRecognitionRuntimeController.defaultCaptureTimeout])
    }

    func testStalePersistedModelPathIsIgnoredRemovedAndCannotOverrideBundledModel() async throws {
        let staleModelURL = try makeModelFile(contents: Data("stale-user-default-model".utf8))
        let bundledModelURL = try makeModelFile(contents: Data("bundled-model".utf8))
        userDefaults.set(staleModelURL.path, forKey: FaceRecognitionRuntimeController.modelPathDefaultsKey)
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let factory = RecordingRecognitionWorkflowFactory()
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: factory,
            bundledModelURLProvider: FixedBundledModelURLProvider(url: bundledModelURL),
            userDefaults: userDefaults
        )

        await controller.observeOnce()

        XCTAssertNil(userDefaults.string(forKey: FaceRecognitionRuntimeController.modelPathDefaultsKey))
        XCTAssertEqual(controller.state.modelPath, "")
        XCTAssertEqual(factory.requestedModelURLs, [bundledModelURL])
        XCTAssertEqual(capture.requestedTimeouts, [FaceRecognitionRuntimeController.defaultCaptureTimeout])
    }

    func testDevelopmentModelOverrideIsInMemoryOnlyAndMissingFileFailsClosed() async {
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: QueueRecognitionSampleCapture(),
            workflowFactory: RecordingRecognitionWorkflowFactory(),
            userDefaults: userDefaults
        )
        let missingPath = temporaryDirectory.appendingPathComponent("missing.mlmodel").path

        controller.setDevelopmentModelPathOverride(missingPath)
        await controller.observeOnce()

        XCTAssertNil(userDefaults.string(forKey: FaceRecognitionRuntimeController.modelPathDefaultsKey))
        XCTAssertEqual(controller.state.status, .missingModelPath)
    }

    func testDevelopmentModelOverrideCanExplicitlyDriveInjectedRuntime() async throws {
        let overrideModelURL = try makeModelFile(contents: Data("dev-override-model".utf8))
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let factory = RecordingRecognitionWorkflowFactory()
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: factory,
            bundledModelURLProvider: FixedBundledModelURLProvider(url: nil),
            userDefaults: userDefaults
        )

        controller.setDevelopmentModelPathOverride(overrideModelURL.path)
        await controller.observeOnce()

        XCTAssertNil(userDefaults.string(forKey: FaceRecognitionRuntimeController.modelPathDefaultsKey))
        XCTAssertEqual(controller.state.modelPath, overrideModelURL.path)
        XCTAssertEqual(factory.requestedModelURLs, [overrideModelURL])
        XCTAssertEqual(capture.requestedTimeouts, [FaceRecognitionRuntimeController.defaultCaptureTimeout])
    }

    func testCaptureSamplesRequiresMinimumBeforeSaving() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let factory = RecordingRecognitionWorkflowFactory()
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: factory,
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.saveEnrollment()

        XCTAssertEqual(capture.requestedTimeouts, [
            FaceRecognitionRuntimeController.defaultCaptureTimeout,
            FaceRecognitionRuntimeController.defaultCaptureTimeout
        ])
        XCTAssertEqual(controller.state.capturedEnrollmentSampleCount, 2)
        XCTAssertEqual(controller.state.status, .tooFewEnrollmentSamples(captured: 2, required: 3))
        XCTAssertEqual(factory.requestedModelURLs, [])
    }

    func testEnrollmentSamplesAreBoundedToNewestRequiredSamples() async throws {
        let modelURL = try makeModelFile(contents: Data("local-core-ml-model".utf8))
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(boundsX: 0.1), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(boundsX: 0.2), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(boundsX: 0.3), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(boundsX: 0.4), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow()
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.saveEnrollment()

        XCTAssertEqual(capture.requestedTimeouts, [
            FaceRecognitionRuntimeController.defaultCaptureTimeout,
            FaceRecognitionRuntimeController.defaultCaptureTimeout,
            FaceRecognitionRuntimeController.defaultCaptureTimeout,
            FaceRecognitionRuntimeController.defaultCaptureTimeout
        ])
        XCTAssertEqual(workflow.enrollSampleCounts, [3])
        XCTAssertEqual(workflow.enrollSampleBoundsXValues, [[0.2, 0.3, 0.4]])
        XCTAssertEqual(controller.state.capturedEnrollmentSampleCount, 0)
    }

    func testSuccessfulEnrollmentComputesChecksumWritesThroughWorkflowAndClearsRawSamples() async throws {
        let modelURL = try makeModelFile(contents: Data("local-core-ml-model".utf8))
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow()
        let factory = RecordingRecognitionWorkflowFactory(workflow: workflow)
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: factory,
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.saveEnrollment()

        XCTAssertEqual(workflow.enrollSampleCounts, [3])
        XCTAssertEqual(
            workflow.enrollChecksums,
            ["498f74cade4628eaa1c2f8e96424652b7ed89a19c8e6220532676cc8e13018c1"]
        )
        XCTAssertEqual(controller.state.capturedEnrollmentSampleCount, 0)
        XCTAssertEqual(
            controller.state.status,
            .enrollmentSaved(sampleCount: 3, modelVersion: workflow.modelVersion)
        )
        XCTAssertEqual(controller.state.lastModelChecksumSHA256, workflow.enrollChecksums.first)
    }

    func testEnrollmentServiceFailuresPublishSafeFailureReasonsAndClearSamplesForPrivacy() async throws {
        let cases: [(FaceEnrollmentServiceError, FaceRecognitionEnrollmentSaveFailureReason, String)] = [
            (.preprocessingFailed, .preprocessingFailed, "preprocessing failed"),
            (.embeddingProviderFailed, .embeddingProviderFailed, "embedding generation failed"),
            (.templateStoreValidationFailed, .templateStoreValidationFailed, "template store rejected")
        ]

        for (serviceError, expectedReason, expectedDescriptionFragment) in cases {
            let modelURL = try makeModelFile(contents: Data("local-core-ml-model-\(UUID().uuidString)".utf8))
            let capture = QueueRecognitionSampleCapture(results: [
                .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
                .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
                .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
            ])
            let workflow = RecordingRecognitionWorkflow(enrollError: serviceError)
            let controller = FaceRecognitionRuntimeController(
                sampleCaptureService: capture,
                workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
                userDefaults: userDefaults
            )
            controller.setDevelopmentModelPathOverride(modelURL.path)

            await controller.captureEnrollmentSample()
            await controller.captureEnrollmentSample()
            await controller.captureEnrollmentSample()
            await controller.saveEnrollment()

            XCTAssertEqual(workflow.enrollSampleCounts, [3])
            XCTAssertEqual(
                controller.state.status,
                .enrollmentSaveFailed(reason: expectedReason),
                "Expected \(serviceError) to map to \(expectedReason)."
            )
            XCTAssertTrue(controller.state.status.description.contains(expectedDescriptionFragment))
            XCTAssertTrue(controller.state.status.description.contains("In-memory samples were cleared"))
            XCTAssertEqual(controller.state.capturedEnrollmentSampleCount, 0)
            XCTAssertNil(controller.state.lastModelChecksumSHA256)
        }
    }

    func testUnknownEnrollmentFailurePublishesSafeUnknownReasonAndClearsSamplesForPrivacy() async throws {
        let modelURL = try makeModelFile(contents: Data("local-core-ml-model".utf8))
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(enrollError: RuntimeControllerTestError.enrollmentFailed)
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.captureEnrollmentSample()
        await controller.saveEnrollment()

        XCTAssertEqual(controller.state.status, .enrollmentSaveFailed(reason: .unknown))
        XCTAssertTrue(controller.state.status.description.contains("unknown local enrollment error"))
        XCTAssertTrue(controller.state.status.description.contains("In-memory samples were cleared"))
        XCTAssertEqual(controller.state.capturedEnrollmentSampleCount, 0)
        XCTAssertNil(controller.state.lastModelChecksumSHA256)
    }

    func testObserveWithoutTemplateCapturesShortSampleAndReportsMissingTemplateOnly() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observeError: FaceRecognitionRuntimeWorkflowError.noTemplate)
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.observeOnce()

        XCTAssertEqual(capture.requestedTimeouts, [FaceRecognitionRuntimeController.defaultCaptureTimeout])
        XCTAssertEqual(workflow.observeCallCount, 1)
        XCTAssertEqual(controller.state.status, .missingTemplate)
    }

    func testSuccessfulObservePublishesSimilarityOnlyWithoutDecision() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observation: FaceRecognitionObservation(
            bestSimilarity: 0.8125,
            modelVersion: "runtime-test-model",
            dimension: 3,
            comparedTemplateCount: 3,
            frame: .usable(FaceRecognitionMatchScore(similarity: 0.8125, modelVersion: "runtime-test-model"))
        ))
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.observeOnce()

        XCTAssertEqual(
            controller.state.status,
            .observeSucceeded(similarity: 0.8125, templateCount: 3, modelVersion: "runtime-test-model")
        )
    }

    func testObserveOnceEvaluatesMultipleCandidatesAndPublishesBestSimilarity() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(samples: [
                try makeSample(boundsX: 0.1),
                try makeSample(boundsX: 0.2)
            ], processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observations: [
            FaceRecognitionObservation(
                bestSimilarity: 0.25,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.25, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.875,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.875, modelVersion: "runtime-test-model"))
            )
        ])
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setDevelopmentModelPathOverride(modelURL.path)

        await controller.observeOnce()

        XCTAssertEqual(capture.requestedModes, [.recognition])
        XCTAssertEqual(workflow.observeSampleBoundsXValues, [0.1, 0.2])
        XCTAssertEqual(
            controller.state.status,
            .observeSucceeded(similarity: 0.875, templateCount: 1, modelVersion: "runtime-test-model")
        )
    }

    func testUnlockRecognitionRejectsSingleLowThresholdMatchWithoutLeakingSensitiveValues() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observation: FaceRecognitionObservation(
            bestSimilarity: 0.5,
            modelVersion: "runtime-test-model",
            dimension: 3,
            comparedTemplateCount: 1,
            frame: .usable(FaceRecognitionMatchScore(similarity: 0.5, modelVersion: "runtime-test-model"))
        ))
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setRecognitionModelPath(modelURL.path)

        let result = await controller.evaluateUnlockRecognition(timeout: 1.25)

        XCTAssertEqual(result, .rejected(.rejected))
        XCTAssertEqual(capture.requestedTimeouts, [1.25, 1.25])
        XCTAssertEqual(capture.requestedModes, [.recognition, .recognition])
        XCTAssertFalse(result.description.contains(modelURL.path))
        XCTAssertFalse(controller.state.status.description.contains(modelURL.path))
    }

    func testUnlockRecognitionAcceptsAfterTwoConsistentMatches() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(boundsX: 0.1), processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(sample: try makeSample(boundsX: 0.2), processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observations: [
            FaceRecognitionObservation(
                bestSimilarity: 0.5,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.5, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.55,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.55, modelVersion: "runtime-test-model"))
            )
        ])
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setRecognitionModelPath(modelURL.path)

        let result = await controller.evaluateUnlockRecognition(timeout: 1.25)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(capture.requestedTimeouts, [1.25, 1.25])
        XCTAssertEqual(capture.requestedModes, [.recognition, .recognition])
        XCTAssertEqual(workflow.observeSampleBoundsXValues, [0.1, 0.2])
    }

    func testUnlockRecognitionAcceptsWhenOneOfMultipleCandidatesMatchesInEachRequiredFrame() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(samples: [
                try makeSample(boundsX: 0.1),
                try makeSample(boundsX: 0.2)
            ], processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(samples: [
                try makeSample(boundsX: 0.3),
                try makeSample(boundsX: 0.4)
            ], processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observations: [
            FaceRecognitionObservation(
                bestSimilarity: 0.2,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.2, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.5,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.5, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.25,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.25, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.55,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.55, modelVersion: "runtime-test-model"))
            )
        ])
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setRecognitionModelPath(modelURL.path)

        let result = await controller.evaluateUnlockRecognition(timeout: 1.25)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(capture.requestedModes, [.recognition, .recognition])
        XCTAssertEqual(workflow.observeSampleBoundsXValues, [0.1, 0.2, 0.3, 0.4])
    }

    func testUnlockRecognitionRejectsWhenNoMultipleFaceCandidateMatches() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(samples: [
                try makeSample(boundsX: 0.1),
                try makeSample(boundsX: 0.2)
            ], processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(samples: [
                try makeSample(boundsX: 0.3),
                try makeSample(boundsX: 0.4)
            ], processedFrameCount: 1)),
            .captured(FaceSampleCaptureSummary(samples: [
                try makeSample(boundsX: 0.5),
                try makeSample(boundsX: 0.6)
            ], processedFrameCount: 1))
        ])
        let workflow = RecordingRecognitionWorkflow(observations: [
            FaceRecognitionObservation(
                bestSimilarity: 0.2,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.2, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.3,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.3, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.2,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.2, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.3,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.3, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.2,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.2, modelVersion: "runtime-test-model"))
            ),
            FaceRecognitionObservation(
                bestSimilarity: 0.3,
                modelVersion: "runtime-test-model",
                dimension: 3,
                comparedTemplateCount: 1,
                frame: .usable(FaceRecognitionMatchScore(similarity: 0.3, modelVersion: "runtime-test-model"))
            )
        ])
        let controller = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
            userDefaults: userDefaults
        )
        controller.setRecognitionModelPath(modelURL.path)

        let result = await controller.evaluateUnlockRecognition(timeout: 1.25)

        XCTAssertEqual(result, .rejected(.rejected))
        XCTAssertEqual(capture.requestedModes, [.recognition, .recognition, .recognition])
        XCTAssertEqual(workflow.observeSampleBoundsXValues, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
    }

    func testUnlockRecognitionFailsClosedForMissingTemplateModelCameraAndInvalidScores() async throws {
        let modelURL = try makeModelFile()
        let cases: [(String, FaceSampleCaptureResult?, Error?, FaceRecognitionObservation?, FaceRecognitionUnlockGateResult)] = [
            (
                "missing template",
                .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
                FaceRecognitionRuntimeWorkflowError.noTemplate,
                nil,
                .rejected(.missingTemplate)
            ),
            (
                "camera denied",
                .permissionDenied,
                nil,
                nil,
                .rejected(.cameraPermissionDenied)
            ),
            (
                "invalid score",
                .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
                nil,
                FaceRecognitionObservation(
                    bestSimilarity: .nan,
                    modelVersion: "runtime-test-model",
                    dimension: 3,
                    comparedTemplateCount: 1,
                    frame: .usable(FaceRecognitionMatchScore(similarity: .nan, modelVersion: "runtime-test-model"))
                ),
                .rejected(.invalidScore)
            ),
            (
                "stale model",
                .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1)),
                nil,
                FaceRecognitionObservation(
                    bestSimilarity: 0.9,
                    modelVersion: "old-model",
                    dimension: 3,
                    comparedTemplateCount: 1,
                    frame: .usable(FaceRecognitionMatchScore(similarity: 0.9, modelVersion: "old-model"))
                ),
                .rejected(.staleModel)
            )
        ]

        for testCase in cases {
            let capture = QueueRecognitionSampleCapture(results: testCase.1.map { [$0] } ?? [])
            let workflow = RecordingRecognitionWorkflow(
                observation: testCase.3 ?? FaceRecognitionObservation(
                    bestSimilarity: 0.5,
                    modelVersion: "runtime-test-model",
                    dimension: 3,
                    comparedTemplateCount: 1,
                    frame: .usable(FaceRecognitionMatchScore(similarity: 0.5, modelVersion: "runtime-test-model"))
                ),
                observeError: testCase.2
            )
            let controller = FaceRecognitionRuntimeController(
                sampleCaptureService: capture,
                workflowFactory: RecordingRecognitionWorkflowFactory(workflow: workflow),
                userDefaults: userDefaults
            )
            controller.setRecognitionModelPath(modelURL.path)

            let result = await controller.evaluateUnlockRecognition()

            XCTAssertEqual(result, testCase.4, testCase.0)
            XCTAssertFalse(result.description.contains(modelURL.path), testCase.0)
        }

        userDefaults.removeObject(forKey: FaceRecognitionRuntimeController.modelPathDefaultsKey)
        let missingModelController = FaceRecognitionRuntimeController(
            sampleCaptureService: QueueRecognitionSampleCapture(),
            workflowFactory: RecordingRecognitionWorkflowFactory(),
            userDefaults: userDefaults
        )

        let missingModelResult = await missingModelController.evaluateUnlockRecognition()

        XCTAssertEqual(missingModelResult, .rejected(.missingModel))
    }

    @MainActor
    func testAppStateRecognitionActionsDoNotReadPasswordAutofillOrType() async throws {
        let modelURL = try makeModelFile()
        let capture = QueueRecognitionSampleCapture(results: [
            .captured(FaceSampleCaptureSummary(sample: try makeSample(), processedFrameCount: 1))
        ])
        let recognitionController = FaceRecognitionRuntimeController(
            sampleCaptureService: capture,
            workflowFactory: RecordingRecognitionWorkflowFactory(workflow: RecordingRecognitionWorkflow()),
            userDefaults: userDefaults
        )
        let vault = NoReadPasswordVault()
        let autofill = NoUseAutofillService()
        let typer = NoUseLockScreenTyper()
        let manager = AppStateManager(
            permissionStatusProvider: StubRecognitionPermissionStatusProvider(statuses: [.accessibility(.authorized)]),
            passwordVault: vault,
            autofillService: autofill,
            lockScreenStateProvider: StubRecognitionLockScreenStateProvider(isSessionLocked: true),
            lockScreenPasswordTyper: typer,
            recognitionRuntimeController: recognitionController,
            userDefaults: userDefaults
        )

        manager.setRecognitionModelPath(modelURL.path)
        await manager.observeRecognitionOnce()

        XCTAssertEqual(vault.events, [.hasPassword(account: defaultPasswordAccountIdentifier)])
        XCTAssertEqual(autofill.fillCallCount, 0)
        XCTAssertEqual(typer.typeCallCount, 0)
        XCTAssertNil(manager.lastManualFillResult)
        XCTAssertNil(manager.lastLockScreenUnlockResult)
        XCTAssertNil(manager.lastAutomaticLockScreenAttemptStatus)
    }

    func testSHA256HasherHashesFilesAndCompiledModelDirectories() throws {
        let fileURL = try makeModelFile(contents: Data("hash-me".utf8))
        let directoryURL = temporaryDirectory.appendingPathComponent("compiled.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: directoryURL.appendingPathComponent("weights.bin"))
        let hasher = SHA256ModelFileHasher()

        XCTAssertEqual(
            try hasher.sha256HexDigest(forFileAt: fileURL),
            "4d11186aed035cc624d553e10db358492c84a7cd6b9670d92123c144930450aa"
        )
        let directoryDigest = try hasher.sha256HexDigest(forFileAt: directoryURL)
        XCTAssertEqual(directoryDigest, try hasher.sha256HexDigest(forFileAt: directoryURL))
        XCTAssertEqual(directoryDigest.count, 64)
        XCTAssertTrue(directoryDigest.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        })
    }

    private func makeModelFile(contents: Data = Data("model".utf8)) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
        try contents.write(to: url)
        return url
    }

    private func makeSample(boundsX: CGFloat = 0) throws -> FaceEnrollmentSample {
        FaceEnrollmentSample(
            image: try makeImage(),
            visionNormalizedFaceBounds: CGRect(x: boundsX, y: 0, width: 1, height: 1)
        )
    }

    private func makeImage() throws -> CGImage {
        let width = 112
        let height = 112
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
            throw RuntimeControllerTestError.imageCreationFailed
        }

        return image
    }

}

private final class QueueRecognitionSampleCapture: FaceRecognitionModeSampleCapturing {
    private var results: [FaceSampleCaptureResult]
    private(set) var requestedTimeouts: [TimeInterval] = []
    private(set) var requestedModes: [FaceSampleCaptureMode] = []

    init(results: [FaceSampleCaptureResult] = []) {
        self.results = results
    }

    func captureSample(timeout: TimeInterval) async -> FaceSampleCaptureResult {
        await captureSample(timeout: timeout, mode: .enrollment)
    }

    func captureSample(timeout: TimeInterval, mode: FaceSampleCaptureMode) async -> FaceSampleCaptureResult {
        requestedTimeouts.append(timeout)
        requestedModes.append(mode)
        guard !results.isEmpty else {
            return .timedOut
        }

        return results.removeFirst()
    }
}

private final class RecordingRecognitionWorkflowFactory: FaceRecognitionRuntimeWorkflowMaking {
    private let workflow: RecordingRecognitionWorkflow
    private(set) var requestedModelURLs: [URL] = []

    init(workflow: RecordingRecognitionWorkflow = RecordingRecognitionWorkflow()) {
        self.workflow = workflow
    }

    func makeWorkflow(modelURL: URL) throws -> any FaceRecognitionRuntimeWorkflow {
        requestedModelURLs.append(modelURL)
        return workflow
    }
}

private struct FixedBundledModelURLProvider: FaceRecognitionBundledModelURLProviding {
    let url: URL?

    func bundledModelURL() -> URL? {
        url
    }
}

private final class RecordingRecognitionWorkflow: FaceRecognitionRuntimeWorkflow {
    let modelVersion = "runtime-test-model"
    let dimension = 3
    private var observations: [FaceRecognitionObservation]
    private let enrollError: Error?
    private let observeError: Error?
    private(set) var enrollSampleCounts: [Int] = []
    private(set) var enrollChecksums: [String] = []
    private(set) var enrollSampleBoundsXValues: [[CGFloat]] = []
    private(set) var observeCallCount = 0
    private(set) var observeSampleBoundsXValues: [CGFloat] = []

    init(
        observation: FaceRecognitionObservation = FaceRecognitionObservation(
            bestSimilarity: 0.5,
            modelVersion: "runtime-test-model",
            dimension: 3,
            comparedTemplateCount: 1,
            frame: .usable(FaceRecognitionMatchScore(similarity: 0.5, modelVersion: "runtime-test-model"))
        ),
        observations: [FaceRecognitionObservation]? = nil,
        enrollError: Error? = nil,
        observeError: Error? = nil
    ) {
        self.observations = observations ?? [observation]
        self.enrollError = enrollError
        self.observeError = observeError
    }

    func enroll(
        samples: [FaceEnrollmentSample],
        metadata: FaceEnrollmentMetadata
    ) async throws -> FaceTemplateRecord {
        enrollSampleCounts.append(samples.count)
        enrollChecksums.append(metadata.conversionArtifactChecksumSHA256)
        enrollSampleBoundsXValues.append(samples.map { $0.visionNormalizedFaceBounds.origin.x })
        if let enrollError {
            throw enrollError
        }
        return FaceTemplateRecord(
            modelVersion: modelVersion,
            conversionArtifactChecksumSHA256: metadata.conversionArtifactChecksumSHA256,
            preprocessingVersion: FaceEmbeddingPreprocessor.defaultPreprocessingVersion,
            embeddingDimension: dimension,
            embeddings: samples.enumerated().map { index, _ in
                FaceEmbedding(values: [Float(index + 1), 0, 0], modelVersion: modelVersion)
            }
        )
    }

    func observe(sample: FaceEnrollmentSample) async throws -> FaceRecognitionObservation {
        observeCallCount += 1
        observeSampleBoundsXValues.append(sample.visionNormalizedFaceBounds.origin.x)
        if let observeError {
            throw observeError
        }
        if observations.count > 1 {
            return observations.removeFirst()
        }
        return observations[0]
    }
}

private final class NoReadPasswordVault: PasswordVaultProviding {
    private(set) var events: [NoReadPasswordVaultEvent] = []

    func savePassword(_ password: String, forAccount account: String) throws {
        XCTFail("Recognition runtime must not save passwords.")
    }

    func password(forAccount account: String) throws -> String? {
        events.append(.readPassword(account: account))
        XCTFail("Recognition runtime must not read passwords.")
        return nil
    }

    func hasPassword(forAccount account: String) throws -> Bool {
        events.append(.hasPassword(account: account))
        return false
    }

    func deletePassword(forAccount account: String) throws {
        XCTFail("Recognition runtime must not delete passwords.")
    }
}

private enum NoReadPasswordVaultEvent: Equatable {
    case hasPassword(account: String)
    case readPassword(account: String)
}

private final class NoUseAutofillService: PasswordAutofillService {
    private(set) var fillCallCount = 0

    var isAccessibilityTrusted: Bool {
        true
    }

    func fillFocusedPasswordField(with password: String) -> AccessibilityAutofillResult {
        fillCallCount += 1
        XCTFail("Recognition runtime must not autofill passwords.")
        return .noFocusedPasswordField
    }
}

private final class NoUseLockScreenTyper: LockScreenPasswordTyping {
    private(set) var typeCallCount = 0

    func typePasswordAndSubmit(_ password: String) -> Bool {
        typeCallCount += 1
        XCTFail("Recognition runtime must not type lock-screen passwords.")
        return false
    }
}

private struct StubRecognitionPermissionStatusProvider: PermissionStatusProviding {
    let statuses: [PermissionStatus]

    func currentPermissionStatuses() -> [PermissionStatus] {
        statuses
    }
}

private struct StubRecognitionLockScreenStateProvider: LockScreenStateProviding {
    let isSessionLocked: Bool
}

private enum RuntimeControllerTestError: Error {
    case imageCreationFailed
    case enrollmentFailed
}
