import Foundation

public protocol EndpointCaching {
    func loadPairedMac() throws -> PairedMac?
    func savePairedMac(_ mac: PairedMac) throws
    func clearPairedMac() throws
}

public final class EndpointCache: EndpointCaching {
    private let defaults: UserDefaults
    private let key: String

    public convenience init(configuration: FacePassCompanionConfiguration = .default) {
        self.init(defaults: configuration.userDefaults())
    }

    public init(defaults: UserDefaults, key: String = "facepass.standbyUnlock.pairedMac") {
        self.defaults = defaults
        self.key = key
    }

    public func loadPairedMac() throws -> PairedMac? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try JSONDecoder().decode(PairedMac.self, from: data)
    }

    public func savePairedMac(_ mac: PairedMac) throws {
        let data = try JSONEncoder().encode(mac)
        defaults.set(data, forKey: key)
    }

    public func clearPairedMac() throws {
        defaults.removeObject(forKey: key)
    }
}
