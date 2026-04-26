import CoreML
import Foundation

public final class CoreMLFaceEmbeddingProvider: FaceEmbeddingProvider {
    public typealias Input = AlignedFaceEmbeddingInput

    public static let defaultAuraFaceModelVersion = "auraface-v1-glintr100-coreml-dev"

    public let modelURL: URL
    public let modelVersion: String
    public let dimension: Int

    private let configuration: CoreMLFaceEmbeddingProviderConfiguration
    private let modelLoader: any CoreMLFaceEmbeddingModelLoading
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedModel: (any CoreMLFaceEmbeddingModelPredicting)?

    public convenience init(
        modelURL: URL,
        modelVersion: String = CoreMLFaceEmbeddingProvider.defaultAuraFaceModelVersion,
        configuration: CoreMLFaceEmbeddingProviderConfiguration = .auraFaceGlintr100
    ) {
        self.init(
            modelURL: modelURL,
            modelVersion: modelVersion,
            configuration: configuration,
            modelLoader: MLModelFaceEmbeddingModelLoader(),
            fileManager: .default
        )
    }

    init(
        modelURL: URL,
        modelVersion: String,
        configuration: CoreMLFaceEmbeddingProviderConfiguration,
        modelLoader: any CoreMLFaceEmbeddingModelLoading,
        fileManager: FileManager = .default
    ) {
        self.modelURL = modelURL
        self.modelVersion = modelVersion
        self.dimension = configuration.embeddingDimension
        self.configuration = configuration
        self.modelLoader = modelLoader
        self.fileManager = fileManager
    }

    public func embedding(for input: AlignedFaceEmbeddingInput) async throws -> FaceEmbedding {
        do {
            try input.validate()
        } catch let error as AlignedFaceEmbeddingInputError {
            throw CoreMLFaceEmbeddingProviderError.invalidInput(error)
        }

        guard !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreMLFaceEmbeddingProviderError.invalidModelVersion
        }

        let model = try loadModelIfNeeded()
        let inputShape = model.modelDescription.inputDescriptionsByName[configuration.inputName]?.shape ?? []
        let inputArray = try Self.makeInputMultiArray(
            from: input,
            configuration: configuration,
            modelInputShape: inputShape
        )
        let prediction: CoreMLFaceEmbeddingPrediction

        do {
            prediction = try model.prediction(inputName: configuration.inputName, input: inputArray)
        } catch let error as CoreMLFaceEmbeddingProviderError {
            throw error
        } catch {
            throw CoreMLFaceEmbeddingProviderError.predictionFailed
        }

