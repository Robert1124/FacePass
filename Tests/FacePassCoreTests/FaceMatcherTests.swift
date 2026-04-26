import XCTest
@testable import FacePassCore

final class FaceMatcherTests: XCTestCase {
    func testCosineSimilarityForIdenticalVectorsIsOne() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [1, 2, 3], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [1, 2, 3], modelVersion: "synthetic-model-v1")
        )

        XCTAssertCompared(result, similarity: 1.0, dimension: 3)
    }

    func testCosineSimilarityForOppositeVectorsIsNegativeOne() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [-1, 0], modelVersion: "synthetic-model-v1")
        )

        XCTAssertCompared(result, similarity: -1.0, dimension: 2)
    }

    func testCosineSimilarityForOrthogonalVectorsIsZero() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [0, 1], modelVersion: "synthetic-model-v1")
        )

        XCTAssertCompared(result, similarity: 0.0, dimension: 2)
    }

    func testDimensionMismatchFailsClosed() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [1, 2], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [1, 2, 3], modelVersion: "synthetic-model-v1")
        )

        XCTAssertEqual(result, .failed(.dimensionMismatch))
    }

    func testEmptyEmbeddingFailsClosed() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [], modelVersion: "synthetic-model-v1")
        )

        XCTAssertEqual(result, .failed(.emptyEmbedding))
    }

    func testZeroVectorFailsClosed() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [0, 0], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v1")
        )

        XCTAssertEqual(result, .failed(.zeroNorm))
    }

    func testNaNVectorFailsClosed() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [Float.nan, 1], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v1")
        )

        XCTAssertEqual(result, .failed(.nonFiniteValue))
    }

    func testInfiniteVectorFailsClosed() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [Float.infinity, 1], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v1")
        )

        XCTAssertEqual(result, .failed(.nonFiniteValue))
    }

    func testModelVersionMismatchFailsClosed() {
        let matcher = FaceMatcher()

        let result = matcher.cosineSimilarity(
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v1"),
            FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v2")
        )

        XCTAssertEqual(result, .failed(.modelVersionMismatch))
    }

    private func XCTAssertCompared(
        _ result: FaceMatchResult,
        similarity expectedSimilarity: Float,
        dimension expectedDimension: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case let .compared(comparison):
            XCTAssertEqual(comparison.similarity, expectedSimilarity, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(comparison.dimension, expectedDimension, file: file, line: line)
        case let .failed(reason):
            XCTFail("Expected comparison but failed closed with \(reason).", file: file, line: line)
        }
    }
}
