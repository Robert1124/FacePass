import CoreML
import Foundation
import XCTest
@testable import FacePassCore

final class CoreMLFaceEmbeddingProviderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMLFaceEmbeddingProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testAlignedInputRequires112By112RGBChannelsFirstValues() throws {
        XCTAssertThrowsError(try AlignedFaceEmbeddingInput(width: 111, values: validInputValues())) { error in
            XCTAssertEqual(
                error as? AlignedFaceEmbeddingInputError,
                .unsupportedDimensions(width: 111, height: 112, channelCount: 3)
            )
        }

        XCTAssertThrowsError(try AlignedFaceEmbeddingInput(preprocessingVersion: " ", values: validInputValues())) { error in
            XCTAssertEqual(error as? AlignedFaceEmbeddingInputError, .missingPreprocessingVersion)
        }

        XCTAssertThrowsError(try AlignedFaceEmbeddingInput(values: [1, 2, 3])) { error in
            XCTAssertEqual(
                error as? AlignedFaceEmbeddingInputError,
                .invalidValueCount(expected: AlignedFaceEmbeddingInput.expectedValueCount, actual: 3)
            )
        }

        var values = validInputValues()
        values[7] = .nan
        XCTAssertThrowsError(try AlignedFaceEmbeddingInput(values: values)) { error in
            XCTAssertEqual(error as? AlignedFaceEmbeddingInputError, .nonFiniteValue(index: 7))
        }
    }

    func testProviderDoesNotLoadModelUntilEmbeddingIsRequested() throws {
        let modelURL = try createPlaceholderModelFile()
        let fakeModel = FakeCoreMLFaceEmbeddingModel(output: try makeOutput(values: validOutputValues()))
        let loader = FakeCoreMLFaceEmbeddingModelLoader(model: fakeModel)

        _ = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: loader
        )

        XCTAssertEqual(loader.loadCallCount, 0)
        XCTAssertEqual(fakeModel.predictionCallCount, 0)
    }

    func testProviderConvertsPredictionOutputToFaceEmbeddingAndCachesLoadedModel() async throws {
        let modelURL = try createPlaceholderModelFile()
        let fakeModel = FakeCoreMLFaceEmbeddingModel(output: try makeOutput(values: validOutputValues()))
        let loader = FakeCoreMLFaceEmbeddingModelLoader(model: fakeModel)
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: loader
        )

        let embedding = try await provider.embedding(for: validInput())
        let secondEmbedding = try await provider.embedding(for: validInput())

        XCTAssertEqual(embedding.dimension, 512)
        XCTAssertEqual(embedding.modelVersion, modelVersion)
        XCTAssertEqual(embedding.values.first, 1)
        XCTAssertEqual(secondEmbedding.values.first, 1)
        XCTAssertEqual(loader.loadCallCount, 1)
        XCTAssertEqual(fakeModel.predictionCallCount, 2)
        XCTAssertEqual(fakeModel.capturedInputName, "data")
        XCTAssertEqual(fakeModel.capturedInputShape, [1, 3, 112, 112])
    }

    func testProviderUsesThreeDimensionalInputShapeWhenModelDeclaresIt() async throws {
        let modelURL = try createPlaceholderModelFile()
        let model = FakeCoreMLFaceEmbeddingModel(
            description: CoreMLFaceEmbeddingModelDescription(
                inputDescriptionsByName: [
                    "data": CoreMLFaceEmbeddingFeatureDescription(
                        name: "data",
                        type: .multiArray,
                        shape: [3, 112, 112]
                    )
                ],
                outputDescriptionsByName: validOutputDescription()
            ),
            output: try makeOutput(values: validOutputValues())
        )
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(model: model)
        )

        _ = try await provider.embedding(for: validInput())

        XCTAssertEqual(model.capturedInputShape, [3, 112, 112])
    }

    func testFaceEmbeddingServiceDelegatesToProvider() async throws {
        let modelURL = try createPlaceholderModelFile()
        let fakeModel = FakeCoreMLFaceEmbeddingModel(output: try makeOutput(values: validOutputValues()))
        let loader = FakeCoreMLFaceEmbeddingModelLoader(model: fakeModel)
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: loader
        )
        let service = FaceEmbeddingService(provider: provider)

        let embedding = try await service.embedding(for: validInput())

        XCTAssertEqual(service.modelVersion, modelVersion)
        XCTAssertEqual(service.dimension, 512)
        XCTAssertEqual(embedding.dimension, 512)
        XCTAssertEqual(fakeModel.predictionCallCount, 1)
    }

    func testMissingModelFailsClosedWithoutCallingLoader() async throws {
        let loader = FakeCoreMLFaceEmbeddingModelLoader(
            model: FakeCoreMLFaceEmbeddingModel(output: try makeOutput(values: validOutputValues()))
        )
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: temporaryDirectory.appendingPathComponent("missing.mlmodel"),
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: loader
        )

        await XCTAssertThrowsProviderError(try await provider.embedding(for: validInput()), .missingModel)
        XCTAssertEqual(loader.loadCallCount, 0)
    }

    func testModelLoadFailureIsSanitized() async throws {
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: try createPlaceholderModelFile(),
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(error: CocoaError(.fileReadCorruptFile))
        )

        await XCTAssertThrowsProviderError(try await provider.embedding(for: validInput()), .modelLoadFailed)
    }

    func testModelDescriptionValidationFailsClosedBeforePrediction() async throws {
        let modelURL = try createPlaceholderModelFile()
        let missingInputModel = FakeCoreMLFaceEmbeddingModel(
            description: CoreMLFaceEmbeddingModelDescription(
                inputDescriptionsByName: [:],
                outputDescriptionsByName: validOutputDescription()
            ),
            output: try makeOutput(values: validOutputValues())
        )
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(model: missingInputModel)
        )

        await XCTAssertThrowsProviderError(
            try await provider.embedding(for: validInput()),
            .missingInputFeature(name: "data")
        )
        XCTAssertEqual(missingInputModel.predictionCallCount, 0)
    }

    func testRejectsUnsupportedModelShapes() async throws {
        let modelURL = try createPlaceholderModelFile()
        let badShapeModel = FakeCoreMLFaceEmbeddingModel(
            description: CoreMLFaceEmbeddingModelDescription(
                inputDescriptionsByName: [
                    "data": CoreMLFaceEmbeddingFeatureDescription(
                        name: "data",
                        type: .multiArray,
                        shape: [1, 112, 112, 3]
                    )
                ],
                outputDescriptionsByName: validOutputDescription()
            ),
            output: try makeOutput(values: validOutputValues())
        )
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(model: badShapeModel)
        )

        await XCTAssertThrowsProviderError(
            try await provider.embedding(for: validInput()),
            .unsupportedInputShape(name: "data", actual: [1, 112, 112, 3])
        )
        XCTAssertEqual(badShapeModel.predictionCallCount, 0)
    }

    func testAllowsUnavailableOutputShapeAndValidatesPredictionDimension() async throws {
        let modelURL = try createPlaceholderModelFile()
        let model = FakeCoreMLFaceEmbeddingModel(
            description: CoreMLFaceEmbeddingModelDescription(
                inputDescriptionsByName: validInputDescription(),
                outputDescriptionsByName: [
                    "1333": CoreMLFaceEmbeddingFeatureDescription(
                        name: "1333",
                        type: .multiArray,
                        shape: []
                    )
                ]
            ),
            output: try makeOutput(values: validOutputValues())
        )
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(model: model)
        )

        let embedding = try await provider.embedding(for: validInput())

        XCTAssertEqual(embedding.dimension, 512)
        XCTAssertEqual(model.predictionCallCount, 1)
    }

    func testPredictionFailureIsSanitized() async throws {
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: try createPlaceholderModelFile(),
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(
                model: FakeCoreMLFaceEmbeddingModel(predictionError: CocoaError(.fileReadUnknown))
            )
        )

        await XCTAssertThrowsProviderError(try await provider.embedding(for: validInput()), .predictionFailed)
    }

    func testBadPredictionOutputsFailClosed() async throws {
        try await assertOutputError(
            output: CoreMLFaceEmbeddingPrediction(multiArraysByName: [:]),
            expectedError: .missingPredictionOutput(name: "1333")
        )

        try await assertOutputError(
            output: try makeOutput(values: Array(repeating: 1, count: 511)),
            expectedError: .invalidOutputDimension(expected: 512, actual: 511)
        )

        var nonFiniteValues = validOutputValues()
        nonFiniteValues[12] = .infinity
        try await assertOutputError(
            output: try makeOutput(values: nonFiniteValues),
            expectedError: .nonFiniteOutputValue(index: 12)
        )

        try await assertOutputError(
            output: try makeOutput(values: Array(repeating: 0, count: 512)),
            expectedError: .zeroNormOutput
        )
    }

    func testOptionalDevOnlyCoreMLModelSmoke() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["FACEPASS_COREML_FACE_EMBEDDING_MODEL_PATH"],
              !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Set FACEPASS_COREML_FACE_EMBEDDING_MODEL_PATH to run the dev-only Core ML model smoke test.")
        }

        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: URL(fileURLWithPath: modelPath),
            modelVersion: "auraface-v1-glintr100-coreml-dev-smoke"
        )

        let embedding = try await provider.embedding(for: validInput())

        XCTAssertEqual(embedding.modelVersion, "auraface-v1-glintr100-coreml-dev-smoke")
        XCTAssertEqual(embedding.dimension, 512)
    }

    private var modelVersion: String {
        "test-auraface-coreml-v1"
    }

    private func validInputValues() -> [Float] {
        Array(repeating: 0.25, count: AlignedFaceEmbeddingInput.expectedValueCount)
    }

    private func validInput() throws -> AlignedFaceEmbeddingInput {
        try AlignedFaceEmbeddingInput(values: validInputValues())
    }

    private func validOutputValues() -> [Float] {
        var values = Array(repeating: Float(0.5), count: 512)
        values[0] = 1
        return values
    }

    private func createPlaceholderModelFile() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mlmodel")
        FileManager.default.createFile(atPath: url.path, contents: Data("placeholder".utf8))
        return url
    }

    private func validInputDescription() -> [String: CoreMLFaceEmbeddingFeatureDescription] {
        [
            "data": CoreMLFaceEmbeddingFeatureDescription(
                name: "data",
                type: .multiArray,
                shape: [1, 3, 112, 112]
            )
        ]
    }

    private func validOutputDescription() -> [String: CoreMLFaceEmbeddingFeatureDescription] {
        [
            "1333": CoreMLFaceEmbeddingFeatureDescription(
                name: "1333",
                type: .multiArray,
                shape: [1, 512]
            )
        ]
    }

    private func makeOutput(values: [Float]) throws -> CoreMLFaceEmbeddingPrediction {
        try CoreMLFaceEmbeddingPrediction(multiArraysByName: [
            "1333": makeMultiArray(values)
        ])
    }

    private func makeMultiArray(_ values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [NSNumber(value: values.count)], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: values.count)
        for (index, value) in values.enumerated() {
            pointer[index] = value
        }
        return array
    }

    private func assertOutputError(
        output: CoreMLFaceEmbeddingPrediction,
        expectedError: CoreMLFaceEmbeddingProviderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let provider = CoreMLFaceEmbeddingProvider(
            modelURL: try createPlaceholderModelFile(),
            modelVersion: modelVersion,
            configuration: .auraFaceGlintr100,
            modelLoader: FakeCoreMLFaceEmbeddingModelLoader(
                model: FakeCoreMLFaceEmbeddingModel(output: output)
            )
        )

        await XCTAssertThrowsProviderError(
            try await provider.embedding(for: validInput()),
            expectedError,
            file: file,
            line: line
        )
    }

    private func XCTAssertThrowsProviderError(
        _ expression: @autoclosure () async throws -> Any,
        _ expectedError: CoreMLFaceEmbeddingProviderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected CoreMLFaceEmbeddingProviderError.\(expectedError).", file: file, line: line)
        } catch let error as CoreMLFaceEmbeddingProviderError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Expected CoreMLFaceEmbeddingProviderError, got \(error).", file: file, line: line)
        }
    }
}

