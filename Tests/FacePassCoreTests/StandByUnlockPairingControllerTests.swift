import CryptoKit
import Foundation
import Security
import XCTest
@testable import FacePassCore

final class StandByUnlockPairingControllerTests: XCTestCase {
    func testStartPairingSessionReturnsOneTimeTokenQRCodePayloadWithoutSecrets() throws {
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = makePairingController(store: store)

        let session = controller.startPairingSession()

        XCTAssertEqual(session.macDeviceId, "mac-facepass-1")
        XCTAssertEqual(session.protocolVersion, 1)
        XCTAssertEqual(session.publicKeyFingerprint, "SHA256:public-key-fingerprint")
        XCTAssertEqual(session.oneTimeToken, "one-time-token")
        XCTAssertEqual(session.expiresAt, standbyHTTPDate("2026-04-27T14:10:00Z"))
        XCTAssertEqual(session.qrPayload["macDeviceId"] as? String, "mac-facepass-1")
        XCTAssertEqual(session.qrPayload["publicKeyFingerprint"] as? String, "SHA256:public-key-fingerprint")
        XCTAssertEqual(session.qrPayload["oneTimeToken"] as? String, "one-time-token")
        XCTAssertEqual(session.qrPayload["bonjourServiceType"] as? String, "_facepass._tcp")
        XCTAssertEqual(session.qrPayload["bonjourDomain"] as? String, "local")
        XCTAssertEqual(session.qrPayload["expiresAt"] as? String, "2026-04-27T14:10:00Z")
        XCTAssertNil(session.qrPayload["publicKeyX963Representation"])
        XCTAssertNil(session.qrPayload["privateKey"])
        XCTAssertNil(session.qrPayload["password"])
        XCTAssertNil(session.qrPayload["requestId"])
        XCTAssertNil(session.qrPayload["faceData"])
        XCTAssertFalse(String(describing: session).localizedCaseInsensitiveContains("password"))
        XCTAssertNil(try store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
    }

    func testStartPairingSessionIncludesLocalEndpointWhenAvailableWithoutLoopback() throws {
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: store,
            clock: { standbyHTTPDate("2026-04-27T14:05:00Z") },
            tokenGenerator: { "one-time-token" },
            localEndpointProvider: {
                StandByPairingEndpoint(host: "192.168.4.204", port: 65508, scheme: "http")
            }
        )

        let session = controller.startPairingSession()
        let endpoint = try XCTUnwrap(session.qrPayload["localEndpoint"] as? [String: Any])

        XCTAssertEqual(endpoint["host"] as? String, "192.168.4.204")
        XCTAssertEqual(endpoint["port"] as? Int, 65508)
        XCTAssertEqual(endpoint["scheme"] as? String, "http")
        XCTAssertEqual(endpoint["url"] as? String, "http://192.168.4.204:65508")
        XCTAssertNotEqual(endpoint["host"] as? String, "127.0.0.1")
        XCTAssertNil(session.qrPayload["password"])
        XCTAssertNil(session.qrPayload["privateKey"])
    }

    func testRegisterIPhoneRequiresCurrentOneTimeTokenAndStoresPublicKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = makePairingController(store: store)
        let session = controller.startPairingSession()

        let result = try controller.registerIPhone(
            StandByIPhonePairingRegistration(
                oneTimeToken: session.oneTimeToken,
                iphoneDeviceId: "iphone-standby-1",
                displayName: "StandBy Test iPhone",
                publicKeyX963Representation: privateKey.publicKey.x963Representation
            )
        )

        XCTAssertEqual(result.iphoneDeviceId, "iphone-standby-1")
        let stored = try XCTUnwrap(store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
        XCTAssertEqual(stored.iphoneDeviceId, "iphone-standby-1")
        XCTAssertEqual(stored.displayName, "StandBy Test iPhone")
        XCTAssertEqual(stored.publicKeyX963Representation, privateKey.publicKey.x963Representation)
        XCTAssertEqual(stored.signingAlgorithm, .p256SHA256)
        XCTAssertTrue(stored.isEnabled)
        XCTAssertEqual(stored.highestAcceptedCounter, 0)
        XCTAssertFalse(String(describing: result).localizedCaseInsensitiveContains("password"))
    }

