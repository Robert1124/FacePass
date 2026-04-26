import CryptoKit
import Foundation
import Security

public struct FaceTemplateStore {
    public static let currentTemplateFormatVersion = 1

    public let encryptedFileURL: URL

    private let keyProvider: any FaceTemplateEncryptionKeyProviding
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) throws {
        self.init(
            baseDirectory: try Self.defaultBaseDirectory(fileManager: fileManager),
            keyProvider: KeychainFaceTemplateEncryptionKeyProvider(),
            fileManager: fileManager
        )
    }

    public init(
        baseDirectory: URL,
        keyProvider: any FaceTemplateEncryptionKeyProviding,
        fileManager: FileManager = .default
    ) {
        self.encryptedFileURL = baseDirectory.appendingPathComponent("default-template.fpenc")
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    public static func defaultBaseDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw FaceTemplateStoreError.applicationSupportDirectoryUnavailable
        }

        return applicationSupportDirectory
            .appendingPathComponent("FacePass", isDirectory: true)
            .appendingPathComponent("FaceTemplates", isDirectory: true)
    }

    public func save(_ record: FaceTemplateRecord) throws {
        try Self.validate(record)
        let key = try keyProvider.encryptionKeyForWriting()
        try Self.validateEncryptionKey(key)

        let plaintext = try encoder().encode(FaceTemplatePayload(record: record))
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw FaceTemplateStoreError.encryptionFailed
        }

        guard let sealedData = sealedBox.combined else {
            throw FaceTemplateStoreError.encryptionFailed
        }

        try fileManager.createDirectory(
            at: encryptedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sealedData.write(to: encryptedFileURL, options: [.atomic])
    }

    public func load() throws -> FaceTemplateRecord? {
        guard fileManager.fileExists(atPath: encryptedFileURL.path) else {
            return nil
        }

        guard let key = try keyProvider.encryptionKeyForReading() else {
            throw FaceTemplateStoreError.missingEncryptionKey
        }
        try Self.validateEncryptionKey(key)

        do {
            let sealedData = try Data(contentsOf: encryptedFileURL)
            let sealedBox = try AES.GCM.SealedBox(combined: sealedData)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            let payload = try decoder().decode(FaceTemplatePayload.self, from: plaintext)
            let record = payload.record
            try Self.validate(record)
            return record
        } catch let error as FaceTemplateStoreError {
            throw error
        } catch {
            throw FaceTemplateStoreError.corruptOrUnreadableTemplate
        }
    }

    public func delete() throws {
        if fileManager.fileExists(atPath: encryptedFileURL.path) {
            try fileManager.removeItem(at: encryptedFileURL)
        }
        try keyProvider.deleteEncryptionKey()
    }

    private static func validate(_ record: FaceTemplateRecord) throws {
        guard record.templateFormatVersion == currentTemplateFormatVersion else {
            throw FaceTemplateStoreError.unsupportedTemplateFormatVersion
        }

        guard record.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FaceTemplateStoreError.invalidCreatedAt
        }

        guard !record.modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FaceTemplateStoreError.missingModelVersion
        }

        try validateConversionArtifactChecksum(record.conversionArtifactChecksumSHA256)

        guard !record.preprocessingVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FaceTemplateStoreError.missingPreprocessingVersion
        }

        guard record.similarityMetric == .cosine else {
            throw FaceTemplateStoreError.unsupportedSimilarityMetric
        }

        guard let firstEmbedding = record.embeddings.first else {
            throw FaceTemplateStoreError.emptyEmbeddings
        }

        guard !firstEmbedding.values.isEmpty else {
            throw FaceTemplateStoreError.emptyEmbeddingValues
        }

        guard record.embeddingDimension == firstEmbedding.dimension else {
            throw FaceTemplateStoreError.embeddingDimensionMismatch
        }

        for embedding in record.embeddings {
            guard embedding.modelVersion == record.modelVersion else {
                throw FaceTemplateStoreError.mixedModelVersions
            }

            guard !embedding.values.isEmpty else {
                throw FaceTemplateStoreError.emptyEmbeddingValues
            }

            guard embedding.dimension == firstEmbedding.dimension else {
                throw FaceTemplateStoreError.mixedEmbeddingDimensions
            }

            var normSquared = 0.0
            for value in embedding.values {
                guard value.isFinite else {
                    throw FaceTemplateStoreError.nonFiniteEmbeddingValue
                }
                let doubleValue = Double(value)
                normSquared += doubleValue * doubleValue
            }

            guard normSquared > 0 else {
                throw FaceTemplateStoreError.zeroNormEmbedding
            }
        }
    }

    private static func validateEncryptionKey(_ key: SymmetricKey) throws {
        guard [128, 192, 256].contains(key.bitCount) else {
            throw FaceTemplateStoreError.invalidEncryptionKeySize
        }
    }

    private static func validateConversionArtifactChecksum(_ checksum: String) throws {
        guard !checksum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FaceTemplateStoreError.missingConversionArtifactChecksum
        }

        guard checksum.utf8.count == 64, checksum.utf8.allSatisfy(Self.isHexDigit) else {
            throw FaceTemplateStoreError.invalidConversionArtifactChecksum
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public struct FaceTemplateRecord: Equatable {
    public let templateFormatVersion: Int
    public let modelVersion: String
    public let conversionArtifactChecksumSHA256: String
    public let preprocessingVersion: String
    public let createdAt: Date
    public let similarityMetric: FaceTemplateSimilarityMetric
    public let embeddingDimension: Int
    public let embeddings: [FaceEmbedding]

    public init(
        templateFormatVersion: Int = FaceTemplateStore.currentTemplateFormatVersion,
        modelVersion: String,
        conversionArtifactChecksumSHA256: String,
        preprocessingVersion: String,
        createdAt: Date = Date(),
        similarityMetric: FaceTemplateSimilarityMetric = .cosine,
        embeddingDimension: Int? = nil,
        embeddings: [FaceEmbedding]
    ) {
        self.templateFormatVersion = templateFormatVersion
        self.modelVersion = modelVersion
        self.conversionArtifactChecksumSHA256 = conversionArtifactChecksumSHA256
        self.preprocessingVersion = preprocessingVersion
        self.createdAt = createdAt
        self.similarityMetric = similarityMetric
        self.embeddingDimension = embeddingDimension ?? embeddings.first?.dimension ?? 0
        self.embeddings = embeddings
    }
}

public enum FaceTemplateSimilarityMetric: String, Codable, Equatable {
    case cosine
}

public protocol FaceTemplateEncryptionKeyProviding {
    func encryptionKeyForReading() throws -> SymmetricKey?
    func encryptionKeyForWriting() throws -> SymmetricKey
    func deleteEncryptionKey() throws
}

public struct KeychainFaceTemplateEncryptionKeyProvider: FaceTemplateEncryptionKeyProviding {
    private static let service = "com.facepass.face-template-store"

    private let account: String

    public init(applicationTag: String = "com.facepass.face-template-store.default-key") {
        self.account = applicationTag
    }

    public func encryptionKeyForReading() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let keyData = result as? Data else {
                throw FaceTemplateStoreError.keyStorageFailure(operation: .read, status: errSecInvalidItemRef)
            }
            return SymmetricKey(data: keyData)
        case errSecItemNotFound:
            return nil
        default:
            throw FaceTemplateStoreError.keyStorageFailure(operation: .read, status: status)
        }
    }

    public func encryptionKeyForWriting() throws -> SymmetricKey {
        if let existingKey = try encryptionKeyForReading() {
            return existingKey
        }

        let keyData = Self.randomKeyData()
        var query = baseQuery()
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return SymmetricKey(data: keyData)
        case errSecDuplicateItem:
            if let existingKey = try encryptionKeyForReading() {
                return existingKey
            }
            throw FaceTemplateStoreError.keyStorageFailure(operation: .save, status: status)
        default:
            throw FaceTemplateStoreError.keyStorageFailure(operation: .save, status: status)
        }
    }

    public func deleteEncryptionKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw FaceTemplateStoreError.keyStorageFailure(operation: .delete, status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private static func randomKeyData() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }
}

