import Foundation

public protocol StandByReplayChecking {
    func accept(
        requestId: String,
        counter: UInt64,
        iphoneDeviceId: String,
        expiresAt: Date
    ) throws
}

public final class StandByReplayCache: StandByReplayChecking {
    private struct Entry {
        let requestId: String
        let expiresAt: Date
    }

    private let clock: () -> Date
    private let queue = DispatchQueue(label: "FacePass.StandByReplayCache")
    private var entriesByDeviceId: [String: [Entry]] = [:]
    private var highestCounterByDeviceId: [String: UInt64] = [:]

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    public func accept(
        requestId: String,
        counter: UInt64,
        iphoneDeviceId: String,
        expiresAt: Date
    ) throws {
        try queue.sync {
            let now = clock()
            var entries = entriesByDeviceId[iphoneDeviceId, default: []]
                .filter { $0.expiresAt > now }

            guard !entries.contains(where: { $0.requestId == requestId }) else {
                throw StandByUnlockVerificationError.replayedRequestId
            }

            if let highestCounter = highestCounterByDeviceId[iphoneDeviceId],
               counter <= highestCounter {
                throw StandByUnlockVerificationError.staleCounter
            }

            entries.append(Entry(requestId: requestId, expiresAt: expiresAt))
            entriesByDeviceId[iphoneDeviceId] = entries
            highestCounterByDeviceId[iphoneDeviceId] = counter
        }
    }
}
