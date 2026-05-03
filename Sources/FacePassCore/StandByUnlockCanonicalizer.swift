import Foundation

public enum StandByUnlockCanonicalizationError: Error, Equatable, CustomStringConvertible {
    case unsupportedType
    case unsupportedProtocolVersion
    case encodingFailed

    public var description: String {
        switch self {
        case .unsupportedType:
            "Unsupported StandBy Unlock request type."
        case .unsupportedProtocolVersion:
            "Unsupported StandBy Unlock protocol version."
        case .encodingFailed:
            "Unable to canonicalize StandBy Unlock request."
        }
    }
}

public enum StandByUnlockCanonicalizer {
    public static let supportedType = "standby_unlock_request"
    public static let supportedProtocolVersion = 1

    public static func canonicalPayload(for request: StandByUnlockRequest) throws -> Data {
        guard request.type == supportedType else {
            throw StandByUnlockCanonicalizationError.unsupportedType
        }

        guard request.protocolVersion == supportedProtocolVersion else {
            throw StandByUnlockCanonicalizationError.unsupportedProtocolVersion
        }

        do {
            let json = try [
                "\"action\":\(jsonString(request.action))",
                "\"counter\":\(request.counter)",
                "\"expiresAt\":\(jsonString(canonicalDateString(from: request.expiresAt)))",
                "\"issuedAt\":\(jsonString(canonicalDateString(from: request.issuedAt)))",
                "\"iphoneDeviceId\":\(jsonString(request.iphoneDeviceId))",
                "\"macDeviceId\":\(jsonString(request.macDeviceId))",
                "\"protocolVersion\":\(request.protocolVersion)",
                "\"requestId\":\(jsonString(request.requestId))",
                "\"type\":\(jsonString(request.type))"
            ].joined(separator: ",")
            return Data("{\(json)}".utf8)
        } catch {
            throw StandByUnlockCanonicalizationError.encodingFailed
        }
    }

    private static func canonicalDateString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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
