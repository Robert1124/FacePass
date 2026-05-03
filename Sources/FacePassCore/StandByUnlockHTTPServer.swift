import Foundation
import Darwin
import Network
import SystemConfiguration

public struct StandByHTTPServerRequest: Equatable {
    public let method: String
    public let path: String
    public let body: Data?

    public init(method: String, path: String, body: Data?) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct StandByHTTPServerResponse: Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum StandByUnlockHTTPServerStatus: String, Equatable {
    case starting
    case ready
    case failed
    case stopped
}

public protocol StandByHTTPServerStatusProviding: AnyObject {
    var httpStatus: StandByUnlockHTTPServerStatus { get }
    var bonjourStatusDescription: String? { get }
}

public final class StandByUnlockHTTPRouter {
    private let macDeviceId: String
    private let protocolVersion: Int
    private let serverStatus: () -> StandByUnlockHTTPServerStatus
    private let publicKeyFingerprint: String
    private let isIPhoneUnlockEnabled: () -> Bool
    private let pairingController: StandByUnlockPairingController
    private let unlockHandler: (StandByUnlockRequest) async -> StandByUnlockAttemptStatus
    private let pairingDidChange: (StandByIPhonePairingResult) -> Void

    public init(
        macDeviceId: String,
        protocolVersion: Int,
        serverStatus: StandByUnlockHTTPServerStatus,
        publicKeyFingerprint: String,
        isIPhoneUnlockEnabled: @escaping () -> Bool,
        pairingController: StandByUnlockPairingController,
        unlockHandler: @escaping (StandByUnlockRequest) async -> StandByUnlockAttemptStatus,
        pairingDidChange: @escaping (StandByIPhonePairingResult) -> Void = { _ in }
    ) {
        self.macDeviceId = macDeviceId
        self.protocolVersion = protocolVersion
        self.serverStatus = { serverStatus }
        self.publicKeyFingerprint = publicKeyFingerprint
        self.isIPhoneUnlockEnabled = isIPhoneUnlockEnabled
        self.pairingController = pairingController
        self.unlockHandler = unlockHandler
        self.pairingDidChange = pairingDidChange
    }

    public init(
        macDeviceId: String,
        protocolVersion: Int,
        serverStatus: @escaping () -> StandByUnlockHTTPServerStatus,
        publicKeyFingerprint: String,
        isIPhoneUnlockEnabled: @escaping () -> Bool,
        pairingController: StandByUnlockPairingController,
        unlockHandler: @escaping (StandByUnlockRequest) async -> StandByUnlockAttemptStatus,
        pairingDidChange: @escaping (StandByIPhonePairingResult) -> Void = { _ in }
    ) {
        self.macDeviceId = macDeviceId
        self.protocolVersion = protocolVersion
        self.serverStatus = serverStatus
        self.publicKeyFingerprint = publicKeyFingerprint
        self.isIPhoneUnlockEnabled = isIPhoneUnlockEnabled
        self.pairingController = pairingController
        self.unlockHandler = unlockHandler
        self.pairingDidChange = pairingDidChange
    }

    public func handle(_ request: StandByHTTPServerRequest) async -> StandByHTTPServerResponse {
        switch (request.method.uppercased(), request.path) {
        case ("GET", "/v1/status"):
            return jsonResponse(statusCode: 200, payload: [
                "macDeviceId": macDeviceId,
                "protocolVersion": protocolVersion,
                "serverStatus": serverStatus().rawValue,
                "publicKeyFingerprint": publicKeyFingerprint,
                "whetherIPhoneUnlockEnabled": isIPhoneUnlockEnabled()
            ])
        case ("POST", "/v1/pair"):
            return handlePair(request)
        case ("POST", "/v1/standby-unlock"):
            return await handleStandByUnlock(request)
        case (_, "/v1/status"), (_, "/v1/pair"), (_, "/v1/standby-unlock"):
            return errorResponse(statusCode: 405, errorCode: "method_not_allowed")
        default:
            return errorResponse(statusCode: 404, errorCode: "not_found")
        }
    }

