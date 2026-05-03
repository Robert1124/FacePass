import Foundation

public enum PairingClientError: Error, Equatable, CustomStringConvertible {
    case invalidPayload
    case unsupportedProtocolVersion
    case expiredPayload
    case discoveryFailed
    case discoveryTimedOut
    case discoveryNotFound
    case discoverySearchFailed
    case requestFailed
    case rejected(String)

    public var code: String {
        switch self {
        case .invalidPayload:
            "invalid_payload"
        case .unsupportedProtocolVersion:
            "unsupported_protocol"
        case .expiredPayload:
            "expired_payload"
        case .discoveryFailed:
            "discovery_failed"
        case .discoveryTimedOut:
            "discovery_timed_out"
        case .discoveryNotFound:
            "discovery_not_found"
        case .discoverySearchFailed:
            "discovery_search_failed"
        case .requestFailed:
            "request_failed"
        case .rejected(let code):
            code
        }
    }

    public var description: String {
        code
    }
}

public final class PairingClient {
    private let endpointCache: EndpointCaching
    private let rediscoveryService: any PairingEndpointRediscovering
    private let keyStore: CompanionKeyStoring
    private let configuration: FacePassCompanionConfiguration
    private let clock: () -> Date
    private let transport: StandByUnlockTransporting

    public init(
        endpointCache: EndpointCaching,
        rediscoveryService: any PairingEndpointRediscovering = BonjourRediscoveryService(),
        keyStore: CompanionKeyStoring,
        configuration: FacePassCompanionConfiguration = .default,
        clock: @escaping () -> Date = Date.init,
        transport: StandByUnlockTransporting = URLSessionStandByUnlockTransport()
    ) {
        self.endpointCache = endpointCache
        self.rediscoveryService = rediscoveryService
        self.keyStore = keyStore
        self.configuration = configuration
        self.clock = clock
        self.transport = transport
    }

    public func pair(with payload: PairingQRCodePayload) async throws -> PairedMac {
        try validate(payload)

        if let endpoint = payload.localEndpoint {
            do {
                return try await pair(payload: payload, endpoint: endpoint)
            } catch PairingClientError.requestFailed {
                // Direct QR endpoints can fail on networks that block direct IP traffic; Bonjour remains the fallback.
            }
        }

        let endpoint = try await rediscoverEndpoint(for: payload)
        return try await pair(payload: payload, endpoint: endpoint)
    }

    private func pair(payload: PairingQRCodePayload, endpoint: MacEndpoint) async throws -> PairedMac {
        let response = try await postPairingRegistration(payload: payload, to: endpoint)
        guard response.ok else {
            throw PairingClientError.rejected(response.errorCode ?? "pairing_rejected")
        }

        let now = clock()
        let mac = PairedMac(
            macDeviceId: payload.macDeviceId,
            displayName: payload.displayName,
            publicKeyFingerprint: payload.publicKeyFingerprint,
            cachedEndpoint: endpoint,
            bonjourServiceName: nil,
            pairedAt: now,
            lastSeenAt: now
        )
        try endpointCache.savePairedMac(mac)
        return mac
    }

    private func rediscoverEndpoint(for payload: PairingQRCodePayload) async throws -> MacEndpoint {
        do {
            return try await rediscoveryService.rediscoverEndpoint(
                macDeviceId: payload.macDeviceId,
                publicKeyFingerprint: payload.publicKeyFingerprint,
                timeout: .seconds(5)
            )
        } catch let error as BonjourRediscoveryError {
            throw pairingError(for: error)
        } catch {
            throw PairingClientError.discoveryFailed
        }
    }

    private func validate(_ payload: PairingQRCodePayload) throws {
        guard payload.type == PairingQRCodePayload.expectedType,
              !payload.macDeviceId.isEmpty,
              !payload.publicKeyFingerprint.isEmpty,
              !payload.oneTimeToken.isEmpty,
              normalized(payload.bonjourServiceType) == "_facepass._tcp",
              normalized(payload.bonjourDomain) == "local",
              payload.expirationDate != nil,
              isValidEndpoint(payload.localEndpoint) else {
            throw PairingClientError.invalidPayload
        }

        guard payload.protocolVersion == CanonicalStandByUnlockPayload.protocolVersion else {
            throw PairingClientError.unsupportedProtocolVersion
        }

        guard let expiresAt = payload.expirationDate, clock() < expiresAt else {
            throw PairingClientError.expiredPayload
        }
    }

    private func normalized(_ value: String) -> String {
        value.hasSuffix(".") ? String(value.dropLast()) : value
    }

    private func isValidEndpoint(_ endpoint: MacEndpoint?) -> Bool {
        guard let endpoint else {
            return true
        }

        return !endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && endpoint.port > 0
            && endpoint.port <= 65535
            && endpoint.baseURL != nil
    }

    private func pairingError(for error: BonjourRediscoveryError) -> PairingClientError {
        switch error {
        case .timeout:
            .discoveryTimedOut
        case .notFound:
            .discoveryNotFound
        case .searchFailed:
            .discoverySearchFailed
        }
    }

    private func postPairingRegistration(
        payload: PairingQRCodePayload,
        to endpoint: MacEndpoint
    ) async throws -> PairingResponse {
        guard let baseURL = endpoint.baseURL else {
            throw PairingClientError.requestFailed
        }

        let registration = PairingRegistrationRequest(
            oneTimeToken: payload.oneTimeToken,
            iphoneDeviceId: keyStore.iphoneDeviceId,
            displayName: configuration.iphoneDisplayName,
            publicKeyX963Representation: try keyStore.publicKeyX963Representation()
        )

        let url = baseURL.appending(path: "v1/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.standByUnlockRequestEncoder.encode(registration)

        do {
            let (data, _) = try await transport.data(for: request)
            return try JSONDecoder().decode(PairingResponse.self, from: data)
        } catch let error as PairingClientError {
            throw error
        } catch {
            throw PairingClientError.requestFailed
        }
    }
}
