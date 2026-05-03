import Foundation
import Darwin

public protocol StandByUnlockCounterStoring {
    func nextCounter(for macDeviceId: String) throws -> UInt64
}

public enum StandByUnlockCounterStoreError: Error, Equatable {
    case counterOverflow
    case lockUnavailable(Int32)
}

public final class UserDefaultsStandByUnlockCounterStore: StandByUnlockCounterStoring {
    private let defaults: UserDefaults
    private let key: String
    private let lockFileURL: URL
    private let lock = NSLock()

    public convenience init(configuration: FacePassCompanionConfiguration = .default) {
        self.init(defaults: configuration.userDefaults(), lockFileURL: configuration.counterLockFileURL())
    }

    public init(
        defaults: UserDefaults,
        key: String = "facepass.standbyUnlock.countersByMacDeviceId",
        lockFileURL: URL = FileManager.default.temporaryDirectory.appending(path: "StandByUnlockCounterStore.lock")
    ) {
        self.defaults = defaults
        self.key = key
        self.lockFileURL = lockFileURL
    }

    public func nextCounter(for macDeviceId: String) throws -> UInt64 {
        try lock.withLock {
            try withFileLock {
                defaults.synchronize()
                var counters = loadCounters()
                let current = counters[macDeviceId] ?? 0
                guard current < UInt64.max else {
                    throw StandByUnlockCounterStoreError.counterOverflow
                }

                let next = current + 1
                counters[macDeviceId] = next
                saveCounters(counters)
                defaults.synchronize()
                return next
            }
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let directoryURL = lockFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileDescriptor = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw StandByUnlockCounterStoreError.lockUnavailable(errno)
        }
        defer { close(fileDescriptor) }

        guard flock(fileDescriptor, LOCK_EX) == 0 else {
            throw StandByUnlockCounterStoreError.lockUnavailable(errno)
        }
        defer { flock(fileDescriptor, LOCK_UN) }

        return try body()
    }

    private func loadCounters() -> [String: UInt64] {
        guard let data = defaults.data(forKey: key),
              let counters = try? JSONDecoder().decode([String: UInt64].self, from: data) else {
            return [:]
        }
        return counters
    }

    private func saveCounters(_ counters: [String: UInt64]) {
        guard let data = try? JSONEncoder().encode(counters) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