    func testRegisteringSecondIPhoneReplacesPreviousPairedTrustRecord() throws {
        let firstPrivateKey = P256.Signing.PrivateKey()
        let secondPrivateKey = P256.Signing.PrivateKey()
        var now = standbyHTTPDate("2026-04-27T14:05:00Z")
        var nextToken = "first-token"
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: store,
            clock: { now },
            tokenGenerator: { nextToken }
        )

        let firstSession = controller.startPairingSession()
        _ = try controller.registerIPhone(
            StandByIPhonePairingRegistration(
                oneTimeToken: firstSession.oneTimeToken,
                iphoneDeviceId: "iphone-standby-1",
                displayName: "First iPhone",
                publicKeyX963Representation: firstPrivateKey.publicKey.x963Representation
            )
        )

        now = standbyHTTPDate("2026-04-27T14:06:00Z")
        nextToken = "second-token"
        let secondSession = controller.startPairingSession()
        _ = try controller.registerIPhone(
            StandByIPhonePairingRegistration(
                oneTimeToken: secondSession.oneTimeToken,
                iphoneDeviceId: "iphone-standby-2",
                displayName: "Second iPhone",
                publicKeyX963Representation: secondPrivateKey.publicKey.x963Representation
            )
        )

        XCTAssertNil(try store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
        let stored = try XCTUnwrap(store.pairedDevice(forIPhoneDeviceId: "iphone-standby-2"))
        XCTAssertEqual(stored.displayName, "Second iPhone")
        XCTAssertEqual(try store.currentPairedDevice()?.iphoneDeviceId, "iphone-standby-2")
    }

    func testCurrentPairedDeviceFallsBackToAccountLookupWhenServiceDataResultHasNoData() throws {
        let device = StandByPairedDevice(
            iphoneDeviceId: "iphone-standby-1",
            displayName: "StandBy Test iPhone",
            publicKeyX963Representation: P256.Signing.PrivateKey().publicKey.x963Representation,
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: standbyHTTPDate("2026-04-27T14:05:00Z"),
            lastSeenAt: standbyHTTPDate("2026-04-27T14:06:00Z"),
            highestAcceptedCounter: 5
        )
        let encodedDevice = try JSONEncoder().encode(device)
        let client = StubStandByPairedDeviceSecItemClient(
            serviceDataResult: [
                [kSecAttrAccount as String: device.iphoneDeviceId]
            ],
            attributesResult: [
                [kSecAttrAccount as String: device.iphoneDeviceId]
            ],
            devicesByAccount: [device.iphoneDeviceId: encodedDevice]
        )
        let store = StandByPairedDeviceStore(
            service: "FacePass.StandByPairedDeviceStoreTests.\(UUID().uuidString)",
            secItemClient: client
        )

        let current = try XCTUnwrap(store.currentPairedDevice())

        XCTAssertEqual(current, device)
        XCTAssertEqual(client.serviceDataQueryCount, 1)
        XCTAssertEqual(client.attributeQueryCount, 1)
        XCTAssertEqual(client.accountDataQueries, [device.iphoneDeviceId])
    }

    func testCurrentPairedDeviceFallsBackToAccountLookupWhenAggregateDataQueryFindsNoItems() throws {
        let device = StandByPairedDevice(
            iphoneDeviceId: "iphone-standby-aggregate-miss",
            displayName: "Aggregate Miss iPhone",
            publicKeyX963Representation: P256.Signing.PrivateKey().publicKey.x963Representation,
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: standbyHTTPDate("2026-04-27T14:05:00Z"),
            lastSeenAt: standbyHTTPDate("2026-04-27T14:06:00Z"),
            highestAcceptedCounter: 5
        )
        let encodedDevice = try JSONEncoder().encode(device)
        let client = StubStandByPairedDeviceSecItemClient(
            serviceDataResult: nil,
            attributesResult: [
                [kSecAttrAccount as String: device.iphoneDeviceId]
            ],
            devicesByAccount: [device.iphoneDeviceId: encodedDevice]
        )
        let store = StandByPairedDeviceStore(
            service: "FacePass.StandByPairedDeviceStoreTests.\(UUID().uuidString)",
            secItemClient: client
        )

        let current = try XCTUnwrap(store.currentPairedDevice())

        XCTAssertEqual(current, device)
        XCTAssertEqual(client.serviceDataQueryCount, 1)
        XCTAssertEqual(client.attributeQueryCount, 1)
        XCTAssertEqual(client.accountDataQueries, [device.iphoneDeviceId])
    }

