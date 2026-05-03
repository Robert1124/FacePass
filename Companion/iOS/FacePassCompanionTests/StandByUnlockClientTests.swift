import Darwin
import Foundation
import XCTest
@testable import FacePassCompanionCore

final class StandByUnlockClientTests: XCTestCase {
    func testPairingPayloadDecodesOptionalLocalEndpointFromQRCode() throws {
        let data = """
        {
          "type": "facepass_standby_pairing",
          "protocolVersion": 1,
          "macDeviceId": "mac-facepass-1",
          "publicKeyFingerprint": "SHA256:public-key-fingerprint",
          "oneTimeToken": "one-time-token",
          "bonjourServiceType": "_facepass._tcp",
          "bonjourDomain": "local",
          "expiresAt": "2026-04-27T14:10:00Z",
          "localEndpoint": {
            "host": "192.168.4.204",
            "port": 65508,
            "scheme": "http",
            "url": "http://192.168.4.204:65508"
          }
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(PairingQRCodePayload.self, from: data)

        XCTAssertEqual(payload.localEndpoint, MacEndpoint(host: "192.168.4.204", port: 65508, scheme: "http"))
    }

    func testPairingUsesQRCodeEndpointBeforeBonjourRediscovery() async throws {
        let payload = makePairingPayload(
            localEndpoint: MacEndpoint(host: "192.168.4.204", port: 65508, scheme: "http")
        )
        let cache = FakeEndpointCache(mac: nil)
        let rediscovery = FakePairingRediscovery(endpoint: MacEndpoint(host: "192.168.4.205", port: 65508, scheme: "http"))
        let transport = CapturingStandByUnlockTransport(
            response: #"{"ok":true,"result":"paired","iphoneDeviceId":"iphone-standby-1","displayName":"Test iPhone"}"#.data(using: .utf8)!
        )
        let client = PairingClient(
            endpointCache: cache,
            rediscoveryService: rediscovery,
            keyStore: FakeKeyStore(),
            clock: { standbyClientDate("2026-04-27T14:05:00Z") },
            transport: transport
        )

        let mac = try await client.pair(with: payload)

        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://192.168.4.204:65508/v1/pair"
        ])
        XCTAssertEqual(rediscovery.requestedMacDeviceIds, [])
        XCTAssertEqual(mac.cachedEndpoint, payload.localEndpoint)
        XCTAssertEqual(cache.savedMacs.last?.cachedEndpoint, payload.localEndpoint)
    }

    func testPairingFallsBackToBonjourWhenQRCodeEndpointIsUnreachable() async throws {
        let payload = makePairingPayload(
            localEndpoint: MacEndpoint(host: "192.168.4.204", port: 65508, scheme: "http")
        )
        let cache = FakeEndpointCache(mac: nil)
        let rediscoveredEndpoint = MacEndpoint(host: "192.168.4.205", port: 65508, scheme: "http")
        let rediscovery = FakePairingRediscovery(endpoint: rediscoveredEndpoint)
        let transport = CapturingStandByUnlockTransport(
            response: #"{"ok":true,"result":"paired","iphoneDeviceId":"iphone-standby-1","displayName":"Test iPhone"}"#.data(using: .utf8)!,
            failuresBeforeSuccess: 1
        )
        let client = PairingClient(
            endpointCache: cache,
            rediscoveryService: rediscovery,
            keyStore: FakeKeyStore(),
            clock: { standbyClientDate("2026-04-27T14:05:00Z") },
            transport: transport
        )

        let mac = try await client.pair(with: payload)

        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://192.168.4.204:65508/v1/pair",
            "http://192.168.4.205:65508/v1/pair"
        ])
        XCTAssertEqual(rediscovery.requestedMacDeviceIds, ["mac-facepass-1"])
        XCTAssertEqual(mac.cachedEndpoint, rediscoveredEndpoint)
        XCTAssertEqual(cache.savedMacs.last?.cachedEndpoint, rediscoveredEndpoint)
    }

    func testRequestUnlockBuildsSignedBodyForCachedEndpoint() async throws {
        let mac = PairedMac(
            macDeviceId: "mac-facepass-1",
            displayName: "Office Mac",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            cachedEndpoint: MacEndpoint(host: "127.0.0.1", port: 45000, scheme: "http"),
            bonjourServiceName: nil,
            pairedAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: nil
        )
        let cache = FakeEndpointCache(mac: mac)
        let transport = CapturingStandByUnlockTransport(
            response: #"{"ok":true,"result":"unlock_requested"}"#.data(using: .utf8)!
        )
        let client = StandByUnlockClient(
            endpointCache: cache,
            rediscoveryService: FakeRediscovery(endpoint: nil),
            keyStore: FakeKeyStore(),
            counterStore: FakeCounterStore(),
            clock: { standbyClientDate("2026-04-27T14:04:30Z") },
            requestIdGenerator: { "standby-request-1" },
            transport: transport
        )

        let result = try await client.requestUnlock()

        XCTAssertEqual(result, StandByUnlockResult(ok: true, result: "unlock_requested", errorCode: nil))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "http://127.0.0.1:45000/v1/standby-unlock")
        let body = try XCTUnwrap(transport.requests[0].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "standby_unlock_request")
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object["requestId"] as? String, "standby-request-1")
        XCTAssertEqual(object["iphoneDeviceId"] as? String, "iphone-standby-1")
        XCTAssertEqual(object["macDeviceId"] as? String, "mac-facepass-1")
        XCTAssertEqual(object["action"] as? String, "unlock_screen")
        XCTAssertEqual(object["issuedAt"] as? String, "2026-04-27T14:04:30Z")
        XCTAssertEqual(object["expiresAt"] as? String, "2026-04-27T14:04:40Z")
        XCTAssertEqual(object["counter"] as? Int, 1)
        XCTAssertEqual(object["signature"] as? String, Data("signed-payload".utf8).base64EncodedString())
    }

    func testRequestUnlockRetriesOnceAfterRediscoveryWhenCachedEndpointFails() async throws {
        let mac = PairedMac(
            macDeviceId: "mac-facepass-1",
            displayName: "Office Mac",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            cachedEndpoint: MacEndpoint(host: "192.0.2.10", port: 45000, scheme: "http"),
            bonjourServiceName: nil,
            pairedAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: nil
        )
        let cache = FakeEndpointCache(mac: mac)
        let transport = CapturingStandByUnlockTransport(
            response: #"{"ok":true,"result":"unlock_requested"}"#.data(using: .utf8)!,
            failuresBeforeSuccess: 1
        )
        let rediscovery = FakeRediscovery(
            endpoint: MacEndpoint(host: "127.0.0.1", port: 45001, scheme: "http")
        )
        var requestIds = ["standby-request-1", "standby-request-2"][...]
        let client = StandByUnlockClient(
            endpointCache: cache,
            rediscoveryService: rediscovery,
            keyStore: FakeKeyStore(),
            counterStore: FakeCounterStore(),
            clock: { standbyClientDate("2026-04-27T14:04:30Z") },
            requestIdGenerator: { requestIds.removeFirst() },
            transport: transport
        )

        let result = try await client.requestUnlock()

        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://192.0.2.10:45000/v1/standby-unlock",
            "http://127.0.0.1:45001/v1/standby-unlock"
        ])
        let firstBody = try XCTUnwrap(transport.requests[0].httpBody)
        let secondBody = try XCTUnwrap(transport.requests[1].httpBody)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        XCTAssertEqual(firstObject["requestId"] as? String, "standby-request-1")
        XCTAssertEqual(secondObject["requestId"] as? String, "standby-request-2")
        XCTAssertEqual(firstObject["counter"] as? Int, 1)
        XCTAssertEqual(secondObject["counter"] as? Int, 2)
        XCTAssertEqual(rediscovery.requestedTimeouts, [.seconds(8)])
        XCTAssertEqual(cache.savedMacs.last?.cachedEndpoint, MacEndpoint(host: "127.0.0.1", port: 45001, scheme: "http"))
        XCTAssertNotNil(cache.savedMacs.last?.lastSeenAt)
    }

    func testRequestUnlockFallsBackToNearbyPortProbeWhenBonjourRediscoveryTimesOut() async throws {
        let mac = PairedMac(
            macDeviceId: "mac-facepass-1",
            displayName: "Office Mac",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            cachedEndpoint: MacEndpoint(host: "192.168.4.204", port: 49155, scheme: "http"),
            bonjourServiceName: nil,
            pairedAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: nil
        )
        let cache = FakeEndpointCache(mac: mac)
        let transport = RoutingStandByUnlockTransport { request in
            switch request.url?.absoluteString {
            case "http://192.168.4.204:49155/v1/standby-unlock":
                throw URLError(.cannotConnectToHost)
            case "http://192.168.4.204:49156/v1/status":
                return #"{"macDeviceId":"mac-facepass-1","protocolVersion":1,"publicKeyFingerprint":"SHA256:public-key-fingerprint","serverStatus":"ready","whetherIPhoneUnlockEnabled":true}"#.data(using: .utf8)!
            case "http://192.168.4.204:49156/v1/standby-unlock":
                return #"{"ok":true,"result":"unlock_requested"}"#.data(using: .utf8)!
            default:
                throw URLError(.cannotConnectToHost)
            }
        }
        let rediscovery = FakeRediscovery(endpoint: nil, error: BonjourRediscoveryError.timeout)
        var requestIds = ["standby-request-1", "standby-request-2"][...]
        let client = StandByUnlockClient(
            endpointCache: cache,
            rediscoveryService: rediscovery,
            keyStore: FakeKeyStore(),
            counterStore: FakeCounterStore(),
            clock: { standbyClientDate("2026-04-27T14:04:30Z") },
            requestIdGenerator: { requestIds.removeFirst() },
            transport: transport
        )

        let result = try await client.requestUnlock()

        XCTAssertEqual(result, StandByUnlockResult(ok: true, result: "unlock_requested", errorCode: nil))
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://192.168.4.204:49155/v1/standby-unlock",
            "http://192.168.4.204:49156/v1/status",
            "http://192.168.4.204:49156/v1/standby-unlock"
        ])
        XCTAssertEqual(cache.savedMacs.last?.cachedEndpoint, MacEndpoint(host: "192.168.4.204", port: 49156, scheme: "http"))
    }

    func testBonjourRediscoveryPrefersResolvedIPv4AddressOverLocalHostname() throws {
        let host = BonjourResolvedEndpointHostSelector.resolvedHost(
            hostName: "Yiwens-MacBook-Pro-14.local.",
            addresses: [
                ipv4SocketAddressData("192.168.4.204")
            ]
        )

        XCTAssertEqual(host, "192.168.4.204")
    }

    func testBonjourRediscoveryKeepsMultipleCandidatesBeforeHostnameFallback() throws {
        let hosts = BonjourResolvedEndpointHostSelector.resolvedHosts(
            hostName: "Yiwens-MacBook-Pro-14.local.",
            addresses: [
                ipv4SocketAddressData("192.168.4.215"),
                ipv4SocketAddressData("192.168.4.204")
            ]
        )

        XCTAssertEqual(hosts, [
            "192.168.4.215",
            "192.168.4.204",
            "Yiwens-MacBook-Pro-14.local"
        ])
    }
}

private func makePairingPayload(localEndpoint: MacEndpoint?) -> PairingQRCodePayload {
    PairingQRCodePayload(
        type: PairingQRCodePayload.expectedType,
        protocolVersion: CanonicalStandByUnlockPayload.protocolVersion,
        macDeviceId: "mac-facepass-1",
        publicKeyFingerprint: "SHA256:public-key-fingerprint",
        oneTimeToken: "one-time-token",
        bonjourServiceType: "_facepass._tcp",
        bonjourDomain: "local",
        expiresAt: "2026-04-27T14:10:00Z",
        localEndpoint: localEndpoint
    )
}

private final class FakeEndpointCache: EndpointCaching {
    private var mac: PairedMac?
    var savedMacs: [PairedMac] = []

    init(mac: PairedMac?) {
        self.mac = mac
    }

    func loadPairedMac() throws -> PairedMac? {
        mac
    }

    func savePairedMac(_ mac: PairedMac) throws {
        self.mac = mac
        savedMacs.append(mac)
    }

    func clearPairedMac() throws {
        mac = nil
    }
}

private final class FakeRediscovery: BonjourRediscovering {
    let endpoint: MacEndpoint?
    let error: BonjourRediscoveryError
    private(set) var requestedTimeouts: [Duration] = []

    init(endpoint: MacEndpoint?, error: BonjourRediscoveryError = .notFound) {
        self.endpoint = endpoint
        self.error = error
    }

    func rediscoverEndpoint(for mac: PairedMac, timeout: Duration) async throws -> MacEndpoint {
        requestedTimeouts.append(timeout)
        guard let endpoint else {
            throw error
        }
        return endpoint
    }
}

private final class FakePairingRediscovery: PairingEndpointRediscovering {
    let endpoint: MacEndpoint?
    private(set) var requestedMacDeviceIds: [String] = []

    init(endpoint: MacEndpoint?) {
        self.endpoint = endpoint
    }

    func rediscoverEndpoint(
        macDeviceId: String,
        publicKeyFingerprint: String,
        timeout: Duration
    ) async throws -> MacEndpoint {
        requestedMacDeviceIds.append(macDeviceId)
        guard let endpoint else {
            throw BonjourRediscoveryError.notFound
        }
        return endpoint
    }
}

private struct FakeKeyStore: CompanionKeyStoring {
    let iphoneDeviceId = "iphone-standby-1"

    func sign(_ payload: Data) throws -> Data {
        Data("signed-payload".utf8)
    }

    func publicKeyX963Representation() throws -> Data {
        Data("public-key".utf8)
    }
}

private final class FakeCounterStore: StandByUnlockCounterStoring {
    private var next: UInt64 = 0

    func nextCounter(for macDeviceId: String) throws -> UInt64 {
        next += 1
        return next
    }
}

private final class CapturingStandByUnlockTransport: StandByUnlockTransporting {
    private let response: Data
    private var failuresRemaining: Int
    private(set) var requests: [URLRequest] = []

    init(response: Data, failuresBeforeSuccess: Int = 0) {
        self.response = response
        self.failuresRemaining = failuresBeforeSuccess
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.cannotConnectToHost)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (self.response, response)
    }
}

private final class RoutingStandByUnlockTransport: StandByUnlockTransporting {
    private let handler: (URLRequest) throws -> Data
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) throws -> Data) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let data = try handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private func standbyClientDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }
    return date
}

private func ipv4SocketAddressData(_ host: String, port: UInt16 = 0) -> Data {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, host, &address.sin_addr)

    return withUnsafeBytes(of: &address) { Data($0) }
}
