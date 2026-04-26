import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import FacePassCore

final class FaceEnrollmentAndRecognitionObserveServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceEnrollmentAndRecognitionObserveServiceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testEnrollmentStoresOnlyTemplateRecordFromThreeExplicitSamples() async throws {
        let keyProvider = InMemoryEnrollmentTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)
        let provider = QueueFaceEmbeddingProvider(embeddings: [
            FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
            FaceEmbedding(values: [0, 1, 0], modelVersion: modelVersion),
            FaceEmbedding(values: [0, 0, 1], modelVersion: modelVersion)
        ])
        let service = FaceEnrollmentService(
            embeddingService: FaceEmbeddingService(provider: provider),
            templateStore: store
        )

        let record = try await service.enroll(
            samples: try makeSamples(count: 3),
            metadata: FaceEnrollmentMetadata(
                conversionArtifactChecksumSHA256: validConversionArtifactChecksum,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        XCTAssertEqual(record.modelVersion, modelVersion)
        XCTAssertEqual(record.conversionArtifactChecksumSHA256, validConversionArtifactChecksum)
        XCTAssertEqual(record.preprocessingVersion, FaceEmbeddingPreprocessor.defaultPreprocessingVersion)
        XCTAssertEqual(record.similarityMetric, .cosine)
        XCTAssertEqual(record.embeddingDimension, 3)
        XCTAssertEqual(record.embeddings.count, 3)
        XCTAssertEqual(provider.embeddingCallCount, 3)
        XCTAssertEqual(try store.load(), record)

        let encryptedData = try Data(contentsOf: store.encryptedFileURL)
        XCTAssertFalse(encryptedData.containsPlaintext(modelVersion))
        XCTAssertFalse(encryptedData.containsPlaintext(validConversionArtifactChecksum))
    }

    func testEnrollmentFailsClosedOnTooFewSamplesWithoutCallingProviderOrWritingTemplate() async throws {
        let keyProvider = InMemoryEnrollmentTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)
        let provider = QueueFaceEmbeddingProvider(embeddings: [
            FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)
        ])
        let service = FaceEnrollmentService(
            embeddingService: FaceEmbeddingService(provider: provider),
            templateStore: store
        )

        await XCTAssertThrowsEnrollmentError(
            try await service.enroll(
                samples: try makeSamples(count: 2),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .tooFewSamples(minimumRequired: 3, actual: 2)
        )

        XCTAssertEqual(provider.embeddingCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.encryptedFileURL.path))
    }

    func testEnrollmentFailsClosedOnPreprocessingProviderEmbeddingAndStoreValidationFailures() async throws {
        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 1, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 0, 1], modelVersion: modelVersion)
            ]).enroll(
                samples: try makeSamples(count: 3, bounds: CGRect(x: -0.1, y: 0, width: 1, height: 1)),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .preprocessingFailed
        )

        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(providerError: TestProviderError.failed).enroll(
                samples: try makeSamples(count: 3),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .embeddingProviderFailed
        )

        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, Float.nan, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 0, 1], modelVersion: modelVersion)
            ]).enroll(
                samples: try makeSamples(count: 3),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .nonFiniteEmbedding
        )

        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 1, 0], modelVersion: "synthetic-model-v2"),
                FaceEmbedding(values: [0, 0, 1], modelVersion: modelVersion)
            ]).enroll(
                samples: try makeSamples(count: 3),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .modelVersionMismatch
        )

        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 1, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 0, 1], modelVersion: modelVersion)
            ]).enroll(
                samples: try makeSamples(count: 3),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: "not-a-checksum")
            ),
            .templateStoreValidationFailed
        )
    }

    func testEnrollmentFailsClosedOnEmbeddingDimensionMismatch() async throws {
        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(
                embeddings: [
                    FaceEmbedding(values: [1, 0, 0, 0], modelVersion: modelVersion),
                    FaceEmbedding(values: [0, 1, 0, 0], modelVersion: modelVersion),
                    FaceEmbedding(values: [0, 0, 1, 0], modelVersion: modelVersion)
                ]
            ).enroll(
                samples: try makeSamples(count: 3),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .embeddingDimensionMismatch
        )

        await XCTAssertThrowsEnrollmentError(
            try await makeEnrollmentService(
                embeddings: [
                    FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
                    FaceEmbedding(values: [0, 1, 0, 0], modelVersion: modelVersion),
                    FaceEmbedding(values: [0, 0, 1], modelVersion: modelVersion)
                ]
            ).enroll(
                samples: try makeSamples(count: 3),
                metadata: FaceEnrollmentMetadata(conversionArtifactChecksumSHA256: validConversionArtifactChecksum)
            ),
            .embeddingDimensionMismatch
        )
    }

    func testObserveReturnsBestSimilarityOnlyWithoutAcceptanceDecision() async throws {
        let templateRecord = FaceTemplateRecord(
            modelVersion: modelVersion,
            conversionArtifactChecksumSHA256: validConversionArtifactChecksum,
            preprocessingVersion: FaceEmbeddingPreprocessor.defaultPreprocessingVersion,
            similarityMetric: .cosine,
            embeddingDimension: 3,
            embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [0, 1, 0], modelVersion: modelVersion)
            ]
        )
        let provider = QueueFaceEmbeddingProvider(embeddings: [
            FaceEmbedding(values: [0.2, 0.9, 0], modelVersion: modelVersion)
        ])
        let service = FaceRecognitionObserveService(
            embeddingService: FaceEmbeddingService(provider: provider)
        )

        let observation = try await service.observe(
            sample: try makeSamples(count: 1)[0],
            templateRecord: templateRecord
        )

        XCTAssertEqual(observation.modelVersion, modelVersion)
        XCTAssertEqual(observation.dimension, 3)
        XCTAssertEqual(observation.comparedTemplateCount, 2)
        XCTAssertEqual(observation.bestSimilarity, 0.976187, accuracy: 0.0001)
        XCTAssertEqual(
            observation.frame,
            .usable(FaceRecognitionMatchScore(similarity: observation.bestSimilarity, modelVersion: modelVersion))
        )
    }

    func testObserveMultipleCandidatesReturnsBestSimilarityWithoutStoringRawCandidates() async throws {
        let templateRecord = makeTemplateRecord()
        let provider = QueueFaceEmbeddingProvider(embeddings: [
            FaceEmbedding(values: [0.2, 0.9, 0], modelVersion: modelVersion),
            FaceEmbedding(values: [0.95, 0.1, 0], modelVersion: modelVersion)
        ])
        let service = FaceRecognitionObserveService(
            embeddingService: FaceEmbeddingService(provider: provider)
        )

        let observation = try await service.observe(
            samples: try makeSamples(count: 2),
            templateRecord: templateRecord
        )

        XCTAssertEqual(provider.embeddingCallCount, 2)
        XCTAssertEqual(observation.bestSimilarity, 0.994505, accuracy: 0.0001)
        XCTAssertEqual(observation.comparedTemplateCount, 1)
        XCTAssertEqual(
            observation.frame,
            .usable(FaceRecognitionMatchScore(similarity: observation.bestSimilarity, modelVersion: modelVersion))
        )
    }

    func testObserveFailsClosedOnPreprocessingProviderProbeAndTemplateMismatches() async throws {
        let validTemplate = makeTemplateRecord()

        await XCTAssertThrowsObserveError(
            try await makeObserveService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)
            ]).observe(
                sample: try makeSamples(count: 1, bounds: CGRect(x: 0, y: 0, width: 0, height: 1))[0],
                templateRecord: validTemplate
            ),
            .preprocessingFailed
        )

        await XCTAssertThrowsObserveError(
            try await makeObserveService(providerError: TestProviderError.failed).observe(
                sample: try makeSamples(count: 1)[0],
                templateRecord: validTemplate
            ),
            .embeddingProviderFailed
        )

        await XCTAssertThrowsObserveError(
            try await makeObserveService(embeddings: [
                FaceEmbedding(values: [Float.nan, 0, 0], modelVersion: modelVersion)
            ]).observe(
                sample: try makeSamples(count: 1)[0],
                templateRecord: validTemplate
            ),
            .nonFiniteProbeEmbedding
        )

        await XCTAssertThrowsObserveError(
            try await makeObserveService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: "synthetic-model-v2")
            ]).observe(
                sample: try makeSamples(count: 1)[0],
                templateRecord: validTemplate
            ),
            .modelVersionMismatch
        )

        await XCTAssertThrowsObserveError(
            try await makeObserveService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)
            ]).observe(
                sample: try makeSamples(count: 1)[0],
                templateRecord: FaceTemplateRecord(
                    modelVersion: modelVersion,
                    conversionArtifactChecksumSHA256: validConversionArtifactChecksum,
                    preprocessingVersion: "different-preprocessing-v1",
                    embeddingDimension: 3,
                    embeddings: [FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)]
                )
            ),
            .preprocessingVersionMismatch
        )
    }

    func testObserveFailsClosedOnEmbeddingDimensionMismatch() async throws {
        await XCTAssertThrowsObserveError(
            try await makeObserveService(embeddings: [
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)
            ]).observe(
                sample: try makeSamples(count: 1)[0],
                templateRecord: FaceTemplateRecord(
                    modelVersion: modelVersion,
                    conversionArtifactChecksumSHA256: validConversionArtifactChecksum,
                    preprocessingVersion: FaceEmbeddingPreprocessor.defaultPreprocessingVersion,
                    embeddingDimension: 4,
                    embeddings: [FaceEmbedding(values: [1, 0, 0, 0], modelVersion: modelVersion)]
                )
            ),
            .embeddingDimensionMismatch
        )

        await XCTAssertThrowsObserveError(
            try await makeObserveService(embeddings: [
                FaceEmbedding(values: [1, 0, 0, 0], modelVersion: modelVersion)
            ]).observe(
                sample: try makeSamples(count: 1)[0],
                templateRecord: makeTemplateRecord()
            ),
            .embeddingDimensionMismatch
        )
    }

    private var modelVersion: String {
        "synthetic-model-v1"
    }

    private var validConversionArtifactChecksum: String {
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    }

    private func makeStore(keyProvider: InMemoryEnrollmentTemplateKeyProvider) -> FaceTemplateStore {
        FaceTemplateStore(baseDirectory: temporaryDirectory, keyProvider: keyProvider)
    }

    private func makeEnrollmentService(
        embeddings: [FaceEmbedding] = [
            FaceEmbedding(values: [1, 0, 0], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [0, 1, 0], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [0, 0, 1], modelVersion: "synthetic-model-v1")
        ],
        providerError: Error? = nil
    ) -> FaceEnrollmentService<QueueFaceEmbeddingProvider> {
        FaceEnrollmentService(
            embeddingService: FaceEmbeddingService(provider: QueueFaceEmbeddingProvider(
                modelVersion: modelVersion,
                dimension: 3,
                embeddings: embeddings,
                error: providerError
            )),
            templateStore: makeStore(keyProvider: InMemoryEnrollmentTemplateKeyProvider())
        )
    }

    private func makeObserveService(
        embeddings: [FaceEmbedding] = [
            FaceEmbedding(values: [1, 0, 0], modelVersion: "synthetic-model-v1")
        ],
        providerError: Error? = nil
    ) -> FaceRecognitionObserveService<QueueFaceEmbeddingProvider> {
        FaceRecognitionObserveService(
            embeddingService: FaceEmbeddingService(provider: QueueFaceEmbeddingProvider(
                modelVersion: modelVersion,
                dimension: 3,
                embeddings: embeddings,
                error: providerError
            ))
        )
    }

    private func makeTemplateRecord() -> FaceTemplateRecord {
        FaceTemplateRecord(
            modelVersion: modelVersion,
            conversionArtifactChecksumSHA256: validConversionArtifactChecksum,
            preprocessingVersion: FaceEmbeddingPreprocessor.defaultPreprocessingVersion,
            embeddingDimension: 3,
            embeddings: [FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)]
        )
    }

    private func makeSamples(
        count: Int,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) throws -> [FaceEnrollmentSample] {
        let image = try makeImage(width: 112, height: 112) { _, _ in
            EnrollmentRGBA(red: 255, green: 128, blue: 0)
        }
        return (0..<count).map { _ in
            FaceEnrollmentSample(image: image, visionNormalizedFaceBounds: bounds)
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> EnrollmentRGBA
    ) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = Array(repeating: UInt8(0), count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let index = (y * bytesPerRow) + (x * bytesPerPixel)
                bytes[index] = color.red
                bytes[index + 1] = color.green
                bytes[index + 2] = color.blue
                bytes[index + 3] = color.alpha
            }
        }

        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
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
            throw TestImageError.makeImageFailed
        }

        return image
    }

    private func XCTAssertThrowsEnrollmentError(
        _ expression: @autoclosure () async throws -> FaceTemplateRecord,
        _ expectedError: FaceEnrollmentServiceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected FaceEnrollmentServiceError.\(expectedError).", file: file, line: line)
        } catch let error as FaceEnrollmentServiceError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Expected FaceEnrollmentServiceError, got \(error).", file: file, line: line)
        }
    }

    private func XCTAssertThrowsObserveError(
        _ expression: @autoclosure () async throws -> FaceRecognitionObservation,
        _ expectedError: FaceRecognitionObserveServiceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected FaceRecognitionObserveServiceError.\(expectedError).", file: file, line: line)
        } catch let error as FaceRecognitionObserveServiceError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Expected FaceRecognitionObserveServiceError, got \(error).", file: file, line: line)
        }
    }
}