    func testCurrentPairedDeviceIgnoresMalformedAggregateRecordsWhenValidDeviceExists() throws {
        let device = StandByPairedDevice(
            iphoneDeviceId: "iphone-standby-1",
            displayName: "Visible Settings iPhone",
            publicKeyX963Representation: P256.Signing.PrivateKey().publicKey.x963Representation,
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: standbyHTTPDate("2026-04-27T14:05:00Z"),
            lastSeenAt: standbyHTTPDate("2026-04-27T14:06:00Z"),
            highestAcceptedCounter: 5
        )
        let encodedDevice = try JSONEncoder().encode(device)
        let client = StubStandByPairedDeviceSecItemClient(
            serviceDataResult: [
                Data("legacy-or-malformed-pairing-record".utf8),
                encodedDevice
            ],
            attributesResult: nil,
            devicesByAccount: [:]
        )
        let store = StandByPairedDeviceStore(
            service: "FacePass.StandByPairedDeviceStoreTests.\(UUID().uuidString)",
            secItemClient: client
        )

        let current = try XCTUnwrap(store.currentPairedDevice())

        XCTAssertEqual(current, device)
        XCTAssertEqual(client.serviceDataQueryCount, 1)
        XCTAssertEqual(client.attributeQueryCount, 0)
        XCTAssertEqual(client.accountDataQueries, [])
    }

    func testCurrentPairedDeviceFallsBackPastMalformedAccountRecord() throws {
        let validDevice = StandByPairedDevice(
            iphoneDeviceId: "iphone-standby-valid",
            displayName: "Settings Visible iPhone",
            publicKeyX963Representation: P256.Signing.PrivateKey().publicKey.x963Representation,
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: standbyHTTPDate("2026-04-27T14:07:00Z"),
            lastSeenAt: standbyHTTPDate("2026-04-27T14:08:00Z"),
            highestAcceptedCounter: 9
        )
        let client = StubStandByPairedDeviceSecItemClient(
            serviceDataResult: [
                Data("legacy-or-malformed-pairing-record".utf8)
            ],
            attributesResult: [
                [kSecAttrAccount as String: "iphone-standby-malformed"],
                [kSecAttrAccount as String: validDevice.iphoneDeviceId]
            ],
            devicesByAccount: [
                "iphone-standby-malformed": Data("malformed-account-record".utf8),
                validDevice.iphoneDeviceId: try JSONEncoder().encode(validDevice)
            ]
        )
        let store = StandByPairedDeviceStore(
            service: "FacePass.StandByPairedDeviceStoreTests.\(UUID().uuidString)",
            secItemClient: client
        )

        let current = try XCTUnwrap(store.currentPairedDevice())

        XCTAssertEqual(current, validDevice)
        XCTAssertEqual(client.serviceDataQueryCount, 1)
        XCTAssertEqual(client.attributeQueryCount, 1)
        XCTAssertEqual(client.accountDataQueries, [
            "iphone-standby-malformed",
            validDevice.iphoneDeviceId
        ])
    }

    func testExpiredOneTimeTokenDoesNotStorePairedDevice() throws {
        let privateKey = P256.Signing.PrivateKey()
        var now = standbyHTTPDate("2026-04-27T14:05:00Z")
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: store,
            clock: { now },
            tokenGenerator: { "one-time-token" },
            pairingSessionTTL: 60
        )
        let session = controller.startPairingSession()

        now = standbyHTTPDate("2026-04-27T14:06:01Z")

        XCTAssertThrowsError(
            try controller.registerIPhone(
                StandByIPhonePairingRegistration(
                    oneTimeToken: session.oneTimeToken,
                    iphoneDeviceId: "iphone-standby-1",
                    displayName: "StandBy Test iPhone",
                    publicKeyX963Representation: privateKey.publicKey.x963Representation
                )
            )
        ) { error in
            XCTAssertEqual(error as? StandByUnlockPairingError, .expiredOneTimeToken)
        }

        XCTAssertNil(try store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
        XCTAssertNil(try store.currentPairedDevice())
    }

