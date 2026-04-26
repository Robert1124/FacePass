import Foundation

public enum FaceRecognitionCalibrationSampleClass: Equatable {
    case genuine
    case impostor
}

public struct FaceRecognitionCalibrationAttempt: Equatable {
    public let sampleClass: FaceRecognitionCalibrationSampleClass
    public let decision: FaceRecognitionDecision
    public let frames: [FaceRecognitionFrame]?
    public let conditionSliceID: String?

    public init(
        sampleClass: FaceRecognitionCalibrationSampleClass,
        decision: FaceRecognitionDecision,
        conditionSliceID: String? = nil
    ) {
        self.sampleClass = sampleClass
        self.decision = decision
        self.frames = nil
        self.conditionSliceID = Self.normalizedConditionSliceID(conditionSliceID)
    }

    public init(
        sampleClass: FaceRecognitionCalibrationSampleClass,
        frames: [FaceRecognitionFrame],
        policy: FaceRecognitionPolicy,
        conditionSliceID: String? = nil
    ) {
        self.sampleClass = sampleClass
        self.decision = policy.evaluate(frames)
        self.frames = frames
        self.conditionSliceID = Self.normalizedConditionSliceID(conditionSliceID)
    }

    private static func normalizedConditionSliceID(_ conditionSliceID: String?) -> String? {
        guard let conditionSliceID, !conditionSliceID.isEmpty else {
            return nil
        }
        return conditionSliceID
    }
}

public struct FaceRecognitionCalibrationMetrics: Equatable {
    public let genuineAttemptCount: Int
    public let impostorAttemptCount: Int
    public let falseRejectCount: Int
    public let falseAcceptCount: Int
    public let falseRejectRate: Double
    public let falseAcceptRate: Double
    public let conditionSliceMetrics: [String: FaceRecognitionConditionSliceMetrics]

    public init(
        genuineAttemptCount: Int,
        impostorAttemptCount: Int,
        falseRejectCount: Int,
        falseAcceptCount: Int,
        conditionSliceMetrics: [String: FaceRecognitionConditionSliceMetrics] = [:]
    ) {
        self.genuineAttemptCount = max(0, genuineAttemptCount)
        self.impostorAttemptCount = max(0, impostorAttemptCount)
        self.falseRejectCount = max(0, falseRejectCount)
        self.falseAcceptCount = max(0, falseAcceptCount)
        self.falseRejectRate = Self.rate(
            numerator: self.falseRejectCount,
            denominator: self.genuineAttemptCount
        )
        self.falseAcceptRate = Self.rate(
            numerator: self.falseAcceptCount,
            denominator: self.impostorAttemptCount
        )
        self.conditionSliceMetrics = conditionSliceMetrics
    }

    public static func calculate(
        from attempts: [FaceRecognitionCalibrationAttempt]
    ) -> FaceRecognitionCalibrationMetrics {
        var genuineAttemptCount = 0
        var impostorAttemptCount = 0
        var falseRejectCount = 0
        var falseAcceptCount = 0
        var conditionSliceBuckets: [String: ConditionSliceBucket] = [:]

        for attempt in attempts {
            switch attempt.sampleClass {
            case .genuine:
                genuineAttemptCount += 1
                let isFalseReject = !attempt.decision.isAccepted
                if isFalseReject {
                    falseRejectCount += 1
                }

                if let conditionSliceID = attempt.conditionSliceID {
                    var bucket = conditionSliceBuckets[conditionSliceID] ?? ConditionSliceBucket()
                    bucket.genuineAttemptCount += 1
                    if isFalseReject {
                        bucket.falseRejectCount += 1
                    }
                    conditionSliceBuckets[conditionSliceID] = bucket
                }

            case .impostor:
                impostorAttemptCount += 1
                if attempt.decision.isAccepted {
                    falseAcceptCount += 1
                }
            }
        }

        let sliceMetrics = conditionSliceBuckets.mapValues { bucket in
            FaceRecognitionConditionSliceMetrics(
                genuineAttemptCount: bucket.genuineAttemptCount,
                falseRejectCount: bucket.falseRejectCount
            )
        }

        return FaceRecognitionCalibrationMetrics(
            genuineAttemptCount: genuineAttemptCount,
            impostorAttemptCount: impostorAttemptCount,
            falseRejectCount: falseRejectCount,
            falseAcceptCount: falseAcceptCount,
            conditionSliceMetrics: sliceMetrics
        )
    }