        let values = try Self.embeddingValues(from: prediction, configuration: configuration)
        return FaceEmbedding(values: values, modelVersion: modelVersion)
    }

    private func loadModelIfNeeded() throws -> any CoreMLFaceEmbeddingModelPredicting {
        lock.lock()
        defer { lock.unlock() }

        if let cachedModel {
            return cachedModel
        }

        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw CoreMLFaceEmbeddingProviderError.missingModel
        }

        let loadedModel: any CoreMLFaceEmbeddingModelPredicting
        do {
            loadedModel = try modelLoader.loadModel(at: modelURL)
        } catch let error as CoreMLFaceEmbeddingProviderError {
            throw error
        } catch {
            throw CoreMLFaceEmbeddingProviderError.modelLoadFailed
        }

        try Self.validateModelDescription(loadedModel.modelDescription, configuration: configuration)
        cachedModel = loadedModel
        return loadedModel
    }

    static func validateModelDescription(
        _ modelDescription: CoreMLFaceEmbeddingModelDescription,
        configuration: CoreMLFaceEmbeddingProviderConfiguration
    ) throws {
        guard let inputDescription = modelDescription.inputDescriptionsByName[configuration.inputName] else {
            throw CoreMLFaceEmbeddingProviderError.missingInputFeature(name: configuration.inputName)
        }

        guard inputDescription.type == .multiArray else {
            throw CoreMLFaceEmbeddingProviderError.unsupportedInputFeature(name: configuration.inputName)
        }

        guard isCompatibleInputShape(inputDescription.shape, configuration: configuration) else {
            throw CoreMLFaceEmbeddingProviderError.unsupportedInputShape(
                name: configuration.inputName,
                actual: inputDescription.shape
            )
        }

        guard let outputDescription = modelDescription.outputDescriptionsByName[configuration.outputName] else {
            throw CoreMLFaceEmbeddingProviderError.missingOutputFeature(name: configuration.outputName)
        }

        guard outputDescription.type == .multiArray else {
            throw CoreMLFaceEmbeddingProviderError.unsupportedOutputFeature(name: configuration.outputName)
        }

        guard outputDescription.shape.isEmpty
                || isCompatibleOutputShape(outputDescription.shape, expectedDimension: configuration.embeddingDimension) else {
            throw CoreMLFaceEmbeddingProviderError.unsupportedOutputShape(
                name: configuration.outputName,
                actual: outputDescription.shape
            )
        }
    }

    static func makeInputMultiArray(
        from input: AlignedFaceEmbeddingInput,
        configuration: CoreMLFaceEmbeddingProviderConfiguration,
        modelInputShape: [Int]
    ) throws -> MLMultiArray {
        do {
            let shape = inputMultiArrayShape(configuration: configuration, modelInputShape: modelInputShape)
            let array = try MLMultiArray(
                shape: shape.map { NSNumber(value: $0) },
                dataType: .float32
            )
            let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: input.values.count)
            for (index, value) in input.values.enumerated() {
                pointer[index] = value
            }
            return array
        } catch {
            throw CoreMLFaceEmbeddingProviderError.invalidInput(.invalidValueCount(
                expected: AlignedFaceEmbeddingInput.expectedValueCount,
                actual: input.values.count
            ))
        }
    }

    private static func inputMultiArrayShape(
        configuration: CoreMLFaceEmbeddingProviderConfiguration,
        modelInputShape: [Int]
    ) -> [Int] {
        if modelInputShape.count == 3 {
            return [
                configuration.inputChannelCount,
                configuration.inputHeight,
                configuration.inputWidth
            ]
        }

        return [
            1,
            configuration.inputChannelCount,
            configuration.inputHeight,
            configuration.inputWidth
        ]
    }

    static func embeddingValues(
        from prediction: CoreMLFaceEmbeddingPrediction,
        configuration: CoreMLFaceEmbeddingProviderConfiguration
    ) throws -> [Float] {
        guard let output = prediction.multiArraysByName[configuration.outputName] else {
            throw CoreMLFaceEmbeddingProviderError.missingPredictionOutput(name: configuration.outputName)
        }

        guard output.count == configuration.embeddingDimension else {
            throw CoreMLFaceEmbeddingProviderError.invalidOutputDimension(
                expected: configuration.embeddingDimension,
                actual: output.count
            )
        }

        var values: [Float] = []
        values.reserveCapacity(output.count)

        var normSquared = 0.0
        for index in 0..<output.count {
            let value = output[index].floatValue
            guard value.isFinite else {
                throw CoreMLFaceEmbeddingProviderError.nonFiniteOutputValue(index: index)
            }
            values.append(value)
            let doubleValue = Double(value)
            normSquared += doubleValue * doubleValue
        }

        guard normSquared > 0 else {
            throw CoreMLFaceEmbeddingProviderError.zeroNormOutput
        }

        return values
    }

    private static func isCompatibleInputShape(
        _ shape: [Int],
        configuration: CoreMLFaceEmbeddingProviderConfiguration
    ) -> Bool {
        if shape.count == 4 {
            return isFlexibleOrOne(shape[0])
                && shape[1] == configuration.inputChannelCount
                && shape[2] == configuration.inputHeight
                && shape[3] == configuration.inputWidth
        }

        if shape.count == 3 {
            return shape[0] == configuration.inputChannelCount
                && shape[1] == configuration.inputHeight
                && shape[2] == configuration.inputWidth
        }

        return false
    }

    private static func isCompatibleOutputShape(_ shape: [Int], expectedDimension: Int) -> Bool {
        if shape == [expectedDimension] {
            return true
        }

        if shape.count == 2, isFlexibleOrOne(shape[0]), shape[1] == expectedDimension {
            return true
        }

        return shape.filter { $0 > 0 }.reduce(1, *) == expectedDimension
    }

    private static func isFlexibleOrOne(_ value: Int) -> Bool {
        value == 1 || value == -1 || value == 0
    }
}

