import Foundation

public struct FaceRecognitionThreshold: Equatable {
    public let minimumSimilarity: Float
    public let modelVersion: String

    public init(minimumSimilarity: Float, modelVersion: String) {
        self.minimumSimilarity = minimumSimilarity
        self.modelVersion = modelVersion
    }
}

public struct FaceRecognitionMatchScore: Equatable {
    public let similarity: Float
    public let modelVersion: String

    public init(similarity: Float, modelVersion: String) {
        self.similarity = similarity
        self.modelVersion = modelVersion
    }
}

public enum FaceRecognitionFrame: Equatable {
    case usable(FaceRecognitionMatchScore)
    case noFace
    case multipleFaces
    case badQuality
    case modelError
    case inconsistentMatchEvidence
}

public struct FaceRecognitionPolicy: Equatable {
    public static let `default` = FaceRecognitionPolicy()

    public let threshold: FaceRecognitionThreshold?
    public let requiredAcceptedMatches: Int
    public let maximumUsableFrames: Int

    public init(
        threshold: FaceRecognitionThreshold? = nil,
        requiredAcceptedMatches: Int = 3,
        maximumUsableFrames: Int = 6
    ) {
        self.threshold = threshold
        self.requiredAcceptedMatches = max(1, requiredAcceptedMatches)
        self.maximumUsableFrames = max(self.requiredAcceptedMatches, maximumUsableFrames)
    }

    public func evaluate(_ frames: [FaceRecognitionFrame]) -> FaceRecognitionDecision {
        guard let threshold else {
            return .observeOnly(.thresholdUnset)
        }

        guard isValidSimilarity(threshold.minimumSimilarity), !threshold.modelVersion.isEmpty else {
            return .rejected(.invalidConfiguration)
        }

        var usableFrameCount = 0
        var acceptedMatchCount = 0

        for frame in frames {
            switch frame {
            case let .usable(score):
                guard usableFrameCount < maximumUsableFrames else {
                    continue
                }

                usableFrameCount += 1

                guard isValidSimilarity(score.similarity) else {
                    return .rejected(.invalidScore)
                }

                guard score.modelVersion == threshold.modelVersion else {
                    return .rejected(.staleModelVersion)
                }

                if score.similarity >= threshold.minimumSimilarity {
                    acceptedMatchCount += 1
                }
            case .noFace:
                return .rejected(.noFace)
            case .multipleFaces:
                return .rejected(.multipleFaces)
            case .badQuality:
                return .rejected(.badQuality)
            case .modelError:
                return .rejected(.modelError)
            case .inconsistentMatchEvidence:
                return .rejected(.inconsistentMatches)
            }
        }

        guard usableFrameCount >= requiredAcceptedMatches else {
            return .rejected(.tooFewUsableFrames)
        }

        guard acceptedMatchCount >= requiredAcceptedMatches else {
            return .rejected(.fewerThanRequiredMatches)
        }

        return .accepted
    }

    private func isValidSimilarity(_ similarity: Float) -> Bool {
        similarity.isFinite && similarity >= -1 && similarity <= 1
    }
}

public enum FaceRecognitionDecision: Equatable {
    case accepted
    case observeOnly(FaceRecognitionRejectionReason)
    case rejected(FaceRecognitionRejectionReason)

    public var isAccepted: Bool {
        if case .accepted = self {
            return true
        }
        return false
    }
}

public enum FaceRecognitionRejectionReason: Equatable {
    case thresholdUnset
    case invalidConfiguration
    case invalidScore
    case tooFewUsableFrames
    case noFace
    case multipleFaces
    case badQuality
    case modelError
    case staleModelVersion
    case inconsistentMatches
    case fewerThanRequiredMatches
}
