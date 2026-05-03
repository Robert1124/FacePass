import Foundation
import XCTest
@testable import FacePassCompanionCore

final class EndpointCacheTests: XCTestCase {
    func testEndpointCacheRoundTripsPairedMacThroughDefaults() throws {
        let defaults = try makeDefaults()
        let cache = EndpointCache(defaults: defaults)
        let mac = PairedMac(
            macDeviceId: "mac-facepass-1",
            displayName: "Office Mac",
            publicKeyFingerprint: "SHA256:public-key-fingerprint",
            cachedEndpoint: MacEndpoint(host: "192.168.1.10", port: 45000, scheme: "http"),
            bonjourServiceName: "FacePass Office Mac",
            pairedAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 200)
        )

        try cache.savePairedMac(mac)

        XCTAssertEqual(try cache.loadPairedMac(), mac)

        try cache.clearPairedMac()
        XCTAssertNil(try cache.loadPairedMac())
    }

    func testDurableCounterIncrementsIndependentlyPerMac() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsStandByUnlockCounterStore(defaults: defaults)

        XCTAssertEqual(try store.nextCounter(for: "mac-a"), 1)
        XCTAssertEqual(try store.nextCounter(for: "mac-a"), 2)
        XCTAssertEqual(try store.nextCounter(for: "mac-b"), 1)

        let reloaded = UserDefaultsStandByUnlockCounterStore(defaults: defaults)
        XCTAssertEqual(try reloaded.nextCounter(for: "mac-a"), 3)
        XCTAssertEqual(try reloaded.nextCounter(for: "mac-b"), 2)
    }

    func testDurableCounterSerializesConcurrentIncrementsAcrossStoreInstances() throws {
        let defaults = try makeDefaults()
        let lockFileURL = FileManager.default.temporaryDirectory
            .appending(path: "FacePassCompanionTests-\(UUID().uuidString).lock")
        let iterations = 200
        let queue = DispatchQueue(label: "FacePassCompanionTests.counter", attributes: .concurrent)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var counters: [UInt64] = []
        var errors: [Error] = []

        for _ in 0..<iterations {
            group.enter()
            queue.async {
                defer { group.leave() }
                let store = UserDefaultsStandByUnlockCounterStore(defaults: defaults, lockFileURL: lockFileURL)
                do {
                    let counter = try store.nextCounter(for: "mac-a")
                    resultLock.lock()
                    counters.append(counter)
                    resultLock.unlock()
                } catch {
                    resultLock.lock()
                    errors.append(error)
                    resultLock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(Set(counters), Set(UInt64(1)...UInt64(iterations)))
        XCTAssertEqual(try UserDefaultsStandByUnlockCounterStore(defaults: defaults, lockFileURL: lockFileURL).nextCounter(for: "mac-a"), UInt64(iterations + 1))

        try? FileManager.default.removeItem(at: lockFileURL)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "FacePassCompanionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
