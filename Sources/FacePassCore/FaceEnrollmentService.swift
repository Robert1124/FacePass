import CoreGraphics
import Foundation

public struct FaceEnrollmentSample {
    public let image: CGImage
    public let visionNormalizedFaceBounds: CGRect

    public init(image: CGImage, visionNormalizedFaceBounds: CGRect) {
        self.image = image
        self.visionNormalizedFaceBounds = visionNormalizedFaceBounds
    }
}

public struct FaceEnrollmentMetadata {
    public let conversionArtifactChecksumSHA256: String
    public let createdAt: Date
    public let similarityMetric: FaceTemplateSimilarityMetric

    public init(
        conversionArtifactChecksumSHA256: String,
        createdAt: Date = Date(),
        similarityMetric: FaceTemplateSimilarityMetric = .cosine
    ) {
        self.conversionArtifactChecksumSHA256 = conversionArtifactChecksumSHA256
        self.createdAt = createdAt
        self.similarityMetric = similarityMetric
    }
}

public struct FaceEnrollmentService<Provider: FaceEmbeddingProvider> where Provider.Input == AlignedFaceEmbeddingInput {
    public static var defaultMinimumSampleCount: Int { 3 }

    private let preprocessor: FaceEmbeddingPreprocessor
    private let embeddingService: FaceEmbeddingService<Provider>
    private let templateStore: FaceTemplateStore
    private let minimumSampleCount: Int

    public init(
        preprocessor: FaceEmbeddingPreprocessor = FaceEmbeddingPreprocessor(),
        embeddingService: FaceEmbeddingService<Provider>,
        templateStore: FaceTemplateStore,
        minimumSampleCount: Int = Self.defaultMinimumSampleCount
    ) {
        self.preprocessor = preprocessor
        self.embeddingService = embeddingService
        self.templateStore = templateStore
        self.minimumSampleCount = max(1, minimumSampleCount)
    }

    @discardableResult
    public func enroll(
        samples: [FaceEnrollmentSample],
        metadata: FaceEnrollmentMetadata
    ) async throws -> FaceTemplateRecord {
        guard samples.count >= minimumSampleCount else {
            throw FaceEnrollmentServiceError.tooFewSamples(
                minimumRequired: minimumSampleCount,
                actual: samples.count
            )
        }

        var embeddings: [FaceEmbedding] = []
        var preprocessingVersion: String?

        for sample in samples {
            let input: AlignedFaceEmbeddingInput
            do {
                input = try preprocessor.makeInput(
                    from: sample.image,
                    visionNormalizedFaceBounds: sample.visionNormalizedFaceBounds
                )
            } catch {
                throw FaceEnrollmentServiceError.preprocessingFailed
            }

            if let existingPreprocessingVersion = preprocessingVersion {
                guard existingPreprocessingVersion == input.preprocessingVersion else {
                    throw FaceEnrollmentServiceError.preprocessingVersionMismatch
                }
            } else {
                preprocessingVersion = input.preprocessingVersion
            }

            let embedding: FaceEmbedding
            do {
                embedding = try await embeddingService.embedding(for: input)
            } catch {
                throw FaceEnrollmentServiceError.embeddingProviderFailed
            }

            try validateEmbedding(embedding)
            embeddings.append(embedding)
        }

        guard let firstEmbedding = embeddings.first else {
            throw FaceEnrollmentServiceError.emptyEmbedding
        }

        guard firstEmbedding.modelVersion == embeddingService.modelVersion else {
            throw FaceEnrollmentServiceError.modelVersionMismatch
        }

        guard firstEmbedding.dimension == embeddingService.dimension else {
            throw FaceEnrollmentServiceError.embeddingDimensionMismatch
        }

        for embedding in embeddings.dropFirst() {
            guard embedding.modelVersion == firstEmbedding.modelVersion else {
                throw FaceEnrollmentServiceError.modelVersionMismatch
            }

            guard embedding.dimension == firstEmbedding.dimension else {
                throw FaceEnrollmentServiceError.embeddingDimensionMismatch
            }
        }

        let record = FaceTemplateRecord(
            modelVersion: firstEmbedding.modelVersion,
            conversionArtifactChecksumSHA256: metadata.conversionArtifactChecksumSHA256,
            preprocessingVersion: preprocessingVersion ?? FaceEmbeddingPreprocessor.defaultPreprocessingVersion,
            createdAt: metadata.createdAt,
            similarityMetric: metadata.similarityMetric,
            embeddingDimension: firstEmbedding.dimension,
            embeddings: embeddings
        )

        do {
            try templateStore.save(record)
        } catch {
            throw FaceEnrollmentServiceError.templateStoreValidationFailed
        }

        return record
    }

    private func validateEmbedding(_ embedding: FaceEmbedding) throws {
        guard !embedding.values.isEmpty else {
            throw FaceEnrollmentServiceError.emptyEmbedding
        }

        var normSquared = 0.0
        for value in embedding.values {
            guard value.isFinite else {
                throw FaceEnrollmentServiceError.nonFiniteEmbedding
            }
            let doubleValue = Double(value)
            normSquared += doubleValue * doubleValue
        }

        guard normSquared > 0 else {
            throw FaceEnrollmentServiceError.zeroNormEmbedding
        }
    }
}

public enum FaceEnrollmentServiceError: Error, Equatable, CustomStringConvertible {
    case tooFewSamples(minimumRequired: Int, actual: Int)
    case preprocessingFailed
    case preprocessingVersionMismatch
    case embeddingProviderFailed
    case emptyEmbedding
    case nonFiniteEmbedding
    case zeroNormEmbedding
    case modelVersionMismatch
    case embeddingDimensionMismatch
    case templateStoreValidationFailed

    public var description: String {
        switch self {
        case let .tooFewSamples(minimumRequired, actual):
            return "Face enrollment requires at least \(minimumRequired) samples, got \(actual)."
        case .preprocessingFailed:
            return "Face enrollment preprocessing failed."
        case .preprocessingVersionMismatch:
            return "Face enrollment preprocessing versions do not match."
        case .embeddingProviderFailed:
            return "Face enrollment embedding provider failed."
        case .emptyEmbedding:
            return "Face enrollment produced an empty embedding."
        case .nonFiniteEmbedding:
            return "Face enrollment produced a non-finite embedding."
        case .zeroNormEmbedding:
            return "Face enrollment produced a zero-norm embedding."
        case .modelVersionMismatch:
            return "Face enrollment model versions do not match."
        case .embeddingDimensionMismatch:
            return "Face enrollment embedding dimensions do not match."
        case .templateStoreValidationFailed:
            return "Face enrollment template-store validation failed."
        }
    }
}
