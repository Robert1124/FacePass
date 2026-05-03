import ActivityKit
import Foundation

@available(iOS 16.2, *)
public struct StandByUnlockActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: String
        public var lastRequestAt: Date?
        public var isRequestInFlight: Bool

        public init(
            status: String = "FacePass Ready",
            lastRequestAt: Date? = nil,
            isRequestInFlight: Bool = false
        ) {
            self.status = status
            self.lastRequestAt = lastRequestAt
            self.isRequestInFlight = isRequestInFlight
        }
    }

    public var macDeviceId: String
    public var macDisplayName: String

    public init(macDeviceId: String, macDisplayName: String) {
        self.macDeviceId = macDeviceId
        self.macDisplayName = macDisplayName
    }
}
