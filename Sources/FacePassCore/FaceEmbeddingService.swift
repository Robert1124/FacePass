import Foundation

public struct FaceEmbeddingService<Provider: FaceEmbeddingProvider> where Provider.Input == AlignedFaceEmbeddingInput {
    private let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    public var modelVersion: String {
        provider.modelVersion
    }

    public var dimension: Int {
        provider.dimension
    }

    public func embedding(for input: AlignedFaceEmbeddingInput) async throws -> FaceEmbedding {
        try await provider.embedding(for: input)
    }
}
