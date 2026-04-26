import CryptoKit
import Foundation
import XCTest
@testable import FacePassCore

final class FaceTemplateStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var keychainTestApplicationTags: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        for applicationTag in keychainTestApplicationTags {
            try? KeychainFaceTemplateEncryptionKeyProvider(applicationTag: applicationTag).deleteEncryptionKey()
        }
        keychainTestApplicationTags = []
        try super.tearDownWithError()
    }

    func testSaveAndReadRoundTripsSyntheticEmbeddingsThroughTempDirectory() throws {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)
        let record = makeRecord(embeddings: [
            FaceEmbedding(values: [0.125, 0.25, 0.5], modelVersion: modelVersion),
            FaceEmbedding(values: [0.75, 0.625, 0.375], modelVersion: modelVersion)
        ])

        try store.save(record)

        let loadedRecord = try store.load()
        XCTAssertEqual(loadedRecord, record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.encryptedFileURL.path))
    }

    func testOnDiskFileDoesNotContainObviousPlaintextPayloadValues() throws {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)
        let checksum = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let record = makeRecord(
            conversionArtifactChecksumSHA256: checksum,
            embeddings: [
                FaceEmbedding(values: [0.125, 0.25, 0.5], modelVersion: modelVersion)
            ]
        )

        try store.save(record)

        let encryptedData = try Data(contentsOf: store.encryptedFileURL)
        XCTAssertFalse(encryptedData.containsPlaintext(modelVersion))
        XCTAssertFalse(encryptedData.containsPlaintext(checksum))
        XCTAssertFalse(encryptedData.containsPlaintext("0.125"))
        XCTAssertFalse(encryptedData.containsPlaintext("0.25"))
        XCTAssertFalse(encryptedData.containsPlaintext("0.5"))
    }

    func testRejectsInvalidEmbeddingSets() {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)

        XCTAssertSaveThrows(
            makeRecord(embeddings: []),
            on: store,
            expectedError: .emptyEmbeddings
        )
        XCTAssertSaveThrows(
            makeRecord(embeddings: [FaceEmbedding(values: [], modelVersion: modelVersion)]),
            on: store,
            expectedError: .emptyEmbeddingValues
        )
        XCTAssertSaveThrows(
            makeRecord(embeddings: [FaceEmbedding(values: [1, Float.nan], modelVersion: modelVersion)]),
            on: store,
            expectedError: .nonFiniteEmbeddingValue
        )
        XCTAssertSaveThrows(
            makeRecord(embeddings: [
                FaceEmbedding(values: [1, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [1, 0, 0], modelVersion: modelVersion)
            ]),
            on: store,
            expectedError: .mixedEmbeddingDimensions
        )
        XCTAssertSaveThrows(
            makeRecord(embeddings: [
                FaceEmbedding(values: [1, 0], modelVersion: modelVersion),
                FaceEmbedding(values: [1, 0], modelVersion: "synthetic-model-v2")
            ]),
            on: store,
            expectedError: .mixedModelVersions
        )
        XCTAssertSaveThrows(
            makeRecord(embeddings: [FaceEmbedding(values: [0, 0], modelVersion: modelVersion)]),
            on: store,
            expectedError: .zeroNormEmbedding
        )
        XCTAssertSaveThrows(
            makeRecord(
                embeddingDimension: 3,
                embeddings: [FaceEmbedding(values: [1, 0], modelVersion: modelVersion)]
            ),
            on: store,
            expectedError: .embeddingDimensionMismatch
        )
    }

    func testAcceptsStrictSHA256ChecksumHexCaseVariants() throws {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)

        for checksum in [
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
        ] {
            try store.save(makeRecord(conversionArtifactChecksumSHA256: checksum))
            XCTAssertEqual(try store.load()?.conversionArtifactChecksumSHA256, checksum)
        }
    }

    func testRejectsMalformedConversionArtifactChecksums() {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)

        let invalidCases: [(String, FaceTemplateStoreError)] = [
            ("", .missingConversionArtifactChecksum),
            ("  ", .missingConversionArtifactChecksum),
            ("synthetic-conversion-checksum", .invalidConversionArtifactChecksum),
            (String(repeating: "a", count: 63), .invalidConversionArtifactChecksum),
            (String(repeating: "a", count: 65), .invalidConversionArtifactChecksum),
            (String(repeating: "g", count: 64), .invalidConversionArtifactChecksum),
            (" \(String(repeating: "a", count: 64))", .invalidConversionArtifactChecksum),
            ("\(String(repeating: "a", count: 64))\n", .invalidConversionArtifactChecksum)
        ]

        for (checksum, expectedError) in invalidCases {
            XCTAssertSaveThrows(
                makeRecord(conversionArtifactChecksumSHA256: checksum),
                on: store,
                expectedError: expectedError
            )
        }
    }

    func testDeleteRemovesEncryptedFileAndCallsKeyDeleteHook() throws {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)
        let record = makeRecord()

        try store.save(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.encryptedFileURL.path))

        try store.delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.encryptedFileURL.path))
        XCTAssertEqual(keyProvider.deleteCallCount, 1)
        XCTAssertFalse(keyProvider.hasStoredKey)
    }

    func testReadingWithoutKeyFailsClosed() throws {
        let savingKeyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: savingKeyProvider)
        try store.save(makeRecord())

        let missingKeyProvider = InMemoryFaceTemplateKeyProvider(initialKeyData: nil)
        let storeWithoutKey = makeStore(keyProvider: missingKeyProvider)

        XCTAssertThrowsError(try storeWithoutKey.load()) { error in
            XCTAssertEqual(error as? FaceTemplateStoreError, .missingEncryptionKey)
        }
    }

    func testReadingTamperedFileFailsClosed() throws {
        let keyProvider = InMemoryFaceTemplateKeyProvider()
        let store = makeStore(keyProvider: keyProvider)
        try store.save(makeRecord())

        var encryptedData = try Data(contentsOf: store.encryptedFileURL)
        encryptedData[0] = encryptedData[0] ^ 0xFF
        try encryptedData.write(to: store.encryptedFileURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? FaceTemplateStoreError, .corruptOrUnreadableTemplate)
        }
    }

    func testKeychainEncryptionKeyProviderRoundTripsWithUniqueGenericPasswordItem() throws {
        let applicationTag = "com.facepass.tests.face-template-store.\(UUID().uuidString)"
        keychainTestApplicationTags.append(applicationTag)
        let keyProvider = KeychainFaceTemplateEncryptionKeyProvider(applicationTag: applicationTag)

        try keyProvider.deleteEncryptionKey()
        XCTAssertNil(try keyProvider.encryptionKeyForReading())

        let savedKey = try keyProvider.encryptionKeyForWriting()
        XCTAssertEqual(savedKey.bitCount, 256)

        let loadedKey = try XCTUnwrap(keyProvider.encryptionKeyForReading())
        XCTAssertEqual(loadedKey.bitCount, savedKey.bitCount)

        try keyProvider.deleteEncryptionKey()
        XCTAssertNil(try keyProvider.encryptionKeyForReading())
    }

    private var modelVersion: String {
        "synthetic-model-v1"
    }

    private var validConversionArtifactChecksum: String {
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    }

    private func makeStore(keyProvider: InMemoryFaceTemplateKeyProvider) -> FaceTemplateStore {
        FaceTemplateStore(baseDirectory: temporaryDirectory, keyProvider: keyProvider)
    }

    private func makeRecord(
        modelVersion: String? = nil,
        conversionArtifactChecksumSHA256: String? = nil,
        preprocessingVersion: String = "synthetic-preprocessing-v1",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        embeddingDimension: Int? = nil,
        embeddings: [FaceEmbedding]? = nil
    ) -> FaceTemplateRecord {
        let resolvedModelVersion = modelVersion ?? self.modelVersion
        return FaceTemplateRecord(
            modelVersion: resolvedModelVersion,
            conversionArtifactChecksumSHA256: conversionArtifactChecksumSHA256 ?? validConversionArtifactChecksum,
            preprocessingVersion: preprocessingVersion,
            createdAt: createdAt,
            embeddingDimension: embeddingDimension,
            embeddings: embeddings ?? [
                FaceEmbedding(values: [1, 0, 0], modelVersion: resolvedModelVersion),
                FaceEmbedding(values: [0, 1, 0], modelVersion: resolvedModelVersion)
            ]
        )
    }

    private func XCTAssertSaveThrows(
        _ record: FaceTemplateRecord,
        on store: FaceTemplateStore,
        expectedError: FaceTemplateStoreError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try store.save(record), file: file, line: line) { error in
            XCTAssertEqual(error as? FaceTemplateStoreError, expectedError, file: file, line: line)
        }
    }
}

private final class InMemoryFaceTemplateKeyProvider: FaceTemplateEncryptionKeyProviding {
    private var keyData: Data?
    private let generatedKeyData: Data
    private(set) var deleteCallCount = 0

    init(
        initialKeyData: Data? = nil,
        generatedKeyData: Data = Data((0..<32).map { UInt8($0) })
    ) {
        self.keyData = initialKeyData
        self.generatedKeyData = generatedKeyData
    }

    var hasStoredKey: Bool {
        keyData != nil
    }

    func encryptionKeyForReading() throws -> SymmetricKey? {
        keyData.map(SymmetricKey.init(data:))
    }

    func encryptionKeyForWriting() throws -> SymmetricKey {
        if keyData == nil {
            keyData = generatedKeyData
        }
        return SymmetricKey(data: keyData!)
    }

    func deleteEncryptionKey() throws {
        deleteCallCount += 1
        keyData = nil
    }
}

private extension Data {
    func containsPlaintext(_ string: String) -> Bool {
        range(of: Data(string.utf8)) != nil
    }
}
