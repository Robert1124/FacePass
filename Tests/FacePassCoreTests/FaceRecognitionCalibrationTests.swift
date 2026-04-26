import XCTest
@testable import FacePassCore

final class FaceRecognitionCalibrationTests: XCTestCase {
    func testMetricsCountWindowLevelFalseRejectsAndFalseAccepts() {
        let attempts: [FaceRecognitionCalibrationAttempt] = [
            attempt(.genuine, .accepted),
            attempt(.genuine, .rejected(.noFace)),
            attempt(.impostor, .accepted),
            attempt(.impostor, .rejected(.fewerThanRequiredMatches))
        ]

        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: attempts)

        XCTAssertEqual(metrics.genuineAttemptCount, 2)
        XCTAssertEqual(metrics.impostorAttemptCount, 2)
        XCTAssertEqual(metrics.falseRejectCount, 1)
        XCTAssertEqual(metrics.falseAcceptCount, 1)
        XCTAssertEqual(metrics.falseRejectRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.falseAcceptRate, 0.5, accuracy: 0.0001)
    }

    func testAttemptCanEvaluateFramesWithPolicy() {
        let policy = FaceRecognitionPolicy(threshold: syntheticThreshold)

        let genuineAttempt = FaceRecognitionCalibrationAttempt(
            sampleClass: .genuine,
            frames: [
                usableFrame(score: 0.93),
                usableFrame(score: 0.92),
                usableFrame(score: 0.91)
            ],
            policy: policy
        )
        let impostorAttempt = FaceRecognitionCalibrationAttempt(
            sampleClass: .impostor,
            frames: [
                usableFrame(score: 0.30),
                usableFrame(score: 0.20),
                usableFrame(score: 0.10)
            ],
            policy: policy
        )

        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: [
            genuineAttempt,
            impostorAttempt
        ])

        XCTAssertEqual(genuineAttempt.decision, .accepted)
        XCTAssertEqual(impostorAttempt.decision, .rejected(.fewerThanRequiredMatches))
        XCTAssertEqual(metrics.falseRejectCount, 0)
        XCTAssertEqual(metrics.falseAcceptCount, 0)
    }

    func testPrototypeGatePassesWithRequiredCountsZeroFalseAcceptsAndFrrAtOrBelowFivePercent() {
        let attempts =
            repeatedAttempts(.genuine, count: 143, decision: .accepted)
            + repeatedAttempts(.genuine, count: 7, decision: .rejected(.fewerThanRequiredMatches))
            + repeatedAttempts(.impostor, count: 300, decision: .rejected(.fewerThanRequiredMatches))
        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: attempts)

        let result = FaceRecognitionCalibrationGate.prototype.evaluate(metrics)

        XCTAssertTrue(result.isAccepted)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(metrics.falseRejectRate, 7.0 / 150.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.falseAcceptRate, 0.0, accuracy: 0.0001)
    }

    func testPrototypeGateFailsWhenAnyFalseAcceptIsPresent() {
        let attempts =
            repeatedAttempts(.genuine, count: 150, decision: .accepted)
            + repeatedAttempts(.impostor, count: 299, decision: .rejected(.fewerThanRequiredMatches))
            + repeatedAttempts(.impostor, count: 1, decision: .accepted)
        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: attempts)

        let result = FaceRecognitionCalibrationGate.prototype.evaluate(metrics)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.failures.contains(.falseAcceptsObserved(count: 1)))
    }

    func testPrototypeGateFailsWhenAttemptCountsAreTooLow() {
        let attempts =
            repeatedAttempts(.genuine, count: 149, decision: .accepted)
            + repeatedAttempts(.impostor, count: 299, decision: .rejected(.fewerThanRequiredMatches))
        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: attempts)

        let result = FaceRecognitionCalibrationGate.prototype.evaluate(metrics)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.failures.contains(.tooFewGenuineAttempts(required: 150, actual: 149)))
        XCTAssertTrue(result.failures.contains(.tooFewImpostorAttempts(required: 300, actual: 299)))
    }

    func testPrototypeGateFailsWhenConditionSliceFrrExceedsTenPercent() {
        let attempts =
            repeatedAttempts(.genuine, count: 8, decision: .accepted, conditionSliceID: "slice-low-light")
            + repeatedAttempts(
                .genuine,
                count: 1,
                decision: .rejected(.fewerThanRequiredMatches),
                conditionSliceID: "slice-low-light"
            )
            + repeatedAttempts(.genuine, count: 141, decision: .accepted, conditionSliceID: "slice-bright")
            + repeatedAttempts(.impostor, count: 300, decision: .rejected(.fewerThanRequiredMatches))
        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: attempts)

        let result = FaceRecognitionCalibrationGate.prototype.evaluate(metrics)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.failures.contains(.conditionSliceFalseRejectRateTooHigh(
            conditionSliceID: "slice-low-light",
            maximum: 0.10,
            actual: 1.0 / 9.0
        )))
        XCTAssertEqual(metrics.falseRejectRate, 1.0 / 150.0, accuracy: 0.0001)
    }

    func testEmptyAttemptsFailPrototypeGateClosed() {
        let metrics = FaceRecognitionCalibrationMetrics.calculate(from: [])

        let result = FaceRecognitionCalibrationGate.prototype.evaluate(metrics)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.failures.contains(.tooFewGenuineAttempts(required: 150, actual: 0)))
        XCTAssertTrue(result.failures.contains(.tooFewImpostorAttempts(required: 300, actual: 0)))
    }

    func testThresholdSweepSelectsZeroFalseAcceptThresholdWithFewestFalseRejects() {
        let attempts: [FaceRecognitionCalibrationAttempt] = [
            frameAttempt(.genuine, scores: [0.95, 0.94, 0.93]),
            frameAttempt(.genuine, scores: [0.88, 0.87, 0.86]),
            frameAttempt(.impostor, scores: [0.82, 0.81, 0.80])
        ]

        let result = FaceRecognitionThresholdSweep().selectThreshold(
            from: attempts,
            candidateMinimumSimilarities: [0.80, 0.85, 0.90],
            modelVersion: syntheticModelVersion
        )

        XCTAssertEqual(result, .selected(
            threshold: FaceRecognitionThreshold(
                minimumSimilarity: 0.85,
                modelVersion: syntheticModelVersion
            ),
            metrics: FaceRecognitionCalibrationMetrics(
                genuineAttemptCount: 2,
                impostorAttemptCount: 1,
                falseRejectCount: 0,
                falseAcceptCount: 0,
                conditionSliceMetrics: [:]
            )
        ))
    }

    func testThresholdSweepFailsClosedWhenNoCandidateAvoidsFalseAccepts() {
        let attempts: [FaceRecognitionCalibrationAttempt] = [
            frameAttempt(.genuine, scores: [0.95, 0.94, 0.93]),
            frameAttempt(.impostor, scores: [0.82, 0.81, 0.80])
        ]

        let result = FaceRecognitionThresholdSweep().selectThreshold(
            from: attempts,
            candidateMinimumSimilarities: [0.80],
            modelVersion: syntheticModelVersion
        )

        XCTAssertEqual(result, .noSelection(.noZeroFalseAcceptThreshold))
    }

    private var syntheticThreshold: FaceRecognitionThreshold {
        FaceRecognitionThreshold(
            minimumSimilarity: 0.90,
            modelVersion: syntheticModelVersion
        )
    }

    private var syntheticModelVersion: String {
        "synthetic-model-v1"
    }

    private func attempt(
        _ sampleClass: FaceRecognitionCalibrationSampleClass,
        _ decision: FaceRecognitionDecision,
        conditionSliceID: String? = nil
    ) -> FaceRecognitionCalibrationAttempt {
        FaceRecognitionCalibrationAttempt(
            sampleClass: sampleClass,
            decision: decision,
            conditionSliceID: conditionSliceID
        )
    }

    private func repeatedAttempts(
        _ sampleClass: FaceRecognitionCalibrationSampleClass,
        count: Int,
        decision: FaceRecognitionDecision,
        conditionSliceID: String? = nil
    ) -> [FaceRecognitionCalibrationAttempt] {
        (0..<count).map { _ in
            attempt(sampleClass, decision, conditionSliceID: conditionSliceID)
        }
    }

    private func frameAttempt(
        _ sampleClass: FaceRecognitionCalibrationSampleClass,
        scores: [Float]
    ) -> FaceRecognitionCalibrationAttempt {
        FaceRecognitionCalibrationAttempt(
            sampleClass: sampleClass,
            frames: scores.map(usableFrame(score:)),
            policy: FaceRecognitionPolicy(threshold: syntheticThreshold)
        )
    }

    private func usableFrame(score: Float) -> FaceRecognitionFrame {
        .usable(FaceRecognitionMatchScore(
            similarity: score,
            modelVersion: syntheticModelVersion
        ))
    }
}
