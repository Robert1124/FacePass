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
    private static let nearbyPortProbeRadius = 12
    private static let preferredMacPort = 65531
    private static let endpointProbeTimeout: TimeInterval = 0.75

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
                do {
                    let rediscovered = try await rediscoveryService.rediscoverEndpoint(
                        for: pairedMac,
                        timeout: Self.endpointRediscoveryTimeout
                    )
                    let result = try await post(try signedRequest(for: pairedMac), to: rediscovered)
                    try saveSuccessfulEndpoint(rediscovered, for: pairedMac, when: result)
                    return result
                } catch {
                    if let recovered = await recoverEndpointNearCachedEndpoint(endpoint, for: pairedMac) {
                        let result = try await post(try signedRequest(for: pairedMac), to: recovered)
                        try saveSuccessfulEndpoint(recovered, for: pairedMac, when: result)
                        return result
                    }
                    throw error
                }
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

    private func recoverEndpointNearCachedEndpoint(
        _ cachedEndpoint: MacEndpoint,
        for pairedMac: PairedMac
    ) async -> MacEndpoint? {
        for endpoint in endpointProbeCandidates(from: cachedEndpoint) {
            if await statusEndpointMatches(endpoint, pairedMac: pairedMac) {
                return endpoint
            }
        }

        return nil
    }

    private func endpointProbeCandidates(from endpoint: MacEndpoint) -> [MacEndpoint] {
        Self.nearbyPortCandidates(around: endpoint.port).map { port in
            MacEndpoint(host: endpoint.host, port: port, scheme: endpoint.scheme)
        }
    }

    private static func nearbyPortCandidates(around port: Int) -> [Int] {
        var candidates: [Int] = []

        for offset in 1...nearbyPortProbeRadius {
            candidates.append(port + offset)
            candidates.append(port - offset)
        }

        candidates.append(preferredMacPort)

        var seen = Set<Int>()
        return candidates.filter { candidate in
            guard candidate > 0, candidate <= 65535, candidate != port else {
                return false
            }
            return seen.insert(candidate).inserted
        }
    }

    private func statusEndpointMatches(
        _ endpoint: MacEndpoint,
        pairedMac: PairedMac
    ) async -> Bool {
        guard let baseURL = endpoint.baseURL else {
            return false
        }

        var request = URLRequest(url: baseURL.appending(path: "v1/status"))
        request.timeoutInterval = Self.endpointProbeTimeout

        do {
            let (data, response) = try await transport.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return false
            }

            let status = try JSONDecoder().decode(StandByStatusResponse.self, from: data)
            return status.macDeviceId == pairedMac.macDeviceId &&
                status.publicKeyFingerprint == pairedMac.publicKeyFingerprint &&
                status.serverStatus == "ready"
        } catch {
            return false
        }
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

private struct StandByStatusResponse: Decodable {
    let macDeviceId: String
    let publicKeyFingerprint: String
    let serverStatus: String
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