    private func handlePair(_ request: StandByHTTPServerRequest) -> StandByHTTPServerResponse {
        guard let body = request.body else {
            return errorResponse(statusCode: 400, errorCode: "invalid_request")
        }

        do {
            let registration = try standbyJSONDecoder().decode(
                StandByIPhonePairingRegistration.self,
                from: body
            )
            let result = try pairingController.registerIPhone(registration)
            pairingDidChange(result)
            return jsonResponse(statusCode: 200, payload: [
                "ok": true,
                "result": "paired",
                "iphoneDeviceId": result.iphoneDeviceId,
                "displayName": result.displayName
            ])
        } catch let error as StandByUnlockPairingError {
            return errorResponse(statusCode: 403, errorCode: httpErrorCode(for: error))
        } catch {
            return errorResponse(statusCode: 400, errorCode: "invalid_request")
        }
    }

    private func handleStandByUnlock(_ request: StandByHTTPServerRequest) async -> StandByHTTPServerResponse {
        guard let body = request.body else {
            return errorResponse(statusCode: 400, errorCode: "invalid_request")
        }

        let standbyRequest: StandByUnlockRequest
        do {
            standbyRequest = try standbyJSONDecoder().decode(StandByUnlockRequest.self, from: body)
        } catch {
            return errorResponse(statusCode: 400, errorCode: "invalid_request")
        }

        let status = await unlockHandler(standbyRequest)
        switch status {
        case .unlockResult(.typedPasswordAndSubmitted):
            return jsonResponse(statusCode: 200, payload: [
                "ok": true,
                "result": "unlock_requested"
            ])
        case .authorizationPromptFillResult(.filled):
            return jsonResponse(statusCode: 200, payload: [
                "ok": true,
                "result": "authorization_prompt_filled"
            ])
        case .disabled:
            return errorResponse(statusCode: 403, errorCode: "disabled")
        case .providerPolicyRejected:
            return errorResponse(statusCode: 403, errorCode: "disabled")
        case .conditionsNotSatisfied:
            return errorResponse(statusCode: 403, errorCode: "conditions_not_satisfied")
        case .verificationFailed(let error):
            return errorResponse(statusCode: 403, errorCode: httpErrorCode(for: error))
        case .unlockResult(let result):
            return errorResponse(statusCode: 403, errorCode: httpErrorCode(for: result))
        case .authorizationPromptFillResult(let result):
            return errorResponse(statusCode: 403, errorCode: httpErrorCode(for: result))
        }
    }

    private func httpErrorCode(for error: StandByUnlockPairingError) -> String {
        switch error {
        case .invalidOneTimeToken:
            "invalid_token"
        case .expiredOneTimeToken:
            "expired_token"
        case .invalidPublicKey:
            "invalid_public_key"
        case .storeFailed:
            "network_error"
        }
    }

    private func httpErrorCode(for error: StandByUnlockVerificationError) -> String {
        switch error {
        case .unpairedIPhone:
            "not_paired"
        case .disabledIPhone:
            "disabled"
        case .invalidSignature, .missingSignature, .invalidPublicKey:
            "invalid_signature"
        case .expiredRequest, .futureRequest, .excessiveValidityWindow:
            "expired"
        case .replayedRequestId, .staleCounter:
            "replay_detected"
        case .wrongMacDevice:
            "wrong_mac"
        case .unsupportedType, .unsupportedProtocolVersion, .unsupportedAction:
            "invalid_request"
        case .replayStoreFailed:
            "network_error"
        }
    }

    private func httpErrorCode(for result: LockScreenUnlockResult) -> String {
        switch result {
        case .typedPasswordAndSubmitted:
            "unlock_requested"
        case .disabled:
            "disabled"
        case .accessibilityPermissionDenied:
            "accessibility_denied"
        case .sessionNotLocked:
            "mac_not_locked"
        case .missingPassword:
            "password_missing"
        case .passwordReadFailed, .typingFailed:
            "unlock_failed"
        }
    }

    private func httpErrorCode(for result: ManualFillResult) -> String {
        switch result {
        case .filled:
            "authorization_prompt_filled"
        case .missingPassword:
            "password_missing"
        case .accessibilityPermissionDenied:
            "accessibility_denied"
        case .noFocusedPasswordField:
            "mac_not_locked"
        case .focusedPasswordFieldUnavailable, .multipleApprovedPasswordFields:
            "unlock_failed"
        case .passwordReadFailed:
            "password_missing"
        case .recognitionRejected, .localRecognitionDisabled:
            "disabled"
        }
    }