public struct CoreMLFaceEmbeddingProviderConfiguration: Equatable {
    public static let auraFaceGlintr100 = CoreMLFaceEmbeddingProviderConfiguration(
        inputName: "data",
        outputName: "1333",
        inputWidth: AlignedFaceEmbeddingInput.expectedWidth,
        inputHeight: AlignedFaceEmbeddingInput.expectedHeight,
        inputChannelCount: AlignedFaceEmbeddingInput.expectedChannelCount,
        embeddingDimension: 512
    )

    public let inputName: String
    public let outputName: String
    public let inputWidth: Int
    public let inputHeight: Int
    public let inputChannelCount: Int
    public let embeddingDimension: Int

    public init(
        inputName: String,
        outputName: String,
        inputWidth: Int,
        inputHeight: Int,
        inputChannelCount: Int,
        embeddingDimension: Int
    ) {
        self.inputName = inputName
        self.outputName = outputName
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.inputChannelCount = inputChannelCount
        self.embeddingDimension = embeddingDimension
    }
}

public enum CoreMLFaceEmbeddingProviderError: Error, Equatable, CustomStringConvertible {
    case missingModel
    case invalidModelVersion
    case invalidInput(AlignedFaceEmbeddingInputError)
    case missingInputFeature(name: String)
    case unsupportedInputFeature(name: String)
    case unsupportedInputShape(name: String, actual: [Int])
    case missingOutputFeature(name: String)
    case unsupportedOutputFeature(name: String)
    case unsupportedOutputShape(name: String, actual: [Int])
    case modelLoadFailed
    case predictionFailed
    case missingPredictionOutput(name: String)
    case invalidOutputDimension(expected: Int, actual: Int)
    case nonFiniteOutputValue(index: Int)
    case zeroNormOutput

    public var description: String {
        switch self {
        case .missingModel:
            return "Core ML face embedding model is missing."
        case .invalidModelVersion:
            return "Core ML face embedding model version is missing."
        case let .invalidInput(error):
            return "Core ML face embedding input is invalid: \(error.description)"
        case let .missingInputFeature(name):
            return "Core ML face embedding model is missing expected input '\(name)'."
        case let .unsupportedInputFeature(name):
            return "Core ML face embedding model input '\(name)' has an unsupported feature type."
        case let .unsupportedInputShape(name, actual):
            return "Core ML face embedding model input '\(name)' has unsupported shape \(actual)."
        case let .missingOutputFeature(name):
            return "Core ML face embedding model is missing expected output '\(name)'."
        case let .unsupportedOutputFeature(name):
            return "Core ML face embedding model output '\(name)' has an unsupported feature type."
        case let .unsupportedOutputShape(name, actual):
            return "Core ML face embedding model output '\(name)' has unsupported shape \(actual)."
        case .modelLoadFailed:
            return "Core ML face embedding model load failed."
        case .predictionFailed:
            return "Core ML face embedding prediction failed."
        case let .missingPredictionOutput(name):
            return "Core ML face embedding prediction is missing output '\(name)'."
        case let .invalidOutputDimension(expected, actual):
            return "Core ML face embedding output has \(actual) values, expected \(expected)."
        case let .nonFiniteOutputValue(index):
            return "Core ML face embedding output contains a non-finite value at index \(index)."
        case .zeroNormOutput:
            return "Core ML face embedding output has zero norm."
        }
    }
}