    func testFailedTokenDoesNotStorePairedDevice() throws {
        let privateKey = P256.Signing.PrivateKey()
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = makePairingController(store: store)
        _ = controller.startPairingSession()

        XCTAssertThrowsError(
            try controller.registerIPhone(
                StandByIPhonePairingRegistration(
                    oneTimeToken: "wrong-token",
                    iphoneDeviceId: "iphone-standby-1",
                    displayName: "StandBy Test iPhone",
                    publicKeyX963Representation: privateKey.publicKey.x963Representation
                )
            )
        ) { error in
            XCTAssertEqual(error as? StandByUnlockPairingError, .invalidOneTimeToken)
        }

        XCTAssertNil(try store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
    }

    func testInvalidRegistrationConsumesCurrentOneTimeToken() throws {
        let privateKey = P256.Signing.PrivateKey()
        let store = InMemoryStandByHTTPPairedDeviceStore()
        let controller = makePairingController(store: store)
        let session = controller.startPairingSession()

        XCTAssertThrowsError(
            try controller.registerIPhone(
                StandByIPhonePairingRegistration(
                    oneTimeToken: session.oneTimeToken,
                    iphoneDeviceId: "iphone-standby-1",
                    displayName: "StandBy Test iPhone",
                    publicKeyX963Representation: Data("not-a-public-key".utf8)
                )
            )
        ) { error in
            XCTAssertEqual(error as? StandByUnlockPairingError, .invalidPublicKey)
        }

        XCTAssertThrowsError(
            try controller.registerIPhone(
                StandByIPhonePairingRegistration(
                    oneTimeToken: session.oneTimeToken,
                    iphoneDeviceId: "iphone-standby-1",
                    displayName: "StandBy Test iPhone",
                    publicKeyX963Representation: privateKey.publicKey.x963Representation
                )
            )
        ) { error in
            XCTAssertEqual(error as? StandByUnlockPairingError, .invalidOneTimeToken)
        }
        XCTAssertNil(try store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
    }

    func testConcurrentRegistrationsCannotBothConsumeSameOneTimeToken() throws {
        let firstPrivateKey = P256.Signing.PrivateKey()
        let secondPrivateKey = P256.Signing.PrivateKey()
        let store = BlockingFirstReplacePairedDeviceStore()
        let controller = StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: store,
            clock: { standbyHTTPDate("2026-04-27T14:05:00Z") },
            tokenGenerator: { "one-time-token" }
        )
        let session = controller.startPairingSession()
        let firstRegistration = StandByIPhonePairingRegistration(
            oneTimeToken: session.oneTimeToken,
            iphoneDeviceId: "iphone-standby-1",
            displayName: "First iPhone",
            publicKeyX963Representation: firstPrivateKey.publicKey.x963Representation
        )
        let secondRegistration = StandByIPhonePairingRegistration(
            oneTimeToken: session.oneTimeToken,
            iphoneDeviceId: "iphone-standby-2",
            displayName: "Second iPhone",
            publicKeyX963Representation: secondPrivateKey.publicKey.x963Representation
        )
        let resultRecorder = PairingResultRecorder()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            resultRecorder.record {
                _ = try controller.registerIPhone(firstRegistration)
            }
            group.leave()
        }

        XCTAssertEqual(store.waitUntilFirstReplaceStarted(), .success)

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            resultRecorder.record {
                _ = try controller.registerIPhone(secondRegistration)
            }
            group.leave()
        }

        XCTAssertEqual(resultRecorder.waitForResultCount(1), .success)
        store.releaseFirstReplace()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        let results = resultRecorder.results
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter(\.isSuccess).count, 1)
        XCTAssertEqual(results.compactMap(\.pairingError), [.invalidOneTimeToken])
        XCTAssertEqual(store.replaceCallCount, 1)
    }

    private func makePairingController(store: InMemoryStandByHTTPPairedDeviceStore) -> StandByUnlockPairingController {
        StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: store,
            clock: { standbyHTTPDate("2026-04-27T14:05:00Z") },
            tokenGenerator: { "one-time-token" }
        )
    }
}

class InMemoryStandByHTTPPairedDeviceStore: StandByPairedDeviceStoring {
    private let lock = NSLock()
    private var devices: [String: StandByPairedDevice] = [:]

    func pairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws -> StandByPairedDevice? {
        lock.withLock {
            devices[iphoneDeviceId]
        }
    }

    func currentPairedDevice() throws -> StandByPairedDevice? {
        lock.withLock {
            devices.values.sorted { $0.createdAt > $1.createdAt }.first
        }
    }

