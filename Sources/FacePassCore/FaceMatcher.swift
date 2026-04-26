import Foundation

public struct FaceMatcher {
    public init() {}

    public func cosineSimilarity(
        _ firstEmbedding: FaceEmbedding,
        _ secondEmbedding: FaceEmbedding
    ) -> FaceMatchResult {
        guard !firstEmbedding.values.isEmpty, !secondEmbedding.values.isEmpty else {
            return .failed(.emptyEmbedding)
        }

        guard firstEmbedding.dimension == secondEmbedding.dimension else {
            return .failed(.dimensionMismatch)
        }

        guard firstEmbedding.modelVersion == secondEmbedding.modelVersion else {
            return .failed(.modelVersionMismatch)
        }

        var dotProduct = 0.0
        var firstNormSquared = 0.0
        var secondNormSquared = 0.0

        for (firstValue, secondValue) in zip(firstEmbedding.values, secondEmbedding.values) {
            guard firstValue.isFinite, secondValue.isFinite else {
                return .failed(.nonFiniteValue)
            }

            let first = Double(firstValue)
            let second = Double(secondValue)

            dotProduct += first * second
            firstNormSquared += first * first
            secondNormSquared += second * second
        }

        guard firstNormSquared > 0, secondNormSquared > 0 else {
            return .failed(.zeroNorm)
        }

        let denominator = sqrt(firstNormSquared) * sqrt(secondNormSquared)
        let similarity = dotProduct / denominator
        guard similarity.isFinite else {
            return .failed(.nonFiniteValue)
        }

        return .compared(FaceMatchComparison(
            similarity: Float(similarity),
            modelVersion: firstEmbedding.modelVersion,
            dimension: firstEmbedding.dimension
        ))
    }
}

public enum FaceMatchResult: Equatable {
    case compared(FaceMatchComparison)
    case failed(FaceMatchFailureReason)
}

public struct FaceMatchComparison: Equatable {
    public let similarity: Float
    public let modelVersion: String
    public let dimension: Int

    public init(similarity: Float, modelVersion: String, dimension: Int) {
        self.similarity = similarity
        self.modelVersion = modelVersion
        self.dimension = dimension
    }
}

public enum FaceMatchFailureReason: Equatable {
    case emptyEmbedding
    case dimensionMismatch
    case modelVersionMismatch
    case nonFiniteValue
    case zeroNorm
}
