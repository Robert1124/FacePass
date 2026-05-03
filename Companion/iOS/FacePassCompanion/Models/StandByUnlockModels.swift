import Foundation

public enum StandByUnlockAction: String, Codable, Sendable {
    case unlockScreen = "unlock_screen"
}

public struct MacEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var scheme: String

    public init(host: String, port: Int, scheme: String) {
        self.host = host
        self.port = port
        self.scheme = scheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let host = try container.decodeIfPresent(String.self, forKey: .host),
           let port = try container.decodeIfPresent(Int.self, forKey: .port) {
            self.host = host
            self.port = port
            self.scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? "http"
            return
        }

        if let urlString = try container.decodeIfPresent(String.self, forKey: .url),
           let components = URLComponents(string: urlString),
           let scheme = components.scheme,
           let host = components.host,
           let port = components.port {
            self.host = host
            self.port = port
            self.scheme = scheme
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .host,
            in: container,
            debugDescription: "Mac endpoint requires host/port or url."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(scheme, forKey: .scheme)
    }

    public var baseURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.url
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case scheme
        case url
    }
}

public struct PairedMac: Codable, Equatable, Identifiable, Sendable {
    public var id: String { macDeviceId }

    public var macDeviceId: String
    public var displayName: String
    public var publicKeyFingerprint: String
    public var cachedEndpoint: MacEndpoint?
    public var bonjourServiceName: String?
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(
        macDeviceId: String,
        displayName: String,
        publicKeyFingerprint: String,
        cachedEndpoint: MacEndpoint?,
        bonjourServiceName: String?,
        pairedAt: Date,
        lastSeenAt: Date?
    ) {
        self.macDeviceId = macDeviceId
        self.displayName = displayName
        self.publicKeyFingerprint = publicKeyFingerprint
        self.cachedEndpoint = cachedEndpoint
        self.bonjourServiceName = bonjourServiceName
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct PairingQRCodePayload: Codable, Equatable, Sendable {
    public static let expectedType = "facepass_standby_pairing"

    public var type: String
    public var protocolVersion: Int
    public var macDeviceId: String
    public var publicKeyFingerprint: String
    public var oneTimeToken: String
    public var bonjourServiceType: String
    public var bonjourDomain: String
    public var expiresAt: String
    public var localEndpoint: MacEndpoint?

    public init(
        type: String,
        protocolVersion: Int,
        macDeviceId: String,
        publicKeyFingerprint: String,
        oneTimeToken: String,
        bonjourServiceType: String,
        bonjourDomain: String,
        expiresAt: String,
        localEndpoint: MacEndpoint? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.macDeviceId = macDeviceId
        self.publicKeyFingerprint = publicKeyFingerprint
        self.oneTimeToken = oneTimeToken
        self.bonjourServiceType = bonjourServiceType
        self.bonjourDomain = bonjourDomain
        self.expiresAt = expiresAt
        self.localEndpoint = localEndpoint
    }

    public var displayName: String {
        macDeviceId
    }

    public var expirationDate: Date? {
        ISO8601DateFormatter.standByUnlockDate(from: expiresAt)
    }
}

public struct PairingRegistrationRequest: Codable, Equatable, Sendable {
    public var oneTimeToken: String
    public var iphoneDeviceId: String
    public var displayName: String
    public var publicKeyX963Representation: Data

    public init(
        oneTimeToken: String,
        iphoneDeviceId: String,
        displayName: String,
        publicKeyX963Representation: Data
    ) {
        self.oneTimeToken = oneTimeToken
        self.iphoneDeviceId = iphoneDeviceId
        self.displayName = displayName
        self.publicKeyX963Representation = publicKeyX963Representation
    }
}

public struct StandByUnlockRequest: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var iphoneDeviceId: String
    public var macDeviceId: String
    public var action: StandByUnlockAction
    public var issuedAt: Date
    public var expiresAt: Date
    public var counter: UInt64
    public var signature: Data?

    public init(
        type: String,
        protocolVersion: Int,
        requestId: String,
        iphoneDeviceId: String,
        macDeviceId: String,
        action: StandByUnlockAction,
        issuedAt: Date,
        expiresAt: Date,
        counter: UInt64,
        signature: Data?
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.iphoneDeviceId = iphoneDeviceId
        self.macDeviceId = macDeviceId
        self.action = action
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.counter = counter
        self.signature = signature
    }
}

public struct UnsignedStandByUnlockRequest: Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var iphoneDeviceId: String
    public var macDeviceId: String
    public var action: StandByUnlockAction
    public var issuedAt: Date
    public var expiresAt: Date
    public var counter: UInt64

    public init(
        type: String,
        protocolVersion: Int,
        requestId: String,
        iphoneDeviceId: String,
        macDeviceId: String,
        action: StandByUnlockAction,
        issuedAt: Date,
        expiresAt: Date,
        counter: UInt64
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.iphoneDeviceId = iphoneDeviceId
        self.macDeviceId = macDeviceId
        self.action = action
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.counter = counter
    }
}

public struct StandByUnlockResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var result: String?
    public var errorCode: String?

    public init(ok: Bool, result: String?, errorCode: String?) {
        self.ok = ok
        self.result = result
        self.errorCode = errorCode
    }
}

public struct PairingResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var result: String?
    public var errorCode: String?
    public var iphoneDeviceId: String?
    public var displayName: String?

    public init(
        ok: Bool,
        result: String?,
        errorCode: String?,
        iphoneDeviceId: String?,
        displayName: String?
    ) {
        self.ok = ok
        self.result = result
        self.errorCode = errorCode
        self.iphoneDeviceId = iphoneDeviceId
        self.displayName = displayName
    }
}
