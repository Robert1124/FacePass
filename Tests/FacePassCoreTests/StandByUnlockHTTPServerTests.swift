import Foundation
import XCTest
@testable import FacePassCore

final class StandByUnlockHTTPServerTests: XCTestCase {
    @MainActor
    func testStatusEndpointReturnsPublicStandByStateWithoutSecrets() async throws {
        let secret = "standby-http-secret-\(UUID().uuidString)"
        let router = StandByUnlockHTTPRouter(
            macDeviceId: "mac-facepass-1",
            protocolVersion: 1,
            serverStatus: .ready,
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            isIPhoneUnlockEnabled: { true },
            pairingController: makePairingController(),
            unlockHandler: { _ in
                XCTFail("GET /v1/status must not run unlock handling")
                return StandByUnlockAttemptStatus.unlockResult(.typingFailed)
            }
        )

        let response = await router.handle(
            StandByHTTPServerRequest(method: "GET", path: "/v1/status", body: nil)
        )
        let json = try decodeJSONObject(from: response.body)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(json["macDeviceId"] as? String, "mac-facepass-1")
        XCTAssertEqual(json["protocolVersion"] as? Int, 1)
        XCTAssertEqual(json["serverStatus"] as? String, "ready")
        XCTAssertEqual(json["publicKeyFingerprint"] as? String, "SHA256:public-key-fingerprint")
        XCTAssertEqual(json["whetherIPhoneUnlockEnabled"] as? Bool, true)
        XCTAssertFalse(response.bodyString.contains(secret))
        XCTAssertFalse(response.bodyString.localizedCaseInsensitiveContains("password"))
    }

    @MainActor
    func testStandByUnlockEndpointMapsVerificationAndLocalGateFailuresToStableErrorCodes() async throws {
        let cases: [(name: String, status: StandByUnlockAttemptStatus, expectedCode: String)] = [
            ("unpaired iPhone", .verificationFailed(.unpairedIPhone), "not_paired"),
            ("disabled paired iPhone", .verificationFailed(.disabledIPhone), "disabled"),
            ("invalid signature", .verificationFailed(.invalidSignature), "invalid_signature"),
            ("expired request", .verificationFailed(.expiredRequest), "expired"),
            ("replayed request id", .verificationFailed(.replayedRequestId), "replay_detected"),
            ("wrong Mac", .verificationFailed(.wrongMacDevice), "wrong_mac"),
            ("Mac not locked", .unlockResult(.sessionNotLocked), "mac_not_locked"),
            ("missing password", .unlockResult(.missingPassword), "password_missing"),
            ("unlock failed", .unlockResult(.typingFailed), "unlock_failed"),
            ("network or replay store failure", .verificationFailed(.replayStoreFailed), "network_error")
        ]

        for testCase in cases {
            let router = StandByUnlockHTTPRouter(
                macDeviceId: "mac-facepass-1",
                protocolVersion: 1,
                serverStatus: .ready,
                publicKeyFingerprint: "SHA256:public-key-fingerprint",
                isIPhoneUnlockEnabled: { true },
                pairingController: makePairingController(),
                unlockHandler: { _ in testCase.status }
            )

            let response = await router.handle(
                StandByHTTPServerRequest(
                    method: "POST",
                    path: "/v1/standby-unlock",
                    body: try standbyUnlockRequestBody(requestId: testCase.name)
                )
            )
            let json = try decodeJSONObject(from: response.body)

            XCTAssertEqual(response.statusCode, 403, testCase.name)
            XCTAssertEqual(json["ok"] as? Bool, false, testCase.name)
            XCTAssertEqual(json["errorCode"] as? String, testCase.expectedCode, testCase.name)
            XCTAssertFalse(response.bodyString.contains("standby-http-secret"), testCase.name)
            XCTAssertFalse(response.bodyString.contains("password-value"), testCase.name)
        }
    }

    @MainActor
    func testPairEndpointMapsExpiredOneTimeTokenToStableErrorCode() async throws {
        var now = standbyHTTPDate("2026-04-27T14:05:00Z")
        let pairingController = StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: InMemoryStandByHTTPPairedDeviceStore(),
            clock: { now },
            tokenGenerator: { "one-time-token" },
            pairingSessionTTL: 60
        )
        let session = pairingController.startPairingSession()
        now = standbyHTTPDate("2026-04-27T14:06:01Z")
        let router = StandByUnlockHTTPRouter(
            macDeviceId: "mac-facepass-1",
            protocolVersion: 1,
            serverStatus: .ready,
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            isIPhoneUnlockEnabled: { true },
            pairingController: pairingController,
            unlockHandler: { _ in
                XCTFail("POST /v1/pair must not run unlock handling")
                return StandByUnlockAttemptStatus.unlockResult(.typingFailed)
            }
        )
        let registration = StandByIPhonePairingRegistration(
            oneTimeToken: session.oneTimeToken,
            iphoneDeviceId: "iphone-standby-1",
            displayName: "StandBy Test iPhone",
            publicKeyX963Representation: Data("not-needed-for-expired-token".utf8)
        )

