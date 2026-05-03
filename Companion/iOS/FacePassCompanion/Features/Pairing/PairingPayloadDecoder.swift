import FacePassCompanionCore
import Foundation

struct PairingPayloadDecoder {
    func decode(_ rawPayload: String) throws -> PairingQRCodePayload {
        let trimmed = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw PairingPayloadDecoderError.emptyPayload
        }

        let payload: PairingQRCodePayload
        do {
            payload = try JSONDecoder().decode(PairingQRCodePayload.self, from: data)
        } catch {
            throw PairingPayloadDecoderError.invalidJSON
        }

        guard payload.type == PairingQRCodePayload.expectedType,
              !payload.macDeviceId.isEmpty,
              !payload.publicKeyFingerprint.isEmpty,
              !payload.oneTimeToken.isEmpty,
              !payload.bonjourServiceType.isEmpty,
              !payload.bonjourDomain.isEmpty,
              payload.expirationDate != nil else {
            throw PairingPayloadDecoderError.invalidPayload
        }

        guard payload.protocolVersion == CanonicalStandByUnlockPayload.protocolVersion else {
            throw PairingPayloadDecoderError.unsupportedProtocolVersion
        }

        guard let expirationDate = payload.expirationDate, Date() < expirationDate else {
            throw PairingPayloadDecoderError.expiredPayload
        }

        return payload
    }

    static func displayText(for error: Error) -> String {
        if let error = error as? PairingPayloadDecoderError {
            return error.localizedDescription
        }

        if let error = error as? PairingClientError {
            return displayText(forPairingClientError: error)
        }

        return "Pairing failed. Check that the Mac is nearby and showing a current pairing code."
    }

    private static func displayText(forPairingClientError error: PairingClientError) -> String {
        switch error {
        case .invalidPayload:
            "This pairing code is not valid."
        case .unsupportedProtocolVersion:
            "This pairing code is from an unsupported FacePass version."
        case .expiredPayload:
            "This pairing code expired. Show a new code on the Mac and try again."
        case .discoveryFailed:
            "The Mac could not be found on the local network."
        case .discoveryTimedOut:
            "Searching for the Mac timed out. Check that both devices are on the same local network."
        case .discoveryNotFound:
            "The Mac was not found on the local network."
        case .discoverySearchFailed:
            "The iPhone could not search the local network. Check Local Network permission for FacePass."
        case .requestFailed:
            "The pairing request failed. Check that both devices are on the same local network."
        case .rejected:
            "The Mac rejected the pairing request. Show a new code on the Mac and try again."
        }
    }
}

enum PairingPayloadDecoderError: LocalizedError {
    case emptyPayload
    case invalidJSON
    case invalidPayload
    case unsupportedProtocolVersion
    case expiredPayload

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            "Paste the pairing JSON or scan the QR code from the Mac."
        case .invalidJSON:
            "This pairing text is not valid JSON."
        case .invalidPayload:
            "This is not a valid FacePass pairing code."
        case .unsupportedProtocolVersion:
            "This pairing code is from an unsupported FacePass version."
        case .expiredPayload:
            "This pairing code expired. Show a new code on the Mac and try again."
        }
    }
}