private final class QueueFaceEmbeddingProvider: FaceEmbeddingProvider {
    private(set) var embeddingCallCount = 0

    let modelVersion: String
    let dimension: Int

    private var embeddings: [FaceEmbedding]
    private let error: Error?

    init(
        modelVersion: String = "synthetic-model-v1",
        dimension: Int = 3,
        embeddings: [FaceEmbedding],
        error: Error? = nil
    ) {
        self.modelVersion = modelVersion
        self.dimension = dimension
        self.embeddings = embeddings
        self.error = error
    }

    func embedding(for input: AlignedFaceEmbeddingInput) async throws -> FaceEmbedding {
        embeddingCallCount += 1
        try input.validate()

        if let error {
            throw error
        }

        guard !embeddings.isEmpty else {
            throw TestProviderError.missingEmbedding
        }

        return embeddings.removeFirst()
    }
}

private final class InMemoryEnrollmentTemplateKeyProvider: FaceTemplateEncryptionKeyProviding {
    private var keyData: Data?
    private let generatedKeyData: Data

    init(
        initialKeyData: Data? = nil,
        generatedKeyData: Data = Data((0..<32).map { UInt8($0) })
    ) {
        self.keyData = initialKeyData
        self.generatedKeyData = generatedKeyData
    }

    func encryptionKeyForReading() throws -> SymmetricKey? {
        keyData.map(SymmetricKey.init(data:))
    }

    func encryptionKeyForWriting() throws -> SymmetricKey {
        if keyData == nil {
            keyData = generatedKeyData
        }
        return SymmetricKey(data: keyData!)
    }

    func deleteEncryptionKey() throws {
        keyData = nil
    }
}

private struct EnrollmentRGBA {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

private enum TestImageError: Error {
    case makeImageFailed
}

private enum TestProviderError: Error {
    case failed
    case missingEmbedding
}

private extension Data {
    func containsPlaintext(_ string: String) -> Bool {
        range(of: Data(string.utf8)) != nil
    }
}
