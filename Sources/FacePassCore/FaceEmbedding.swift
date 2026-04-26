import Foundation

public struct FaceEmbedding: Equatable {
    public let values: [Float]
    public let modelVersion: String

    public init(values: [Float], modelVersion: String) {
        self.values = values
        self.modelVersion = modelVersion
    }

    public var dimension: Int {
        values.count
    }
}

public protocol FaceEmbeddingProvider {
    associatedtype Input

    var modelVersion: String { get }
    var dimension: Int { get }

    func embedding(for input: Input) async throws -> FaceEmbedding
}
