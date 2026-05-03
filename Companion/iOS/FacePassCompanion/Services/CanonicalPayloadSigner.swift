import CryptoKit
import Foundation

public enum CanonicalPayloadError: Error, Equatable {
    case unsupportedType
    case unsupportedProtocolVersion
    case unsupportedAction
    case encodingFailed
}

public struct CanonicalStandByUnlockPayload {
    public static let requestType = "standby_unlock_request"
    public static let protocolVersion = 1

    public init() {}

    public func data(for request: UnsignedStandByUnlockRequest) throws -> Data {
        guard request.type == Self.requestType else {
            throw CanonicalPayloadError.unsupportedType
        }

        guard request.protocolVersion == Self.protocolVersion else {
            throw CanonicalPayloadError.unsupportedProtocolVersion
        }

        guard request.action == .unlockScreen else {
            throw CanonicalPayloadError.unsupportedAction
        }

        do {
            let canonical = try [
                "\"action\":\(Self.jsonString(request.action.rawValue))",
                "\"counter\":\(request.counter)",
                "\"expiresAt\":\(Self.jsonString(Self.format(request.expiresAt)))",
                "\"issuedAt\":\(Self.jsonString(Self.format(request.issuedAt)))",
                "\"iphoneDeviceId\":\(Self.jsonString(request.iphoneDeviceId))",
                "\"macDeviceId\":\(Self.jsonString(request.macDeviceId))",
                "\"protocolVersion\":\(request.protocolVersion)",
                "\"requestId\":\(Self.jsonString(request.requestId))",
                "\"type\":\(Self.jsonString(request.type))"
            ].joined(separator: ",")
            return Data("{\(canonical)}".utf8)
        } catch {
            throw CanonicalPayloadError.encodingFailed
        }
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter.standByUnlockString(from: date)
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        )
        let arrayLiteral = String(decoding: data, as: UTF8.self)
        return String(arrayLiteral.dropFirst().dropLast())
    }
}

public protocol StandByUnlockSigning {
    func sign(_ payload: Data) throws -> Data
}

struct P256StandByUnlockSigner: StandByUnlockSigning {
    private var privateKey: P256.Signing.PrivateKey

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    func sign(_ payload: Data) throws -> Data {
        try privateKey.signature(for: payload).derRepresentation
    }
}

public extension ISO8601DateFormatter {
    static func standByUnlockString(from date: Date) -> String {
        standByUnlockFormatter().string(from: date)
    }

    static func standByUnlockDate(from value: String) -> Date? {
        standByUnlockFormatter().date(from: value)
    }

    private static func standByUnlockFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
