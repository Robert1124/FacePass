import Foundation
import Darwin

public protocol BonjourRediscovering {
    func rediscoverEndpoint(for mac: PairedMac, timeout: Duration) async throws -> MacEndpoint
}

public protocol PairingEndpointRediscovering: AnyObject {
    func rediscoverEndpoint(
        macDeviceId: String,
        publicKeyFingerprint: String,
        timeout: Duration
    ) async throws -> MacEndpoint
}

public enum BonjourRediscoveryError: Error, Equatable {
    case notFound
    case timeout
    case searchFailed
}

public final class BonjourRediscoveryService: BonjourRediscovering {
    public static let serviceType = "_facepass._tcp."
    public static let serviceDomain = "local."

    public init() {}

    public func rediscoverEndpoint(
        for mac: PairedMac,
        timeout: Duration = .seconds(3)
    ) async throws -> MacEndpoint {
        try await rediscoverEndpoint(
            macDeviceId: mac.macDeviceId,
            publicKeyFingerprint: mac.publicKeyFingerprint,
            timeout: timeout
        )
    }

    public func rediscoverEndpoint(
        macDeviceId: String,
        publicKeyFingerprint: String,
        timeout: Duration = .seconds(3)
    ) async throws -> MacEndpoint {
        let lookup = BonjourEndpointLookup(
            macDeviceId: macDeviceId,
            publicKeyFingerprint: publicKeyFingerprint,
            timeout: timeout
        )
        return try await lookup.start()
    }
}

extension BonjourRediscoveryService: PairingEndpointRediscovering {}

private final class BonjourEndpointLookup: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let macDeviceId: String
    private let publicKeyFingerprint: String
    private let timeout: Duration
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<MacEndpoint, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var hasFinished = false

    init(macDeviceId: String, publicKeyFingerprint: String, timeout: Duration) {
        self.macDeviceId = macDeviceId
        self.publicKeyFingerprint = publicKeyFingerprint
        self.timeout = timeout
    }

    func start() async throws -> MacEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            timeoutTask = Task { [weak self] in
                guard let self else {
                    return
                }
                do {
                    try await Task.sleep(for: self.timeout)
                    self.finish(.failure(BonjourRediscoveryError.timeout))
                } catch {}
            }
            browser.searchForServices(
                ofType: BonjourRediscoveryService.serviceType,
                inDomain: BonjourRediscoveryService.serviceDomain
            )
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(.failure(BonjourRediscoveryError.searchFailed))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard matchesTarget(sender) else {
            return
        }

        guard let host = resolvedHost(from: sender), sender.port > 0 else {
            return
        }

        finish(.success(MacEndpoint(host: host, port: sender.port, scheme: "http")))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if services.allSatisfy({ $0.port == -1 }) {
            finish(.failure(BonjourRediscoveryError.notFound))
        }
    }

    private func matchesTarget(_ service: NetService) -> Bool {
        guard let txtRecordData = service.txtRecordData() else {
            return false
        }

        let txt = NetService.dictionary(fromTXTRecord: txtRecordData)
        return stringValue(for: "macDeviceId", in: txt) == macDeviceId
            && stringValue(for: "publicKeyFingerprint", in: txt) == publicKeyFingerprint
    }

    private func stringValue(for key: String, in txt: [String: Data]) -> String? {
        guard let data = txt[key] else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func resolvedHost(from service: NetService) -> String? {
        BonjourResolvedEndpointHostSelector.resolvedHost(
            hostName: service.hostName,
            addresses: service.addresses ?? []
        )
    }

    private func finish(_ result: Result<MacEndpoint, Error>) {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        timeoutTask?.cancel()
        browser.stop()
        services.removeAll()

        switch result {
        case .success(let endpoint):
            continuation?.resume(returning: endpoint)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

enum BonjourResolvedEndpointHostSelector {
    static func resolvedHost(hostName: String?, addresses: [Data]) -> String? {
        let numericHosts = addresses.compactMap(numericHost)

        if let host = numericHosts.first(where: isIPv4Host) {
            return host
        }

        if let host = numericHosts.first(where: { !isLinkLocalIPv6Host($0) }) {
            return host
        }

        if let hostName, !hostName.isEmpty {
            return hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        }

        return numericHosts.first
    }

    private static func numericHost(from address: Data) -> String? {
        address.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: sockaddr.self).baseAddress else {
                return nil
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                baseAddress,
                socklen_t(address.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                return nil
            }

            let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func isIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else {
            return false
        }

        return parts.allSatisfy { part in
            guard let value = Int(part) else {
                return false
            }
            return value >= 0 && value <= 255
        }
    }

    private static func isLinkLocalIPv6Host(_ host: String) -> Bool {
        host.lowercased().hasPrefix("fe80:")
    }
}
