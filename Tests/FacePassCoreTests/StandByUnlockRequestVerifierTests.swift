import CryptoKit
import Foundation
import XCTest
@testable import FacePassCore

final class StandByUnlockRequestVerifierTests: XCTestCase {
    func testAcceptsValidP256SignedRequestFromEnabledPairedIPhone() throws {
        let fixture = try makeSignedFixture(counter: 8)
        let replayCache = RecordingStandByReplayCache(acceptedCounter: 8)
        let verifier = makeVerifier(
            pairedDeviceStore: StubStandByPairedDeviceStore(device: fixture.device),
            replayCache: replayCache
        )

        let verified = try verifier.verify(fixture.request)

        XCTAssertEqual(verified.requestId, "standby-request-1")
        XCTAssertEqual(verified.iphoneDeviceId, "iphone-standby-1")
        XCTAssertEqual(verified.macDeviceId, "mac-facepass-1")
        XCTAssertEqual(replayCache.acceptedRequestIds, ["standby-request-1"])
        XCTAssertFalse(String(describing: verified).contains("app-state-secret"))
    }

    func testSuccessfulVerificationPersistsCounterAndLastSeenInStoringDeviceStore() throws {
        let fixture = try makeSignedFixture(requestId: "standby-request-1", counter: 8)
        let store = StoringStandByPairedDeviceStore(device: fixture.device)
        let replayCache = RecordingStandByReplayCache()
        let verifier = makeVerifier(pairedDeviceStore: store, replayCache: replayCache)

        _ = try verifier.verify(fixture.request)

        let stored = try XCTUnwrap(store.pairedDevice(forIPhoneDeviceId: "iphone-standby-1"))
        XCTAssertEqual(stored.highestAcceptedCounter, 8)
        XCTAssertEqual(stored.lastSeenAt, standbyVerifierDate("2026-04-27T14:05:00Z"))
        XCTAssertEqual(replayCache.acceptedRequestIds, ["standby-request-1"])

        let staleRequest = try signedRequest(
            privateKey: fixture.privateKey,
            requestId: "standby-request-2",
            counter: 8
        )

        XCTAssertThrowsError(try verifier.verify(staleRequest)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .staleCounter)
        }
        XCTAssertEqual(replayCache.acceptedRequestIds, ["standby-request-1"])
    }

    func testRejectsTamperedSignedField() throws {
        let fixture = try makeSignedFixture(counter: 8)
        let tampered = fixture.request.withCounter(9)
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: fixture.device))

        XCTAssertThrowsError(try verifier.verify(tampered)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .invalidSignature)
        }
    }

    func testRejectsWrongMacDeviceId() throws {
        let fixture = try makeSignedFixture(macDeviceId: "other-mac")
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: fixture.device))

        XCTAssertThrowsError(try verifier.verify(fixture.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .wrongMacDevice)
        }
    }

    func testRejectsWrongAction() throws {
        let fixture = try makeSignedFixture(action: "fill_authorization_prompt")
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: fixture.device))

        XCTAssertThrowsError(try verifier.verify(fixture.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .unsupportedAction)
            XCTAssertFalse(String(describing: error).contains("app-state-secret"))
        }
    }

    func testRejectsUnpairedIPhone() throws {
        let fixture = try makeSignedFixture(counter: 8)
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: nil))

        XCTAssertThrowsError(try verifier.verify(fixture.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .unpairedIPhone)
        }
    }

    func testRejectsDisabledIPhone() throws {
        let fixture = try makeSignedFixture(counter: 8, isDeviceEnabled: false)
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: fixture.device))

        XCTAssertThrowsError(try verifier.verify(fixture.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .disabledIPhone)
        }
    }

    func testRejectsExpiredAndFutureRequests() throws {
        let expired = try makeSignedFixture(
            issuedAt: standbyVerifierDate("2026-04-27T14:03:00Z"),
            expiresAt: standbyVerifierDate("2026-04-27T14:04:00Z")
        )
        let future = try makeSignedFixture(
            issuedAt: standbyVerifierDate("2026-04-27T14:06:01Z"),
            expiresAt: standbyVerifierDate("2026-04-27T14:06:20Z")
        )
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: expired.device))

        XCTAssertThrowsError(try verifier.verify(expired.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .expiredRequest)
        }
        XCTAssertThrowsError(try verifier.verify(future.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .futureRequest)
        }
    }

    func testRejectsExcessiveValidityWindow() throws {
        let fixture = try makeSignedFixture(
            issuedAt: standbyVerifierDate("2026-04-27T14:04:30Z"),
            expiresAt: standbyVerifierDate("2026-04-27T14:06:31Z")
        )
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: fixture.device))

        XCTAssertThrowsError(try verifier.verify(fixture.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .excessiveValidityWindow)
        }
    }

    func testRejectsRequestIdReplayAndStaleCounter() throws {
        let replayed = try makeSignedFixture(counter: 8)
        let stale = try makeSignedFixture(counter: 7)
        let replayVerifier = makeVerifier(
            pairedDeviceStore: StubStandByPairedDeviceStore(device: replayed.device),
            replayCache: RecordingStandByReplayCache(error: StandByUnlockVerificationError.replayedRequestId)
        )
        let staleVerifier = makeVerifier(
            pairedDeviceStore: StubStandByPairedDeviceStore(device: stale.device),
            replayCache: RecordingStandByReplayCache(error: StandByUnlockVerificationError.staleCounter)
        )

        XCTAssertThrowsError(try replayVerifier.verify(replayed.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .replayedRequestId)
        }
        XCTAssertThrowsError(try staleVerifier.verify(stale.request)) { error in
            XCTAssertEqual(error as? StandByUnlockVerificationError, .staleCounter)
        }
    }

    func testVerificationErrorsDoNotExposePasswordMaterial() throws {
        let secret = "app-state-secret-\(UUID().uuidString)"
        let fixture = try makeSignedFixture(requestId: secret)
        let verifier = makeVerifier(pairedDeviceStore: StubStandByPairedDeviceStore(device: nil))

        XCTAssertThrowsError(try verifier.verify(fixture.request)) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
    }

    private func makeVerifier(
        pairedDeviceStore: any StandByPairedDeviceReading,
        replayCache: RecordingStandByReplayCache = RecordingStandByReplayCache()
    ) -> StandByUnlockRequestVerifier {
        StandByUnlockRequestVerifier(
            macDeviceId: "mac-facepass-1",
            pairedDeviceStore: pairedDeviceStore,
            replayCache: replayCache,
            clock: { standbyVerifierDate("2026-04-27T14:05:00Z") },
            maximumClockSkew: 30,
            maximumValidityWindow: 60
        )
    }

    private func makeSignedFixture(
        type: String = "standby_unlock_request",
        protocolVersion: Int = 1,
        requestId: String = "standby-request-1",
        iphoneDeviceId: String = "iphone-standby-1",
        macDeviceId: String = "mac-facepass-1",
        action: String = "unlock_screen",
        issuedAt: Date = standbyVerifierDate("2026-04-27T14:04:30Z"),
        expiresAt: Date = standbyVerifierDate("2026-04-27T14:05:30Z"),
        counter: UInt64 = 8,
        isDeviceEnabled: Bool = true
    ) throws -> SignedStandByFixture {
        let privateKey = P256.Signing.PrivateKey()
        let signedRequest = try signedRequest(
            privateKey: privateKey,
            type: type,
            protocolVersion: protocolVersion,
            requestId: requestId,
            iphoneDeviceId: iphoneDeviceId,
            macDeviceId: macDeviceId,
            action: action,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            counter: counter
        )
        let device = StandByPairedDevice(
            iphoneDeviceId: iphoneDeviceId,
            displayName: "Test iPhone",
            publicKeyX963Representation: privateKey.publicKey.x963Representation,
            signingAlgorithm: .p256SHA256,
            isEnabled: isDeviceEnabled,
            createdAt: standbyVerifierDate("2026-04-27T14:00:00Z"),
            lastSeenAt: nil,
            highestAcceptedCounter: 7
        )

        return SignedStandByFixture(request: signedRequest, device: device, privateKey: privateKey)
    }

    private func signedRequest(
        privateKey: P256.Signing.PrivateKey,
        type: String = "standby_unlock_request",
        protocolVersion: Int = 1,
        requestId: String = "standby-request-1",
        iphoneDeviceId: String = "iphone-standby-1",
        macDeviceId: String = "mac-facepass-1",
        action: String = "unlock_screen",
        issuedAt: Date = standbyVerifierDate("2026-04-27T14:04:30Z"),
        expiresAt: Date = standbyVerifierDate("2026-04-27T14:05:30Z"),
        counter: UInt64 = 8
    ) throws -> StandByUnlockRequest {
        let unsignedRequest = StandByUnlockRequest(
            type: type,
            protocolVersion: protocolVersion,
            requestId: requestId,
            iphoneDeviceId: iphoneDeviceId,
            macDeviceId: macDeviceId,
            action: action,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            counter: counter,
            signature: nil
        )
        let canonicalPayload = try StandByUnlockCanonicalizer.canonicalPayload(for: unsignedRequest)
        let signature = try privateKey.signature(for: canonicalPayload).derRepresentation
        return unsignedRequest.withSignature(signature)
    }
}

