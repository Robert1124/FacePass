import Foundation
import XCTest
@testable import FacePassCompanionCore

final class CanonicalPayloadSignerTests: XCTestCase {
    func testCanonicalPayloadMatchesMacFieldOrderAndDateFormat() throws {
        let request = UnsignedStandByUnlockRequest(
            type: CanonicalStandByUnlockPayload.requestType,
            protocolVersion: CanonicalStandByUnlockPayload.protocolVersion,
            requestId: "standby-request-1",
            iphoneDeviceId: "iphone-standby-1",
            macDeviceId: "mac-facepass-1",
            action: .unlockScreen,
            issuedAt: standbyDate("2026-04-27T14:04:30Z"),
            expiresAt: standbyDate("2026-04-27T14:05:00Z"),
            counter: 7
        )

        let payload = try CanonicalStandByUnlockPayload().data(for: request)

        XCTAssertEqual(
            String(decoding: payload, as: UTF8.self),
            """
            {"action":"unlock_screen","counter":7,"expiresAt":"2026-04-27T14:05:00Z","issuedAt":"2026-04-27T14:04:30Z","iphoneDeviceId":"iphone-standby-1","macDeviceId":"mac-facepass-1","protocolVersion":1,"requestId":"standby-request-1","type":"standby_unlock_request"}
            """
        )
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("signature"))
    }

    func testStandByUnlockRequestEncodesSignatureAsBase64Data() throws {
        let request = StandByUnlockRequest(
            type: CanonicalStandByUnlockPayload.requestType,
            protocolVersion: CanonicalStandByUnlockPayload.protocolVersion,
            requestId: "standby-request-1",
            iphoneDeviceId: "iphone-standby-1",
            macDeviceId: "mac-facepass-1",
            action: .unlockScreen,
            issuedAt: standbyDate("2026-04-27T14:04:30Z"),
            expiresAt: standbyDate("2026-04-27T14:05:00Z"),
            counter: 7,
            signature: Data("test-signature".utf8)
        )

        let data = try JSONEncoder.standByUnlockRequestEncoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["signature"] as? String, Data("test-signature".utf8).base64EncodedString())
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