struct CoreMLFaceEmbeddingModelDescription: Equatable {
    let inputDescriptionsByName: [String: CoreMLFaceEmbeddingFeatureDescription]
    let outputDescriptionsByName: [String: CoreMLFaceEmbeddingFeatureDescription]
}

struct CoreMLFaceEmbeddingFeatureDescription: Equatable {
    let name: String
    let type: CoreMLFaceEmbeddingFeatureType
    let shape: [Int]
}

enum CoreMLFaceEmbeddingFeatureType: Equatable {
    case multiArray
    case unsupported
}

struct CoreMLFaceEmbeddingPrediction {
    let multiArraysByName: [String: MLMultiArray]
}

protocol CoreMLFaceEmbeddingModelPredicting: AnyObject {
    var modelDescription: CoreMLFaceEmbeddingModelDescription { get }

    func prediction(inputName: String, input: MLMultiArray) throws -> CoreMLFaceEmbeddingPrediction
}

protocol CoreMLFaceEmbeddingModelLoading {
    func loadModel(at url: URL) throws -> any CoreMLFaceEmbeddingModelPredicting
}

private final class MLModelFaceEmbeddingModelLoader: CoreMLFaceEmbeddingModelLoading {
    private let configuration: MLModelConfiguration

    init(configuration: MLModelConfiguration = MLModelConfiguration()) {
        self.configuration = configuration
    }

    func loadModel(at url: URL) throws -> any CoreMLFaceEmbeddingModelPredicting {
        do {
            let loadURL = try compiledModelURL(for: url)
            let model = try MLModel(contentsOf: loadURL, configuration: configuration)
            return MLModelFaceEmbeddingModel(model: model)
        } catch let error as CoreMLFaceEmbeddingProviderError {
            throw error
        } catch {
            throw CoreMLFaceEmbeddingProviderError.modelLoadFailed
        }
    }

    private func compiledModelURL(for url: URL) throws -> URL {
        switch url.pathExtension {
        case "mlmodel", "mlpackage":
            do {
                return try MLModel.compileModel(at: url)
            } catch {
                throw CoreMLFaceEmbeddingProviderError.modelLoadFailed
            }
        default:
            return url
        }
    }
}

private final class MLModelFaceEmbeddingModel: CoreMLFaceEmbeddingModelPredicting {
    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    var modelDescription: CoreMLFaceEmbeddingModelDescription {
        CoreMLFaceEmbeddingModelDescription(
            inputDescriptionsByName: Self.convert(model.modelDescription.inputDescriptionsByName),
            outputDescriptionsByName: Self.convert(model.modelDescription.outputDescriptionsByName)
        )
    }

    func prediction(inputName: String, input: MLMultiArray) throws -> CoreMLFaceEmbeddingPrediction {
        do {
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(multiArray: input)
            ])
            let outputProvider = try model.prediction(from: inputProvider)
            var outputs: [String: MLMultiArray] = [:]

            for outputName in outputProvider.featureNames {
                if let multiArray = outputProvider.featureValue(for: outputName)?.multiArrayValue {
                    outputs[outputName] = multiArray
                }
            }

            return CoreMLFaceEmbeddingPrediction(multiArraysByName: outputs)
        } catch let error as CoreMLFaceEmbeddingProviderError {
            throw error
        } catch {
            throw CoreMLFaceEmbeddingProviderError.predictionFailed
        }
    }

    private static func convert(
        _ descriptions: [String: MLFeatureDescription]
    ) -> [String: CoreMLFaceEmbeddingFeatureDescription] {
        descriptions.mapValues { description in
            CoreMLFaceEmbeddingFeatureDescription(
                name: description.name,
                type: description.type == .multiArray ? .multiArray : .unsupported,
                shape: description.multiArrayConstraint?.shape.map { $0.intValue } ?? []
            )
        }
    }
}