private struct SignedStandByFixture {
    let request: StandByUnlockRequest
    let device: StandByPairedDevice
    let privateKey: P256.Signing.PrivateKey
}

private final class StubStandByPairedDeviceStore: StandByPairedDeviceReading {
    private let device: StandByPairedDevice?

    init(device: StandByPairedDevice?) {
        self.device = device
    }

    func pairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws -> StandByPairedDevice? {
        device?.iphoneDeviceId == iphoneDeviceId ? device : nil
    }
}

private final class StoringStandByPairedDeviceStore: StandByPairedDeviceStoring {
    private var device: StandByPairedDevice?

    init(device: StandByPairedDevice?) {
        self.device = device
    }

    func pairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws -> StandByPairedDevice? {
        device?.iphoneDeviceId == iphoneDeviceId ? device : nil
    }

    func currentPairedDevice() throws -> StandByPairedDevice? {
        device
    }

    func savePairedDevice(_ device: StandByPairedDevice) throws {
        self.device = device
    }

    func replacePairedDevice(_ device: StandByPairedDevice) throws {
        self.device = device
    }

    func deletePairedDevice(forIPhoneDeviceId iphoneDeviceId: String) throws {
        if device?.iphoneDeviceId == iphoneDeviceId {
            device = nil
        }
    }

