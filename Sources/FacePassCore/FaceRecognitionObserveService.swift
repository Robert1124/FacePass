import CoreGraphics
import Foundation

public struct FaceRecognitionObserveService<Provider: FaceEmbeddingProvider> where Provider.Input == AlignedFaceEmbeddingInput {
    private let preprocessor: FaceEmbeddingPreprocessor
    private let embeddingService: FaceEmbeddingService<Provider>
    private let matcher: FaceMatcher

    public init(
        preprocessor: FaceEmbeddingPreprocessor = FaceEmbeddingPreprocessor(),
        embeddingService: FaceEmbeddingService<Provider>,
        matcher: FaceMatcher = FaceMatcher()
    ) {
        self.preprocessor = preprocessor
        self.embeddingService = embeddingService
        self.matcher = matcher
    }

    public func observe(
        sample: FaceEnrollmentSample,
        templateRecord: FaceTemplateRecord
    ) async throws -> FaceRecognitionObservation {
        try await observe(samples: [sample], templateRecord: templateRecord)
    }

    public func observe(
        samples: [FaceEnrollmentSample],
        templateRecord: FaceTemplateRecord
    ) async throws -> FaceRecognitionObservation {
        guard !samples.isEmpty else {
            throw FaceRecognitionObserveServiceError.emptyCandidateSamples
        }

        var bestObservation: FaceRecognitionObservation?
        var firstError: Error?

        for sample in samples {
            do {
                let observation = try await observeSingleCandidate(
                    sample: sample,
                    templateRecord: templateRecord
                )
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

    private func observeSingleCandidate(
        sample: FaceEnrollmentSample,
        templateRecord: FaceTemplateRecord
    ) async throws -> FaceRecognitionObservation {
        guard templateRecord.similarityMetric == .cosine else {
            throw FaceRecognitionObserveServiceError.unsupportedSimilarityMetric
        }

        guard templateRecord.modelVersion == embeddingService.modelVersion else {
            throw FaceRecognitionObserveServiceError.modelVersionMismatch
        }

        guard templateRecord.embeddingDimension == embeddingService.dimension else {
            throw FaceRecognitionObserveServiceError.embeddingDimensionMismatch
        }

        guard !templateRecord.embeddings.isEmpty else {
            throw FaceRecognitionObserveServiceError.emptyTemplate
        }

        let input: AlignedFaceEmbeddingInput
        do {
            input = try preprocessor.makeInput(
                from: sample.image,
                visionNormalizedFaceBounds: sample.visionNormalizedFaceBounds
            )
        } catch {
            throw FaceRecognitionObserveServiceError.preprocessingFailed
        }

        guard input.preprocessingVersion == templateRecord.preprocessingVersion else {
            throw FaceRecognitionObserveServiceError.preprocessingVersionMismatch
        }

        let probeEmbedding: FaceEmbedding
        do {
            probeEmbedding = try await embeddingService.embedding(for: input)
        } catch {
            throw FaceRecognitionObserveServiceError.embeddingProviderFailed
        }

        try validateProbeEmbedding(probeEmbedding, expectedModelVersion: templateRecord.modelVersion)

        var bestComparison: FaceMatchComparison?
        for templateEmbedding in templateRecord.embeddings {
            switch matcher.cosineSimilarity(probeEmbedding, templateEmbedding) {
            case let .compared(comparison):
                if bestComparison == nil || comparison.similarity > bestComparison!.similarity {
                    bestComparison = comparison
                }
            case let .failed(reason):
                throw FaceRecognitionObserveServiceError.matchFailed(reason)
            }
        }

        guard let bestComparison else {
            throw FaceRecognitionObserveServiceError.emptyTemplate
        }

        return FaceRecognitionObservation(
            bestSimilarity: bestComparison.similarity,
            modelVersion: bestComparison.modelVersion,
            dimension: bestComparison.dimension,
            comparedTemplateCount: templateRecord.embeddings.count,
            frame: .usable(FaceRecognitionMatchScore(
                similarity: bestComparison.similarity,
                modelVersion: bestComparison.modelVersion
            ))
        )
    }

    private func validateProbeEmbedding(
        _ embedding: FaceEmbedding,
        expectedModelVersion: String
    ) throws {
        guard embedding.modelVersion == expectedModelVersion else {
            throw FaceRecognitionObserveServiceError.modelVersionMismatch
        }

        guard embedding.dimension == embeddingService.dimension else {
            throw FaceRecognitionObserveServiceError.embeddingDimensionMismatch
        }

        guard !embedding.values.isEmpty else {
            throw FaceRecognitionObserveServiceError.emptyProbeEmbedding
        }

        var normSquared = 0.0
        for value in embedding.values {
            guard value.isFinite else {
                throw FaceRecognitionObserveServiceError.nonFiniteProbeEmbedding
            }
            let doubleValue = Double(value)
            normSquared += doubleValue * doubleValue
        }

        guard normSquared > 0 else {
            throw FaceRecognitionObserveServiceError.zeroNormProbeEmbedding
        }
    }
}

public struct FaceRecognitionObservation: Equatable {
    public let bestSimilarity: Float
    public let modelVersion: String
    public let dimension: Int
    public let comparedTemplateCount: Int
    public let frame: FaceRecognitionFrame

    public init(
        bestSimilarity: Float,
        modelVersion: String,
        dimension: Int,
        comparedTemplateCount: Int,
        frame: FaceRecognitionFrame
    ) {
        self.bestSimilarity = bestSimilarity
        self.modelVersion = modelVersion
        self.dimension = dimension
        self.comparedTemplateCount = comparedTemplateCount
        self.frame = frame
    }
}

public enum FaceRecognitionObserveServiceError: Error, Equatable, CustomStringConvertible {
    case unsupportedSimilarityMetric
    case emptyCandidateSamples
    case emptyTemplate
    case preprocessingFailed
    case preprocessingVersionMismatch
    case embeddingProviderFailed
    case emptyProbeEmbedding
    case nonFiniteProbeEmbedding
    case zeroNormProbeEmbedding
    case modelVersionMismatch
    case embeddingDimensionMismatch
    case matchFailed(FaceMatchFailureReason)

    public var description: String {
        switch self {
        case .unsupportedSimilarityMetric:
            return "Face recognition observation similarity metric is unsupported."
        case .emptyCandidateSamples:
            return "Face recognition observation has no candidate samples."
        case .emptyTemplate:
            return "Face recognition observation template is empty."
        case .preprocessingFailed:
            return "Face recognition observation preprocessing failed."
        case .preprocessingVersionMismatch:
            return "Face recognition observation preprocessing version does not match the template."
        case .embeddingProviderFailed:
            return "Face recognition observation embedding provider failed."
        case .emptyProbeEmbedding:
            return "Face recognition observation produced an empty probe embedding."
        case .nonFiniteProbeEmbedding:
            return "Face recognition observation produced a non-finite probe embedding."
        case .zeroNormProbeEmbedding:
            return "Face recognition observation produced a zero-norm probe embedding."
        case .modelVersionMismatch:
            return "Face recognition observation model versions do not match."
        case .embeddingDimensionMismatch:
            return "Face recognition observation embedding dimensions do not match."
        case let .matchFailed(reason):
            return "Face recognition observation match failed: \(reason)."
        }
    }
}