    func savePairedDevice(_ device: StandByPairedDevice) throws {
        lock.withLock {
            devices[device.iphoneDeviceId] = device
        }
    }

    func replacePairedDevice(_ device: StandByPairedDevice) throws {
        lock.withLock {
            devices = [device.iphoneDeviceId: device]
        }
    }

    func deletePairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws {
        lock.withLock {
            devices[iphoneDeviceId] = nil
        }
    }

    func deleteAllPairedDevices() throws {
        lock.withLock {
            devices.removeAll()
        }
    }
}

private final class BlockingFirstReplacePairedDeviceStore: InMemoryStandByHTTPPairedDeviceStore {
    private let stateLock = NSLock()
    private let firstReplaceStarted = DispatchSemaphore(value: 0)
    private let releaseFirstReplaceSemaphore = DispatchSemaphore(value: 0)
    private var shouldBlockNextReplace = true
    private var _replaceCallCount = 0

    var replaceCallCount: Int {
        stateLock.withLock {
            _replaceCallCount
        }
    }

    override func replacePairedDevice(_ device: StandByPairedDevice) throws {
        let shouldBlock = stateLock.withLock {
            _replaceCallCount += 1
            if shouldBlockNextReplace {
                shouldBlockNextReplace = false
                return true
            }
            return false
        }

        if shouldBlock {
            firstReplaceStarted.signal()
            _ = releaseFirstReplaceSemaphore.wait(timeout: .now() + 2)
        }

        try super.replacePairedDevice(device)
    }

    func waitUntilFirstReplaceStarted() -> DispatchTimeoutResult {
        firstReplaceStarted.wait(timeout: .now() + 2)
    }

    func releaseFirstReplace() {
        releaseFirstReplaceSemaphore.signal()
    }
}

private final class StubStandByPairedDeviceSecItemClient: StandByPairedDeviceSecItemClient {
    private let lock = NSLock()
    private let serviceDataResult: Any?
    private let attributesResult: Any?
    private let devicesByAccount: [String: Data]
    private(set) var serviceDataQueryCount = 0
    private(set) var attributeQueryCount = 0
    private(set) var accountDataQueries: [String] = []

    init(
        serviceDataResult: Any?,
        attributesResult: Any?,
        devicesByAccount: [String: Data]
    ) {
        self.serviceDataResult = serviceDataResult
        self.attributesResult = attributesResult
        self.devicesByAccount = devicesByAccount
    }

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.withLock {
            let query = query as NSDictionary

            if let account = query[kSecAttrAccount] as? String {
                accountDataQueries.append(account)
                guard let data = devicesByAccount[account] else {
                    return errSecItemNotFound
                }

                result?.pointee = data as CFTypeRef
                return errSecSuccess
            }

            if (query[kSecReturnAttributes] as? Bool) == true {
                attributeQueryCount += 1
                result?.pointee = attributesResult as CFTypeRef?
                return attributesResult == nil ? errSecItemNotFound : errSecSuccess
            }

            serviceDataQueryCount += 1
            result?.pointee = serviceDataResult as CFTypeRef?
            return serviceDataResult == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        errSecSuccess
    }
}

private final class PairingResultRecorder {
    private let lock = NSLock()
    private let resultRecorded = DispatchSemaphore(value: 0)
    private var _results: [PairingRegistrationOutcome] = []

    var results: [PairingRegistrationOutcome] {
        lock.withLock {
            _results
        }
    }

    func record(_ body: () throws -> Void) {
        let outcome: PairingRegistrationOutcome
        do {
            try body()
            outcome = .success
        } catch let error as StandByUnlockPairingError {
            outcome = .failure(error)
        } catch {
            outcome = .unexpectedFailure
        }

        lock.withLock {
            _results.append(outcome)
        }
        resultRecorded.signal()
    }

    func waitForResultCount(_ count: Int) -> DispatchTimeoutResult {
        while true {
            if results.count >= count {
                return .success
            }
            if resultRecorded.wait(timeout: .now() + 2) == .timedOut {
                return .timedOut
            }
        }
    }
}

private enum PairingRegistrationOutcome: Equatable {
    case success
    case failure(StandByUnlockPairingError)
    case unexpectedFailure

    var isSuccess: Bool {
        self == .success
    }

    var pairingError: StandByUnlockPairingError? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension JSONEncoder {
    static var standbyHTTP: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }
}

func standbyHTTPDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }
    return date
}