private final class FakeCoreMLFaceEmbeddingModelLoader: CoreMLFaceEmbeddingModelLoading {
    private let model: (any CoreMLFaceEmbeddingModelPredicting)?
    private let error: Error?
    private(set) var loadCallCount = 0

    init(model: any CoreMLFaceEmbeddingModelPredicting) {
        self.model = model
        self.error = nil
    }

    init(error: Error) {
        self.model = nil
        self.error = error
    }

    func loadModel(at url: URL) throws -> any CoreMLFaceEmbeddingModelPredicting {
        loadCallCount += 1
        if let error {
            throw error
        }
        return model!
    }
}

private final class FakeCoreMLFaceEmbeddingModel: CoreMLFaceEmbeddingModelPredicting {
    let modelDescription: CoreMLFaceEmbeddingModelDescription
    private let output: CoreMLFaceEmbeddingPrediction
    private let predictionError: Error?
    private(set) var predictionCallCount = 0
    private(set) var capturedInputName: String?
    private(set) var capturedInputShape: [Int]?

    init(
        description: CoreMLFaceEmbeddingModelDescription = CoreMLFaceEmbeddingModelDescription(
            inputDescriptionsByName: [
                "data": CoreMLFaceEmbeddingFeatureDescription(
                    name: "data",
                    type: .multiArray,
                    shape: [1, 3, 112, 112]
                )
            ],
            outputDescriptionsByName: [
                "1333": CoreMLFaceEmbeddingFeatureDescription(
                    name: "1333",
                    type: .multiArray,
                    shape: [1, 512]
                )
            ]
        ),
        output: CoreMLFaceEmbeddingPrediction? = nil,
        predictionError: Error? = nil
    ) {
        self.modelDescription = description
        self.output = output ?? CoreMLFaceEmbeddingPrediction(multiArraysByName: [:])
        self.predictionError = predictionError
    }

    func prediction(inputName: String, input: MLMultiArray) throws -> CoreMLFaceEmbeddingPrediction {
        predictionCallCount += 1
        capturedInputName = inputName
        capturedInputShape = input.shape.map { $0.intValue }
        if let predictionError {
            throw predictionError
        }
        return output
    }
}