    private static func rate(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }
        return Double(numerator) / Double(denominator)
    }

    private struct ConditionSliceBucket {
        var genuineAttemptCount = 0
        var falseRejectCount = 0
    }
}

public struct FaceRecognitionConditionSliceMetrics: Equatable {
    public let genuineAttemptCount: Int
    public let falseRejectCount: Int
    public let falseRejectRate: Double

    public init(genuineAttemptCount: Int, falseRejectCount: Int) {
        self.genuineAttemptCount = max(0, genuineAttemptCount)
        self.falseRejectCount = max(0, falseRejectCount)
        self.falseRejectRate = Self.rate(
            numerator: self.falseRejectCount,
            denominator: self.genuineAttemptCount
        )
    }

    private static func rate(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }
        return Double(numerator) / Double(denominator)
    }
}

public struct FaceRecognitionCalibrationGate: Equatable {
    public static let prototype = FaceRecognitionCalibrationGate(
        minimumGenuineAttempts: 150,
        minimumImpostorAttempts: 300,
        maximumFalseAccepts: 0,
        maximumFalseRejectRate: 0.05,
        maximumConditionSliceFalseRejectRate: 0.10
    )

    public let minimumGenuineAttempts: Int
    public let minimumImpostorAttempts: Int
    public let maximumFalseAccepts: Int
    public let maximumFalseRejectRate: Double
    public let maximumConditionSliceFalseRejectRate: Double?

    public init(
        minimumGenuineAttempts: Int,
        minimumImpostorAttempts: Int,
        maximumFalseAccepts: Int,
        maximumFalseRejectRate: Double,
        maximumConditionSliceFalseRejectRate: Double? = nil
    ) {
        self.minimumGenuineAttempts = max(0, minimumGenuineAttempts)
        self.minimumImpostorAttempts = max(0, minimumImpostorAttempts)
        self.maximumFalseAccepts = max(0, maximumFalseAccepts)
        self.maximumFalseRejectRate = max(0, maximumFalseRejectRate)
        self.maximumConditionSliceFalseRejectRate = maximumConditionSliceFalseRejectRate.map {
            max(0, $0)
        }
    }

    public func evaluate(
        _ metrics: FaceRecognitionCalibrationMetrics
    ) -> FaceRecognitionCalibrationGateResult {
        var failures: [FaceRecognitionCalibrationGateFailure] = []

        if metrics.genuineAttemptCount < minimumGenuineAttempts {
            failures.append(.tooFewGenuineAttempts(
                required: minimumGenuineAttempts,
                actual: metrics.genuineAttemptCount
            ))
        }

        if metrics.impostorAttemptCount < minimumImpostorAttempts {
            failures.append(.tooFewImpostorAttempts(
                required: minimumImpostorAttempts,
                actual: metrics.impostorAttemptCount
            ))
        }

        if metrics.falseAcceptCount > maximumFalseAccepts {
            failures.append(.falseAcceptsObserved(count: metrics.falseAcceptCount))
        }

        if metrics.falseRejectRate > maximumFalseRejectRate {
            failures.append(.falseRejectRateTooHigh(
                maximum: maximumFalseRejectRate,
                actual: metrics.falseRejectRate
            ))
        }

        if let maximumConditionSliceFalseRejectRate {
            for (conditionSliceID, sliceMetrics) in metrics.conditionSliceMetrics.sorted(by: { $0.key < $1.key }) {
                if sliceMetrics.falseRejectRate > maximumConditionSliceFalseRejectRate {
                    failures.append(.conditionSliceFalseRejectRateTooHigh(
                        conditionSliceID: conditionSliceID,
                        maximum: maximumConditionSliceFalseRejectRate,
                        actual: sliceMetrics.falseRejectRate
                    ))
                }
            }
        }

        return FaceRecognitionCalibrationGateResult(failures: failures)
    }
}

public struct FaceRecognitionCalibrationGateResult: Equatable {
    public let isAccepted: Bool
    public let failures: [FaceRecognitionCalibrationGateFailure]

