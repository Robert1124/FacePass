import XCTest
@testable import FacePassCore

final class FaceRecognitionPolicyTests: XCTestCase {
    func testUnsetThresholdIsObserveOnlyAndNotAccepted() {
        let policy = FaceRecognitionPolicy.default

        let decision = policy.evaluate([
            usableFrame(score: 0.99),
            usableFrame(score: 0.98),
            usableFrame(score: 0.97)
        ])

        XCTAssertEqual(decision, .observeOnly(.thresholdUnset))
        XCTAssertFalse(decision.isAccepted)
    }

    func testThreeAcceptedMatchesWithinSixUsableFramesAcceptsWhenThresholdConfigured() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            usableFrame(score: 0.30),
            usableFrame(score: 0.91),
            usableFrame(score: 0.10),
            usableFrame(score: 0.90),
            usableFrame(score: 0.20)
        ])

        XCTAssertEqual(decision, .accepted)
        XCTAssertTrue(decision.isAccepted)
    }

    func testFewerThanRequiredMatchesRejected() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            usableFrame(score: 0.30),
            usableFrame(score: 0.91),
            usableFrame(score: 0.20)
        ])

        XCTAssertEqual(decision, .rejected(.fewerThanRequiredMatches))
        XCTAssertFalse(decision.isAccepted)
    }

    func testTooFewUsableFramesRejected() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            usableFrame(score: 0.91)
        ])

        XCTAssertEqual(decision, .rejected(.tooFewUsableFrames))
        XCTAssertFalse(decision.isAccepted)
    }

    func testNoFaceFailsClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            .noFace
        ])

        XCTAssertEqual(decision, .rejected(.noFace))
    }

    func testMultipleFacesFailsClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            .multipleFaces
        ])

        XCTAssertEqual(decision, .rejected(.multipleFaces))
    }

    func testBadQualityFailsClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            .badQuality
        ])

        XCTAssertEqual(decision, .rejected(.badQuality))
    }

    func testModelErrorFailsClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            .modelError
        ])

        XCTAssertEqual(decision, .rejected(.modelError))
    }

    func testStaleModelVersionFailsClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            FaceRecognitionFrame.usable(FaceRecognitionMatchScore(
                similarity: 0.99,
                modelVersion: "synthetic-model-v2"
            )),
            usableFrame(score: 0.92),
            usableFrame(score: 0.91)
        ])

        XCTAssertEqual(decision, .rejected(.staleModelVersion))
    }

    func testInconsistentMatchesFailClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            .inconsistentMatchEvidence,
            usableFrame(score: 0.91)
        ])

        XCTAssertEqual(decision, .rejected(.inconsistentMatches))
    }

    func testNonFiniteScoreFailsClosed() {
        let policy = FaceRecognitionPolicy(threshold: calibratedThreshold)

        let decision = policy.evaluate([
            usableFrame(score: 0.92),
            usableFrame(score: Float.nan),
            usableFrame(score: 0.91)
        ])

        XCTAssertEqual(decision, .rejected(.invalidScore))
    }

    private var calibratedThreshold: FaceRecognitionThreshold {
        FaceRecognitionThreshold(
            minimumSimilarity: 0.90,
            modelVersion: "synthetic-model-v1"
        )
    }

    private func usableFrame(score: Float) -> FaceRecognitionFrame {
        .usable(FaceRecognitionMatchScore(
            similarity: score,
            modelVersion: "synthetic-model-v1"
        ))
    }
}
