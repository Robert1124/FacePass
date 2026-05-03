import CryptoKit
import Foundation

public protocol StandByUnlockVerifying {
    func verify(_ request: StandByUnlockRequest) throws -> StandByVerifiedUnlockRequest
}

public enum StandByUnlockVerificationError: Error, Equatable, CustomStringConvertible {
    case unsupportedType
    case unsupportedProtocolVersion
    case unsupportedAction
    case wrongMacDevice
    case unpairedIPhone
    case disabledIPhone
    case missingSignature
    case invalidPublicKey
    case invalidSignature
    case expiredRequest
    case futureRequest
    case excessiveValidityWindow
    case replayedRequestId
    case staleCounter
    case replayStoreFailed

    public var description: String {
        switch self {
        case .unsupportedType:
            "StandBy Unlock request type is unsupported."
        case .unsupportedProtocolVersion:
            "StandBy Unlock protocol version is unsupported."
        case .unsupportedAction:
            "StandBy Unlock request action is unsupported."
        case .wrongMacDevice:
            "StandBy Unlock request is for a different Mac."
        case .unpairedIPhone:
            "StandBy Unlock request is from an unpaired iPhone."
        case .disabledIPhone:
            "StandBy Unlock request is from a disabled paired iPhone."
        case .missingSignature:
            "StandBy Unlock request is missing a signature."
        case .invalidPublicKey:
            "Paired iPhone public key is invalid."
        case .invalidSignature:
            "StandBy Unlock request signature is invalid."
        case .expiredRequest:
            "StandBy Unlock request has expired."
        case .futureRequest:
            "StandBy Unlock request is not valid yet."
        case .excessiveValidityWindow:
            "StandBy Unlock request validity window is too long."
        case .replayedRequestId:
            "StandBy Unlock request was already used."
        case .staleCounter:
            "StandBy Unlock request counter is stale."
        case .replayStoreFailed:
            "StandBy Unlock replay protection could not be updated."
        }
    }
}

public final class StandByUnlockRequestVerifier: StandByUnlockVerifying {
    private let macDeviceId: String
    private let pairedDeviceStore: any StandByPairedDeviceReading
    private let replayCache: any StandByReplayChecking
    private let clock: () -> Date
    private let maximumClockSkew: TimeInterval
    private let maximumValidityWindow: TimeInterval

    public init(
        macDeviceId: String,
        pairedDeviceStore: any StandByPairedDeviceReading,
        replayCache: any StandByReplayChecking = StandByReplayCache(),
        clock: @escaping () -> Date = Date.init,
        maximumClockSkew: TimeInterval = 30,
        maximumValidityWindow: TimeInterval = 60
    ) {
        self.macDeviceId = macDeviceId
        self.pairedDeviceStore = pairedDeviceStore
        self.replayCache = replayCache
        self.clock = clock
        self.maximumClockSkew = maximumClockSkew
        self.maximumValidityWindow = maximumValidityWindow
    }

    public func verify(_ request: StandByUnlockRequest) throws -> StandByVerifiedUnlockRequest {
        guard request.type == StandByUnlockCanonicalizer.supportedType else {
            throw StandByUnlockVerificationError.unsupportedType
        }

        guard request.protocolVersion == StandByUnlockCanonicalizer.supportedProtocolVersion else {
            throw StandByUnlockVerificationError.unsupportedProtocolVersion
        }

        guard request.macDeviceId == macDeviceId else {
            throw StandByUnlockVerificationError.wrongMacDevice
        }

        guard request.action == "unlock_screen" else {
            throw StandByUnlockVerificationError.unsupportedAction
        }

        let now = clock()
        guard request.expiresAt.timeIntervalSince(request.issuedAt) <= maximumValidityWindow else {
            throw StandByUnlockVerificationError.excessiveValidityWindow
        }

        guard request.expiresAt >= now else {
            throw StandByUnlockVerificationError.expiredRequest
        }

        guard request.issuedAt <= now.addingTimeInterval(maximumClockSkew) else {
            throw StandByUnlockVerificationError.futureRequest
        }

        guard let device = try pairedDeviceStore.pairedDevice(forIPhoneDeviceId: request.iphoneDeviceId) else {
            throw StandByUnlockVerificationError.unpairedIPhone
        }

        guard device.isEnabled else {
            throw StandByUnlockVerificationError.disabledIPhone
        }

        guard request.counter > device.highestAcceptedCounter else {
            throw StandByUnlockVerificationError.staleCounter
        }

        try verifySignature(for: request, device: device)

        do {
            try replayCache.accept(
                requestId: request.requestId,
                counter: request.counter,
                iphoneDeviceId: request.iphoneDeviceId,
                expiresAt: request.expiresAt
            )
        } catch let error as StandByUnlockVerificationError {
            throw error
        } catch {
            throw StandByUnlockVerificationError.replayStoreFailed
        }

        if let pairedDeviceStore = pairedDeviceStore as? any StandByPairedDeviceStoring {
            do {
                try pairedDeviceStore.savePairedDevice(
                    StandByPairedDevice(
                        iphoneDeviceId: device.iphoneDeviceId,
                        displayName: device.displayName,
                        publicKeyX963Representation: device.publicKeyX963Representation,
                        signingAlgorithm: device.signingAlgorithm,
                        isEnabled: device.isEnabled,
                        createdAt: device.createdAt,
                        lastSeenAt: now,
                        highestAcceptedCounter: request.counter
                    )
                )
            } catch {
                throw StandByUnlockVerificationError.replayStoreFailed
            }
        }

        return StandByVerifiedUnlockRequest(
            requestId: request.requestId,
            macDeviceId: request.macDeviceId,
            iphoneDeviceId: request.iphoneDeviceId,
            counter: request.counter,
            verifiedAt: now
        )
    }

    private func verifySignature(
        for request: StandByUnlockRequest,
        device: StandByPairedDevice
    ) throws {
        guard device.signingAlgorithm == .p256SHA256 else {
            throw StandByUnlockVerificationError.invalidSignature
        }

        guard let signatureData = request.signature else {
            throw StandByUnlockVerificationError.missingSignature
        }

        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(x963Representation: device.publicKeyX963Representation)
        } catch {
            throw StandByUnlockVerificationError.invalidPublicKey
        }

        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        } catch {
            throw StandByUnlockVerificationError.invalidSignature
        }

        let canonicalPayload: Data
        do {
            canonicalPayload = try StandByUnlockCanonicalizer.canonicalPayload(
                for: StandByUnlockRequest(
                    type: request.type,
                    protocolVersion: request.protocolVersion,
                    requestId: request.requestId,
                    iphoneDeviceId: request.iphoneDeviceId,
                    macDeviceId: request.macDeviceId,
                    action: request.action,
                    issuedAt: request.issuedAt,
                    expiresAt: request.expiresAt,
                    counter: request.counter,
                    signature: nil
                )
            )
        } catch StandByUnlockCanonicalizationError.unsupportedType {
            throw StandByUnlockVerificationError.unsupportedType
        } catch StandByUnlockCanonicalizationError.unsupportedProtocolVersion {
            throw StandByUnlockVerificationError.unsupportedProtocolVersion
        } catch {
            throw StandByUnlockVerificationError.invalidSignature
        }

        guard publicKey.isValidSignature(signature, for: canonicalPayload) else {
            throw StandByUnlockVerificationError.invalidSignature
        }
    }
}
