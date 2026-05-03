import Foundation
import XCTest
@testable import FacePassCore

final class StandByUnlockCanonicalizerTests: XCTestCase {
    func testCanonicalPayloadIsStableAndExcludesSignature() throws {
        let request = makeRequest(signature: Data("first-signature".utf8))
        let sameRequestWithDifferentSignature = makeRequest(signature: Data("second-signature".utf8))

        let canonicalPayload = try StandByUnlockCanonicalizer.canonicalPayload(for: request)
        let payloadWithDifferentSignature = try StandByUnlockCanonicalizer.canonicalPayload(
            for: sameRequestWithDifferentSignature
        )

        XCTAssertEqual(canonicalPayload, payloadWithDifferentSignature)
        XCTAssertEqual(
            String(decoding: canonicalPayload, as: UTF8.self),
            """
            {"action":"unlock_screen","counter":7,"expiresAt":"2026-04-27T14:05:00Z","issuedAt":"2026-04-27T14:04:30Z","iphoneDeviceId":"iphone-standby-1","macDeviceId":"mac-facepass-1","protocolVersion":1,"requestId":"standby-request-1","type":"standby_unlock_request"}
            """
        )
        XCTAssertFalse(String(decoding: canonicalPayload, as: UTF8.self).contains("signature"))
        XCTAssertFalse(String(decoding: canonicalPayload, as: UTF8.self).contains("first-signature"))
        XCTAssertFalse(String(decoding: canonicalPayload, as: UTF8.self).contains("second-signature"))
    }

    func testCanonicalPayloadChangesWhenSignedFieldsChange() throws {
        let baseline = makeRequest(counter: 7, signature: Data("signature".utf8))
        let changedCounter = makeRequest(counter: 8, signature: Data("signature".utf8))

        let baselinePayload = try StandByUnlockCanonicalizer.canonicalPayload(for: baseline)
        let changedPayload = try StandByUnlockCanonicalizer.canonicalPayload(for: changedCounter)

        XCTAssertNotEqual(baselinePayload, changedPayload)
    }

    func testCanonicalPayloadRejectsWrongProtocolType() {
        let request = makeRequest(type: "ordinary_password_fill", signature: nil)

        XCTAssertThrowsError(try StandByUnlockCanonicalizer.canonicalPayload(for: request)) { error in
            XCTAssertEqual(error as? StandByUnlockCanonicalizationError, .unsupportedType)
            XCTAssertFalse(String(describing: error).contains("password"))
        }
    }

    private func makeRequest(
        type: String = "standby_unlock_request",
        protocolVersion: Int = 1,
        requestId: String = "standby-request-1",
        iphoneDeviceId: String = "iphone-standby-1",
        macDeviceId: String = "mac-facepass-1",
        action: String = "unlock_screen",
        issuedAt: Date = standbyDate("2026-04-27T14:04:30Z"),
        expiresAt: Date = standbyDate("2026-04-27T14:05:00Z"),
        counter: UInt64 = 7,
        signature: Data?
    ) -> StandByUnlockRequest {
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

private func standbyDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }
    return date
}