    private func jsonResponse(statusCode: Int, payload: [String: Any]) -> StandByHTTPServerResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return StandByHTTPServerResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    private func errorResponse(statusCode: Int, errorCode: String) -> StandByHTTPServerResponse {
        jsonResponse(statusCode: statusCode, payload: [
            "ok": false,
            "errorCode": errorCode
        ])
    }
}

public final class StandByUnlockHTTPServer {
    private let router: StandByUnlockHTTPRouter
    private let macDeviceId: String
    private let publicKeyFingerprint: String
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var currentStatus: StandByUnlockHTTPServerStatus = .stopped

    public init(
        router: StandByUnlockHTTPRouter,
        macDeviceId: String,
        publicKeyFingerprint: String,
        queue: DispatchQueue = DispatchQueue(label: "FacePass.StandByUnlockHTTPServer")
    ) {
        self.router = router
        self.macDeviceId = macDeviceId
        self.publicKeyFingerprint = publicKeyFingerprint
        self.queue = queue
    }

    public var status: StandByUnlockHTTPServerStatus {
        queue.sync { currentStatus }
    }

    public var localEndpoint: StandByPairingEndpoint? {
        let port = queue.sync { listener?.port?.rawValue }
        guard let port, let host = Self.preferredLANIPv4Address() else {
            return nil
        }

        return StandByPairingEndpoint(host: host, port: Int(port), scheme: "http")
    }

    public func start() throws {
        guard listener == nil else {
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: nil,
            type: "_facepass._tcp",
            domain: "local",
            txtRecord: NWTXTRecord([
                "macDeviceId": macDeviceId,
                "publicKeyFingerprint": publicKeyFingerprint
            ])
        )
        listener.stateUpdateHandler = { [weak self] state in
            self?.setStatus(for: state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        self.listener = listener
        setStatus(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        setStatus(.stopped)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = Self.parseHTTPRequest(from: nextBuffer) {
                Task {
                    let response = await self.router.handle(request)
                    self.send(response, on: connection)
                }
                return
            }

            if isComplete || nextBuffer.count > 256 * 1024 {
                self.send(Self.malformedRequestResponse(), on: connection)
                return
            }

            self.receive(connection: connection, buffer: nextBuffer)
        }
    }

    private func send(_ response: StandByHTTPServerResponse, on connection: NWConnection) {
        let responseData = Self.serializedHTTPResponse(response)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func setStatus(for state: NWListener.State) {
        switch state {
        case .ready:
            setStatus(.ready)
        case .failed:
            setStatus(.failed)
        case .cancelled:
            setStatus(.stopped)
        case .setup, .waiting:
            setStatus(.starting)
        @unknown default:
            setStatus(.failed)
        }
    }

    private func setStatus(_ status: StandByUnlockHTTPServerStatus) {
        queue.async {
            self.currentStatus = status
        }
    }

    private static func parseHTTPRequest(from data: Data) -> StandByHTTPServerRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return StandByHTTPServerRequest(method: "GET", path: "/malformed", body: nil)
        }

        let headerLines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return StandByHTTPServerRequest(method: "GET", path: "/malformed", body: nil)
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return StandByHTTPServerRequest(method: "GET", path: "/malformed", body: nil)
        }

        let contentLength = headerLines.dropFirst().reduce(0) { current, line in
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else {
                return current
            }
            return Int(parts[1]) ?? current
        }

        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let body = contentLength > 0
            ? Data(data[bodyStart..<(bodyStart + contentLength)])
            : nil
        let path = requestParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestParts[1]
        return StandByHTTPServerRequest(method: requestParts[0], path: path, body: body)
    }

    private static func serializedHTTPResponse(_ response: StandByHTTPServerResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"

        var responseText = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            responseText += "\(key): \(value)\r\n"
        }
        responseText += "\r\n"

        var data = Data(responseText.utf8)
        data.append(response.body)
        return data
    }

