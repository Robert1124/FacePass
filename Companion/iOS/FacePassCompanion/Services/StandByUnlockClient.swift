import Foundation

public protocol StandByUnlockTransporting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public final class URLSessionStandByUnlockTransport: StandByUnlockTransporting {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await urlSession.data(for: request)
    }
}

public final class StandByUnlockClient {
    private static let endpointRediscoveryTimeout: Duration = .seconds(8)

    private let endpointCache: EndpointCaching
    private let rediscoveryService: BonjourRediscovering
    private let keyStore: CompanionKeyStoring
    private let counterStore: StandByUnlockCounterStoring
    private let payloadBuilder: CanonicalStandByUnlockPayload
    private let clock: () -> Date
    private let requestIdGenerator: () -> String
    private let transport: StandByUnlockTransporting

    public init(
        endpointCache: EndpointCaching,
        rediscoveryService: BonjourRediscovering,
        keyStore: CompanionKeyStoring,
        counterStore: StandByUnlockCounterStoring,
        payloadBuilder: CanonicalStandByUnlockPayload = CanonicalStandByUnlockPayload(),
        clock: @escaping () -> Date = Date.init,
        requestIdGenerator: @escaping () -> String = { UUID().uuidString },
        transport: StandByUnlockTransporting = URLSessionStandByUnlockTransport()
    ) {
        self.endpointCache = endpointCache
        self.rediscoveryService = rediscoveryService
        self.keyStore = keyStore
        self.counterStore = counterStore
        self.payloadBuilder = payloadBuilder
        self.clock = clock
        self.requestIdGenerator = requestIdGenerator
        self.transport = transport
    }

    public func requestUnlock() async throws -> StandByUnlockResult {
        guard let pairedMac = try endpointCache.loadPairedMac() else {
            return StandByUnlockResult(ok: false, result: nil, errorCode: "not_paired")
        }

        if let endpoint = pairedMac.cachedEndpoint {
            do {
                let result = try await post(try signedRequest(for: pairedMac), to: endpoint)
                try saveSuccessfulEndpoint(endpoint, for: pairedMac, when: result)
                return result
            } catch {
                let rediscovered = try await rediscoveryService.rediscoverEndpoint(
                    for: pairedMac,
                    timeout: Self.endpointRediscoveryTimeout
                )
                let result = try await post(try signedRequest(for: pairedMac), to: rediscovered)
                try saveSuccessfulEndpoint(rediscovered, for: pairedMac, when: result)
                return result
            }
        }

        let rediscovered = try await rediscoveryService.rediscoverEndpoint(
            for: pairedMac,
            timeout: Self.endpointRediscoveryTimeout
        )
        let result = try await post(try signedRequest(for: pairedMac), to: rediscovered)
        try saveSuccessfulEndpoint(rediscovered, for: pairedMac, when: result)
        return result
    }

    private func signedRequest(for mac: PairedMac) throws -> StandByUnlockRequest {
        let issuedAt = clock()
        let unsigned = UnsignedStandByUnlockRequest(
            type: CanonicalStandByUnlockPayload.requestType,
            protocolVersion: CanonicalStandByUnlockPayload.protocolVersion,
            requestId: requestIdGenerator(),
            iphoneDeviceId: keyStore.iphoneDeviceId,
            macDeviceId: mac.macDeviceId,
            action: .unlockScreen,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(10),
            counter: try counterStore.nextCounter(for: mac.macDeviceId)
        )

        let signature = try keyStore.sign(payloadBuilder.data(for: unsigned))

        return StandByUnlockRequest(
            type: unsigned.type,
            protocolVersion: unsigned.protocolVersion,
            requestId: unsigned.requestId,
            iphoneDeviceId: unsigned.iphoneDeviceId,
            macDeviceId: unsigned.macDeviceId,
            action: unsigned.action,
            issuedAt: unsigned.issuedAt,
            expiresAt: unsigned.expiresAt,
            counter: unsigned.counter,
            signature: signature
        )
    }

    private func post(_ requestBody: StandByUnlockRequest, to endpoint: MacEndpoint) async throws -> StandByUnlockResult {
        guard let baseURL = endpoint.baseURL else {
            return StandByUnlockResult(ok: false, result: nil, errorCode: "invalid_endpoint")
        }

        let url = baseURL.appending(path: "v1/standby-unlock")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.standByUnlockRequestEncoder.encode(requestBody)

        let (data, _) = try await transport.data(for: request)
        return try JSONDecoder().decode(StandByUnlockResult.self, from: data)
    }

    private func saveSuccessfulEndpoint(
        _ endpoint: MacEndpoint,
        for pairedMac: PairedMac,
        when result: StandByUnlockResult
    ) throws {
        guard result.ok else {
            return
        }

        var updated = pairedMac
        updated.cachedEndpoint = endpoint
        updated.lastSeenAt = clock()
        try endpointCache.savePairedMac(updated)
    }
}

public extension JSONEncoder {
    static let standByUnlockRequestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.standByUnlockString(from: date))
        }
        return encoder
    }()
}