public enum FaceTemplateStoreError: Error, Equatable, CustomStringConvertible {
    case applicationSupportDirectoryUnavailable
    case missingEncryptionKey
    case invalidEncryptionKeySize
    case corruptOrUnreadableTemplate
    case unsupportedTemplateFormatVersion
    case invalidCreatedAt
    case missingModelVersion
    case missingConversionArtifactChecksum
    case invalidConversionArtifactChecksum
    case missingPreprocessingVersion
    case unsupportedSimilarityMetric
    case emptyEmbeddings
    case emptyEmbeddingValues
    case nonFiniteEmbeddingValue
    case mixedEmbeddingDimensions
    case embeddingDimensionMismatch
    case mixedModelVersions
    case zeroNormEmbedding
    case encryptionFailed
    case keyStorageFailure(operation: FaceTemplateKeyStorageOperation, status: OSStatus)

    public var description: String {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            "Application Support directory is unavailable."
        case .missingEncryptionKey:
            "Face template encryption key is missing."
        case .invalidEncryptionKeySize:
            "Face template encryption key size is invalid."
        case .corruptOrUnreadableTemplate:
            "Face template data is corrupt or unreadable."
        case .unsupportedTemplateFormatVersion:
            "Face template format version is unsupported."
        case .invalidCreatedAt:
            "Face template creation date is invalid."
        case .missingModelVersion:
            "Face template model version is missing."
        case .missingConversionArtifactChecksum:
            "Face template conversion artifact checksum is missing."
        case .invalidConversionArtifactChecksum:
            "Face template conversion artifact checksum must be 64 hexadecimal characters."
        case .missingPreprocessingVersion:
            "Face template preprocessing version is missing."
        case .unsupportedSimilarityMetric:
            "Face template similarity metric is unsupported."
        case .emptyEmbeddings:
            "Face template contains no embeddings."
        case .emptyEmbeddingValues:
            "Face template contains an empty embedding."
        case .nonFiniteEmbeddingValue:
            "Face template contains a non-finite embedding value."
        case .mixedEmbeddingDimensions:
            "Face template contains mixed embedding dimensions."
        case .embeddingDimensionMismatch:
            "Face template embedding dimension does not match metadata."
        case .mixedModelVersions:
            "Face template contains mixed model versions."
        case .zeroNormEmbedding:
            "Face template contains a zero-norm embedding."
        case .encryptionFailed:
            "Face template encryption failed."
        case let .keyStorageFailure(operation, status):
            "Face template key storage \(operation.rawValue) failed with status \(status)."
        }
    }
}

