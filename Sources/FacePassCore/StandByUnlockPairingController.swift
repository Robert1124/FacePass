import CryptoKit
import Foundation

public struct StandByUnlockPairingSession: CustomStringConvertible {
    public static let bonjourServiceType = "_facepass._tcp"
    public static let bonjourDomain = "local"

    public let macDeviceId: String
    public let protocolVersion: Int
    public let publicKeyFingerprint: String
    public let oneTimeToken: String
    public let createdAt: Date
    public let expiresAt: Date
    public let localEndpoint: StandByPairingEndpoint?

    public init(
        macDeviceId: String,
        protocolVersion: Int,
        publicKeyFingerprint: String,
        oneTimeToken: String,
        createdAt: Date,
        expiresAt: Date,
        localEndpoint: StandByPairingEndpoint? = nil
    ) {
        self.macDeviceId = macDeviceId
        self.protocolVersion = protocolVersion
        self.publicKeyFingerprint = publicKeyFingerprint
        self.oneTimeToken = oneTimeToken
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.localEndpoint = localEndpoint
    }

    public var qrPayload: [String: Any] {
        var payload: [String: Any] = [
            "type": "facepass_standby_pairing",
            "protocolVersion": protocolVersion,
            "macDeviceId": macDeviceId,
            "publicKeyFingerprint": publicKeyFingerprint,
            "oneTimeToken": oneTimeToken,
            "bonjourServiceType": Self.bonjourServiceType,
            "bonjourDomain": Self.bonjourDomain,
            "expiresAt": Self.qrPayloadDateFormatter.string(from: expiresAt)
        ]

        if let localEndpoint {
            payload["localEndpoint"] = localEndpoint.qrPayload
        }

        return payload
    }

    public var description: String {
        "StandBy Unlock pairing session for Mac \(macDeviceId)."
    }
}

public struct StandByPairingEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let scheme: String

    public init(host: String, port: Int, scheme: String = "http") {
        self.host = host
        self.port = port
        self.scheme = scheme
    }

    public var urlString: String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.url?.absoluteString ?? "\(scheme)://\(host):\(port)"
    }

    public var qrPayload: [String: Any] {
        [
            "host": host,
            "port": port,
            "scheme": scheme,
            "url": urlString
        ]
    }
}

private extension StandByUnlockPairingSession {
    static let qrPayloadDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

public struct StandByIPhonePairingRegistration: Equatable, Codable {
    public let oneTimeToken: String
    public let iphoneDeviceId: String
    public let displayName: String
    public let publicKeyX963Representation: Data

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

public struct StandByIPhonePairingResult: Equatable, CustomStringConvertible {
    public let iphoneDeviceId: String
    public let displayName: String
    public let pairedAt: Date

    public init(iphoneDeviceId: String, displayName: String, pairedAt: Date) {
        self.iphoneDeviceId = iphoneDeviceId
        self.displayName = displayName
        self.pairedAt = pairedAt
    }

    public var description: String {
        "Paired iPhone \(displayName)."
    }
}

public enum StandByUnlockPairingError: Error, Equatable, CustomStringConvertible {
    case invalidOneTimeToken
    case expiredOneTimeToken
    case invalidPublicKey
    case storeFailed

    public var description: String {
        switch self {
        case .invalidOneTimeToken:
            "The StandBy Unlock pairing token is invalid."
        case .expiredOneTimeToken:
            "The StandBy Unlock pairing token has expired."
        case .invalidPublicKey:
            "The iPhone pairing public key is invalid."
        case .storeFailed:
            "The paired iPhone trust record could not be saved."
        }
    }
}

public final class StandByUnlockPairingController {
    public static let protocolVersion = 1

    private let macDeviceId: String
    private let publicKeyFingerprint: String
    private let pairedDeviceStore: any StandByPairedDeviceStoring
    private let clock: () -> Date
    private let tokenGenerator: () -> String
    private let localEndpointProvider: () -> StandByPairingEndpoint?
    private let pairingSessionTTL: TimeInterval
    private let lock = NSLock()
    private var activeToken: ActivePairingToken?

    public init(
        macDeviceId: String,
        publicKeyFingerprint: String,
        pairedDeviceStore: any StandByPairedDeviceStoring,
        clock: @escaping () -> Date = Date.init,
        tokenGenerator: @escaping () -> String = { UUID().uuidString },
        localEndpointProvider: @escaping () -> StandByPairingEndpoint? = { nil },
        pairingSessionTTL: TimeInterval = 5 * 60
    ) {
        self.macDeviceId = macDeviceId
        self.publicKeyFingerprint = publicKeyFingerprint
        self.pairedDeviceStore = pairedDeviceStore
        self.clock = clock
        self.tokenGenerator = tokenGenerator
        self.localEndpointProvider = localEndpointProvider
        self.pairingSessionTTL = pairingSessionTTL
    }

    public func startPairingSession() -> StandByUnlockPairingSession {
        let token = tokenGenerator()
        let createdAt = clock()
        let expiresAt = createdAt.addingTimeInterval(pairingSessionTTL)
        lock.withLock {
            activeToken = ActivePairingToken(
                value: token,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        }

        return StandByUnlockPairingSession(
            macDeviceId: macDeviceId,
            protocolVersion: Self.protocolVersion,
            publicKeyFingerprint: publicKeyFingerprint,
            oneTimeToken: token,
            createdAt: createdAt,
            expiresAt: expiresAt,
            localEndpoint: localEndpointProvider()
        )
    }

    public func registerIPhone(
        _ registration: StandByIPhonePairingRegistration
    ) throws -> StandByIPhonePairingResult {
        let tokenValidation = lock.withLock {
            consumeActiveToken(registration.oneTimeToken, now: clock())
        }

        switch tokenValidation {
        case .valid:
            break
        case .invalid:
            throw StandByUnlockPairingError.invalidOneTimeToken
        case .expired:
            throw StandByUnlockPairingError.expiredOneTimeToken
        }

        guard !registration.iphoneDeviceId.isEmpty,
              !registration.displayName.isEmpty,
              isValidP256PublicKey(registration.publicKeyX963Representation) else {
            throw StandByUnlockPairingError.invalidPublicKey
        }

        let now = clock()
        let device = StandByPairedDevice(
            iphoneDeviceId: registration.iphoneDeviceId,
            displayName: registration.displayName,
            publicKeyX963Representation: registration.publicKeyX963Representation,
            signingAlgorithm: .p256SHA256,
            isEnabled: true,
            createdAt: now,
            lastSeenAt: nil,
            highestAcceptedCounter: 0
        )

        do {
            try pairedDeviceStore.replacePairedDevice(device)
        } catch {
            throw StandByUnlockPairingError.storeFailed
        }

        return StandByIPhonePairingResult(
            iphoneDeviceId: registration.iphoneDeviceId,
            displayName: registration.displayName,
            pairedAt: now
        )
    }

    private func isValidP256PublicKey(_ data: Data) -> Bool {
        (try? P256.Signing.PublicKey(x963Representation: data)) != nil
    }

    private func consumeActiveToken(_ token: String, now: Date) -> TokenValidationResult {
        guard let activeToken, activeToken.value == token else {
            return .invalid
        }

        guard now < activeToken.expiresAt else {
            self.activeToken = nil
            return .expired
        }

        self.activeToken = nil
        return .valid
    }
}

private struct ActivePairingToken {
    let value: String
    let createdAt: Date
    let expiresAt: Date
}

private enum TokenValidationResult {
    case valid
    case invalid
    case expired
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
