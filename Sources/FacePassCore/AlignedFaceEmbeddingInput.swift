import Foundation

public struct AlignedFaceEmbeddingInput: Equatable {
    public static let expectedWidth = 112
    public static let expectedHeight = 112
    public static let expectedChannelCount = 3
    public static let expectedValueCount = expectedWidth * expectedHeight * expectedChannelCount
    public static let defaultPreprocessingVersion = "aligned-rgb-nchw-112-v1"

    public let width: Int
    public let height: Int
    public let channelCount: Int
    public let layout: AlignedFaceEmbeddingInputLayout
    public let preprocessingVersion: String
    public let values: [Float]

    public init(
        width: Int = Self.expectedWidth,
        height: Int = Self.expectedHeight,
        channelCount: Int = Self.expectedChannelCount,
        layout: AlignedFaceEmbeddingInputLayout = .rgbChannelsFirst,
        preprocessingVersion: String = Self.defaultPreprocessingVersion,
        values: [Float]
    ) throws {
        self.width = width
        self.height = height
        self.channelCount = channelCount
        self.layout = layout
        self.preprocessingVersion = preprocessingVersion
        self.values = values

        try validate()
    }

    public func validate() throws {
        guard width == Self.expectedWidth,
              height == Self.expectedHeight,
              channelCount == Self.expectedChannelCount
        else {
            throw AlignedFaceEmbeddingInputError.unsupportedDimensions(
                width: width,
                height: height,
                channelCount: channelCount
            )
        }

        guard layout == .rgbChannelsFirst else {
            throw AlignedFaceEmbeddingInputError.unsupportedLayout
        }

        guard !preprocessingVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AlignedFaceEmbeddingInputError.missingPreprocessingVersion
        }

        guard values.count == Self.expectedValueCount else {
            throw AlignedFaceEmbeddingInputError.invalidValueCount(
                expected: Self.expectedValueCount,
                actual: values.count
            )
        }

        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw AlignedFaceEmbeddingInputError.nonFiniteValue(index: index)
            }
        }
    }
}

public enum AlignedFaceEmbeddingInputLayout: String, Equatable {
    case rgbChannelsFirst
}

public enum AlignedFaceEmbeddingInputError: Error, Equatable, CustomStringConvertible {
    case unsupportedDimensions(width: Int, height: Int, channelCount: Int)
    case unsupportedLayout
    case missingPreprocessingVersion
    case invalidValueCount(expected: Int, actual: Int)
    case nonFiniteValue(index: Int)

    public var description: String {
        switch self {
        case let .unsupportedDimensions(width, height, channelCount):
            return "Unsupported aligned face input dimensions: \(width)x\(height)x\(channelCount)."
        case .unsupportedLayout:
            return "Unsupported aligned face input layout."
        case .missingPreprocessingVersion:
            return "Aligned face input preprocessing version is missing."
        case let .invalidValueCount(expected, actual):
            return "Aligned face input has \(actual) values, expected \(expected)."
        case let .nonFiniteValue(index):
            return "Aligned face input contains a non-finite value at index \(index)."
        }
    }
}