public enum FaceTemplateKeyStorageOperation: String, Equatable {
    case read
    case save
    case delete
}

private struct FaceTemplatePayload: Codable {
    let templateFormatVersion: Int
    let modelVersion: String
    let conversionArtifactChecksumSHA256: String
    let preprocessingVersion: String
    let createdAt: Date
    let similarityMetric: FaceTemplateSimilarityMetric
    let embeddingDimension: Int
    let embeddings: [[Float]]

    init(record: FaceTemplateRecord) {
        self.templateFormatVersion = record.templateFormatVersion
        self.modelVersion = record.modelVersion
        self.conversionArtifactChecksumSHA256 = record.conversionArtifactChecksumSHA256
        self.preprocessingVersion = record.preprocessingVersion
        self.createdAt = record.createdAt
        self.similarityMetric = record.similarityMetric
        self.embeddingDimension = record.embeddingDimension
        self.embeddings = record.embeddings.map(\.values)
    }

    var record: FaceTemplateRecord {
        FaceTemplateRecord(
            templateFormatVersion: templateFormatVersion,
            modelVersion: modelVersion,
            conversionArtifactChecksumSHA256: conversionArtifactChecksumSHA256,
            preprocessingVersion: preprocessingVersion,
            createdAt: createdAt,
            similarityMetric: similarityMetric,
            embeddingDimension: embeddingDimension,
            embeddings: embeddings.map { FaceEmbedding(values: $0, modelVersion: modelVersion) }
        )
    }
}
