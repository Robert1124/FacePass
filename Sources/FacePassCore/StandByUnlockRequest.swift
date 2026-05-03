import Foundation

public struct StandByUnlockRequest: Equatable, Codable {
    public let type: String
    public let protocolVersion: Int
    public let requestId: String
    public let iphoneDeviceId: String
    public let macDeviceId: String
    public let action: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let counter: UInt64
    public let signature: Data?

    public init(
        type: String,
        protocolVersion: Int,
        requestId: String,
        iphoneDeviceId: String,
        macDeviceId: String,
        action: String,
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

public struct StandByVerifiedUnlockRequest: Equatable, CustomStringConvertible {
    public let requestId: String
    public let macDeviceId: String
    public let iphoneDeviceId: String
    public let counter: UInt64
    public let verifiedAt: Date

    public init(
        requestId: String,
        macDeviceId: String,
        iphoneDeviceId: String,
        counter: UInt64,
        verifiedAt: Date
    ) {
        self.requestId = requestId
        self.macDeviceId = macDeviceId
        self.iphoneDeviceId = iphoneDeviceId
        self.counter = counter
        self.verifiedAt = verifiedAt
    }

    public var description: String {
        "Verified StandBy Unlock request from paired iPhone."
    }
}