    private static func malformedRequestResponse() -> StandByHTTPServerResponse {
        let body = try? JSONSerialization.data(withJSONObject: [
            "ok": false,
            "errorCode": "invalid_request"
        ])
        return StandByHTTPServerResponse(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: body ?? Data()
        )
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            "OK"
        case 400:
            "Bad Request"
        case 403:
            "Forbidden"
        case 404:
            "Not Found"
        case 405:
            "Method Not Allowed"
        default:
            "OK"
        }
    }

    private static func preferredLANIPv4Address() -> String? {
        StandByLocalEndpointSelector.preferredHost(
            from: localIPv4AddressCandidates(),
            defaultRouteInterface: defaultRouteInterfaceName()
        )
    }

    private static func localIPv4AddressCandidates() -> [StandByLocalIPv4Address] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [StandByLocalIPv4Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = current.pointee.ifa_flags
            guard let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  let host = numericIPv4Host(from: address) else {
                continue
            }

            let interfaceName = String(cString: current.pointee.ifa_name)
            candidates.append(StandByLocalIPv4Address(
                interfaceName: interfaceName,
                host: host,
                isUp: flags & UInt32(IFF_UP) != 0,
                isLoopback: flags & UInt32(IFF_LOOPBACK) != 0,
                isPointToPoint: flags & UInt32(IFF_POINTOPOINT) != 0
            ))
        }

        return candidates
    }

    private static func defaultRouteInterfaceName() -> String? {
        guard let globalIPv4 = SCDynamicStoreCopyValue(
            nil,
            "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any] else {
            return nil
        }

        return globalIPv4["PrimaryInterface"] as? String
    }

    private static func numericIPv4Host(from address: UnsafePointer<sockaddr>) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
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

struct StandByLocalIPv4Address: Equatable {
    let interfaceName: String
    let host: String
    let isUp: Bool
    let isLoopback: Bool
    let isPointToPoint: Bool

    init(
        interfaceName: String,
        host: String,
        isUp: Bool = true,
        isLoopback: Bool = false,
        isPointToPoint: Bool = false
    ) {
        self.interfaceName = interfaceName
        self.host = host
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
    }
}

enum StandByLocalEndpointSelector {
    static func preferredHost(
        from candidates: [StandByLocalIPv4Address],
        defaultRouteInterface: String?
    ) -> String? {
        let usableCandidates = candidates.filter(isUsable)

        if let defaultRouteInterface {
            let defaultRouteCandidates = usableCandidates.filter {
                $0.interfaceName == defaultRouteInterface
            }
            if let host = defaultRouteCandidates.first(where: { isPrivateLANIPv4($0.host) })?.host {
                return host
            }
            if let host = defaultRouteCandidates.first(where: { !isLinkLocalIPv4($0.host) })?.host {
                return host
            }
        }

        if let host = usableCandidates.first(where: {
            isPreferredPhysicalInterface($0.interfaceName) && isPrivateLANIPv4($0.host)
        })?.host {
            return host
        }

        if let host = usableCandidates.first(where: {
            !isLikelyVirtualInterface($0.interfaceName) && isPrivateLANIPv4($0.host)
        })?.host {
            return host
        }

        if let host = usableCandidates.first(where: { isPrivateLANIPv4($0.host) })?.host {
            return host
        }

        return usableCandidates.first(where: { !isLinkLocalIPv4($0.host) })?.host
    }

    private static func isUsable(_ candidate: StandByLocalIPv4Address) -> Bool {
        candidate.isUp &&
            !candidate.isLoopback &&
            !candidate.isPointToPoint &&
            !candidate.host.hasPrefix("127.")
    }

    private static func isPreferredPhysicalInterface(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("en") || interfaceName.hasPrefix("eth")
    }

    private static func isLikelyVirtualInterface(_ interfaceName: String) -> Bool {
        let virtualPrefixes = ["awdl", "bridge", "feth", "llw", "utun", "vnic", "vmnet"]
        return virtualPrefixes.contains { interfaceName.hasPrefix($0) }
    }

    private static func isLinkLocalIPv4(_ host: String) -> Bool {
        host.hasPrefix("169.254.")
    }

    private static func isPrivateLANIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            return false
        }

        if parts[0] == 10 {
            return true
        }

        if parts[0] == 172, (16...31).contains(parts[1]) {
            return true
        }

        return parts[0] == 192 && parts[1] == 168
    }
}

private func standbyJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.dataDecodingStrategy = .base64
    return decoder
}