        let response = await router.handle(
            StandByHTTPServerRequest(
                method: "POST",
                path: "/v1/pair",
                body: try JSONEncoder.standbyHTTP.encode(registration)
            )
        )
        let json = try decodeJSONObject(from: response.body)

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["errorCode"] as? String, "expired_token")
        XCTAssertFalse(response.bodyString.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(response.bodyString.contains(session.oneTimeToken))
    }

    @MainActor
    func testStandByUnlockEndpointReturnsSuccessWithoutPasswordMaterial() async throws {
        let secret = "password-value-\(UUID().uuidString)"
        let router = StandByUnlockHTTPRouter(
            macDeviceId: "mac-facepass-1",
            protocolVersion: 1,
            serverStatus: .ready,
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            isIPhoneUnlockEnabled: { true },
            pairingController: makePairingController(),
            unlockHandler: { _ in StandByUnlockAttemptStatus.unlockResult(.typedPasswordAndSubmitted) }
        )

        let response = await router.handle(
            StandByHTTPServerRequest(
                method: "POST",
                path: "/v1/standby-unlock",
                body: try standbyUnlockRequestBody(requestId: secret)
            )
        )
        let json = try decodeJSONObject(from: response.body)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["result"] as? String, "unlock_requested")
        XCTAssertFalse(response.bodyString.contains(secret))
        XCTAssertFalse(response.bodyString.localizedCaseInsensitiveContains("password"))
    }

    func testPreferredLANIPv4AddressUsesDefaultRouteBeforeVirtualPrivateInterface() {
        let candidates = [
            StandByLocalIPv4Address(interfaceName: "feth4942", host: "192.168.192.56"),
            StandByLocalIPv4Address(interfaceName: "en0", host: "192.168.4.204"),
            StandByLocalIPv4Address(interfaceName: "en10", host: "192.168.4.215")
        ]

        let host = StandByLocalEndpointSelector.preferredHost(
            from: candidates,
            defaultRouteInterface: "en10"
        )

        XCTAssertEqual(host, "192.168.4.215")
    }

    func testPreferredLANIPv4AddressFallsBackToPhysicalPrivateInterfaceBeforeVirtualInterface() {
        let candidates = [
            StandByLocalIPv4Address(interfaceName: "feth4942", host: "192.168.192.56"),
            StandByLocalIPv4Address(interfaceName: "en0", host: "192.168.4.204")
        ]

        let host = StandByLocalEndpointSelector.preferredHost(
            from: candidates,
            defaultRouteInterface: nil
        )

        XCTAssertEqual(host, "192.168.4.204")
    }

    private func makePairingController(
        pairedDeviceStore: InMemoryStandByHTTPPairedDeviceStore = InMemoryStandByHTTPPairedDeviceStore()
    ) -> StandByUnlockPairingController {
        StandByUnlockPairingController(
            macDeviceId: "mac-facepass-1",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            pairedDeviceStore: pairedDeviceStore,
            clock: { standbyHTTPDate("2026-04-27T14:05:00Z") },
            tokenGenerator: { "one-time-token" }
        )
    }
}

func standbyUnlockRequestBody(requestId: String) throws -> Data {
    try JSONEncoder.standbyHTTP.encode(
        StandByUnlockRequest(
            type: "standby_unlock_request",
            protocolVersion: 1,
            requestId: requestId,
            iphoneDeviceId: "iphone-standby-1",
            macDeviceId: "mac-facepass-1",
            action: "unlock_screen",
            issuedAt: standbyHTTPDate("2026-04-27T14:04:30Z"),
            expiresAt: standbyHTTPDate("2026-04-27T14:05:30Z"),
            counter: 8,
            signature: Data("test-signature".utf8)
        )
    )
}

func decodeJSONObject(from data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let json = object as? [String: Any] else {
        XCTFail("Expected response body to be a JSON object")
        return [:]
    }
    return json
}

extension StandByHTTPServerResponse {
    var bodyString: String {
        String(decoding: body, as: UTF8.self)
    }
}