    func deleteAllPairedDevices() throws {
        device = nil
    }
}

private final class RecordingStandByReplayCache: StandByReplayChecking {
    private let error: StandByUnlockVerificationError?
    private(set) var acceptedRequestIds: [String] = []
    private let acceptedCounter: UInt64?

    init(
        acceptedCounter: UInt64? = nil,
        error: StandByUnlockVerificationError? = nil
    ) {
        self.acceptedCounter = acceptedCounter
        self.error = error
    }

    func accept(
        requestId: String,
        counter: UInt64,
        iphoneDeviceId: String,
        expiresAt: Date
    ) throws {
        if let error {
            throw error
        }

        acceptedRequestIds.append(requestId)
        if let acceptedCounter {
            XCTAssertEqual(counter, acceptedCounter)
        }
    }
}

private extension StandByUnlockRequest {
    func withCounter(_ counter: UInt64) -> StandByUnlockRequest {
        StandByUnlockRequest(
            type: type,
            protocolVersion: protocolVersion,
            requestId: requestId,
            iphoneDeviceId: iphoneDeviceId,
            macDeviceId: macDeviceId,
            action: action,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            counter: counter,
            signature: signature
        )
    }

    func withSignature(_ signature: Data) -> StandByUnlockRequest {
        StandByUnlockRequest(
            type: type,
            protocolVersion: protocolVersion,
            requestId: requestId,
            iphoneDeviceId: iphoneDeviceId,
            macDeviceId: macDeviceId,
            action: action,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            counter: counter,
            signature: signature
        )
    }
}

private func standbyVerifierDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }
    return date
}