    public init(failures: [FaceRecognitionCalibrationGateFailure]) {
        self.failures = failures
        self.isAccepted = failures.isEmpty
    }
}

public enum FaceRecognitionCalibrationGateFailure: Equatable {
    case tooFewGenuineAttempts(required: Int, actual: Int)
    case tooFewImpostorAttempts(required: Int, actual: Int)
    case falseAcceptsObserved(count: Int)
    case falseRejectRateTooHigh(maximum: Double, actual: Double)
    case conditionSliceFalseRejectRateTooHigh(
        conditionSliceID: String,
        maximum: Double,
        actual: Double
    )
}

public struct FaceRecognitionThresholdSweep: Equatable {
    public let requiredAcceptedMatches: Int
    public let maximumUsableFrames: Int

    public init(requiredAcceptedMatches: Int = 3, maximumUsableFrames: Int = 6) {
        self.requiredAcceptedMatches = max(1, requiredAcceptedMatches)
        self.maximumUsableFrames = max(self.requiredAcceptedMatches, maximumUsableFrames)
    }

    public func selectThreshold(
        from attempts: [FaceRecognitionCalibrationAttempt],
        candidateMinimumSimilarities: [Float],
        modelVersion: String
    ) -> FaceRecognitionThresholdSweepResult {
        guard !attempts.isEmpty else {
            return .noSelection(.emptyAttempts)
        }

        guard attempts.allSatisfy({ $0.frames != nil }) else {
            return .noSelection(.missingFrameData)
        }

        let candidates = Array(Set(candidateMinimumSimilarities.filter {
            $0.isFinite && $0 >= -1 && $0 <= 1
        })).sorted(by: >)

        guard !candidates.isEmpty, !modelVersion.isEmpty else {
            return .noSelection(.noCandidateThresholds)
        }

        var bestSelection: (threshold: FaceRecognitionThreshold, metrics: FaceRecognitionCalibrationMetrics)?

        for candidate in candidates {
            let threshold = FaceRecognitionThreshold(
                minimumSimilarity: candidate,
                modelVersion: modelVersion
            )
            let policy = FaceRecognitionPolicy(
                threshold: threshold,
                requiredAcceptedMatches: requiredAcceptedMatches,
                maximumUsableFrames: maximumUsableFrames
            )
            let evaluatedAttempts = attempts.map { attempt in
                FaceRecognitionCalibrationAttempt(
                    sampleClass: attempt.sampleClass,
                    frames: attempt.frames ?? [],
                    policy: policy,
                    conditionSliceID: attempt.conditionSliceID
                )
            }
            let metrics = FaceRecognitionCalibrationMetrics.calculate(from: evaluatedAttempts)

            guard metrics.falseAcceptCount == 0 else {
                continue
            }

            if shouldReplaceBestSelection(
                currentBest: bestSelection,
                candidateThreshold: threshold,
                candidateMetrics: metrics
            ) {
                bestSelection = (threshold, metrics)
            }
        }

        guard let bestSelection else {
            return .noSelection(.noZeroFalseAcceptThreshold)
        }

        return .selected(
            threshold: bestSelection.threshold,
            metrics: bestSelection.metrics
        )
    }

    private func shouldReplaceBestSelection(
        currentBest: (threshold: FaceRecognitionThreshold, metrics: FaceRecognitionCalibrationMetrics)?,
        candidateThreshold: FaceRecognitionThreshold,
        candidateMetrics: FaceRecognitionCalibrationMetrics
    ) -> Bool {
        guard let currentBest else {
            return true
        }

        if candidateMetrics.falseRejectCount != currentBest.metrics.falseRejectCount {
            return candidateMetrics.falseRejectCount < currentBest.metrics.falseRejectCount
        }

        return candidateThreshold.minimumSimilarity > currentBest.threshold.minimumSimilarity
    }
}

public enum FaceRecognitionThresholdSweepResult: Equatable {
    case selected(
        threshold: FaceRecognitionThreshold,
        metrics: FaceRecognitionCalibrationMetrics
    )
    case noSelection(FaceRecognitionThresholdSweepFailure)
}

public enum FaceRecognitionThresholdSweepFailure: Equatable {
    case emptyAttempts
    case missingFrameData
    case noCandidateThresholds
    case noZeroFalseAcceptThreshold
}
