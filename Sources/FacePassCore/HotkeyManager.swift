import Foundation
#if os(macOS)
import Carbon
#endif

public final class HotkeyManager {
    private var registrations: [HotkeyRegistrationID: HotkeyRegistration] = [:]
    private var nextRuntimeEventID: UInt32 = 1
    private let runtime: HotkeyRuntimeRegistering?

    public init() {
        self.runtime = nil
    }

    init(runtime: HotkeyRuntimeRegistering?) {
        self.runtime = runtime
    }

    public static func system() -> HotkeyManager {
        #if os(macOS)
        HotkeyManager(runtime: CarbonHotkeyRuntime())
        #else
        HotkeyManager()
        #endif
    }

    @discardableResult
    public func register(
        _ descriptor: HotkeyDescriptor,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> HotkeyRegistrationToken {
        let id = HotkeyRegistrationID()
        let eventID = nextRuntimeEventID
        nextRuntimeEventID += 1
        registrations[id] = HotkeyRegistration(
            descriptor: descriptor,
            isEnabled: enabled,
            runtimeEventID: eventID,
            runtimeToken: nil,
            runtimeRegistrationState: enabled ? .unavailable : .disabled,
            handler: handler
        )
        if enabled {
            registerRuntimeIfNeeded(for: id)
        }
        return HotkeyRegistrationToken(
            id: id,
            runtimeRegistrationState: registrations[id]?.runtimeRegistrationState ?? .unavailable
        )
    }

    public func unregister(_ id: HotkeyRegistrationID) {
        unregisterRuntimeIfNeeded(for: id)
        registrations[id] = nil
    }

    public func setEnabled(_ isEnabled: Bool, for id: HotkeyRegistrationID) {
        guard var registration = registrations[id] else {
            return
        }
        registration.isEnabled = isEnabled
        if !isEnabled {
            registration.runtimeRegistrationState = .disabled
        }
        registrations[id] = registration
        if isEnabled {
            registerRuntimeIfNeeded(for: id)
        } else {
            unregisterRuntimeIfNeeded(for: id)
        }
    }

    public func runtimeRegistrationState(for id: HotkeyRegistrationID) -> HotkeyRuntimeRegistrationState? {
        registrations[id]?.runtimeRegistrationState
    }

    @discardableResult
    public func dispatch(_ id: HotkeyRegistrationID) -> HotkeyDispatchResult {
        guard let registration = registrations[id] else {
            return .notRegistered
        }

        guard registration.isEnabled else {
            return .disabled
        }

        registration.handler()
        return .handled
    }

    private func registerRuntimeIfNeeded(for id: HotkeyRegistrationID) {
        guard var registration = registrations[id],
              registration.isEnabled,
              registration.runtimeToken == nil else {
            return
        }

        guard let runtime else {
            registration.runtimeRegistrationState = .unavailable
            registrations[id] = registration
            return
        }

        let result = runtime.register(
            registration.descriptor,
            eventID: registration.runtimeEventID
        ) { [weak self] in
            _ = self?.dispatch(id)
        }

        registration.runtimeRegistrationState = result.state
        registration.runtimeToken = result.token
        registrations[id] = registration
    }

    private func unregisterRuntimeIfNeeded(for id: HotkeyRegistrationID) {
        guard var registration = registrations[id],
              let runtimeToken = registration.runtimeToken else {
            return
        }

        runtimeToken.unregister()
        registration.runtimeToken = nil
        if registration.isEnabled {
            registration.runtimeRegistrationState = .unavailable
        }
        registrations[id] = registration
    }
}

public struct HotkeyDescriptor: Equatable {
    public let keyCode: UInt16
    public let modifiers: Set<HotkeyModifier>

    public init(keyCode: UInt16, modifiers: Set<HotkeyModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultManualFill = HotkeyDescriptor(
        keyCode: 35,
        modifiers: [.control, .option, .command]
    )

    public var displayName: String {
        (orderedModifierDisplayNames + [keyDisplayName]).joined(separator: "-")
    }

    private var orderedModifierDisplayNames: [String] {
        [
            (.control, "Control"),
            (.option, "Option"),
            (.command, "Command"),
            (.shift, "Shift")
        ].compactMap { modifier, displayName in
            modifiers.contains(modifier) ? displayName : nil
        }
    }

    private var keyDisplayName: String {
        switch keyCode {
        case 35:
            "P"
        default:
            "Key \(keyCode)"
        }
    }
}

public enum HotkeyModifier: Equatable, Hashable {
    case command
    case option
    case control
    case shift
}

public struct HotkeyRegistrationToken: Equatable {
    public let id: HotkeyRegistrationID
    public let runtimeRegistrationState: HotkeyRuntimeRegistrationState
}

public struct HotkeyRegistrationID: Equatable, Hashable {
    private let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum HotkeyDispatchResult: Equatable {
    case handled
    case disabled
    case notRegistered
}

public enum HotkeyRuntimeRegistrationState: Equatable {
    case registered
    case disabled
    case unavailable
    case failed
}

private struct HotkeyRegistration {
    let descriptor: HotkeyDescriptor
    var isEnabled: Bool
    let runtimeEventID: UInt32
    var runtimeToken: HotkeyRuntimeToken?
    var runtimeRegistrationState: HotkeyRuntimeRegistrationState
    let handler: () -> Void
}

protocol HotkeyRuntimeRegistering {
    func register(
        _ descriptor: HotkeyDescriptor,
        eventID: UInt32,
        handler: @escaping () -> Void
    ) -> HotkeyRuntimeRegistration
}

struct HotkeyRuntimeRegistration {
    let state: HotkeyRuntimeRegistrationState
    let token: HotkeyRuntimeToken?

    static func registered(_ token: HotkeyRuntimeToken) -> HotkeyRuntimeRegistration {
        HotkeyRuntimeRegistration(state: .registered, token: token)
    }

    static let unavailable = HotkeyRuntimeRegistration(state: .unavailable, token: nil)
    static let failed = HotkeyRuntimeRegistration(state: .failed, token: nil)
}

struct HotkeyRuntimeToken {
    let unregister: () -> Void

    init(unregister: @escaping () -> Void) {
        self.unregister = unregister
    }
}

#if os(macOS)
private final class CarbonHotkeyRuntime: HotkeyRuntimeRegistering {
    private let signature = OSType(
        (UInt32(Character("F").asciiValue!) << 24) |
        (UInt32(Character("P").asciiValue!) << 16) |
        (UInt32(Character("A").asciiValue!) << 8) |
        UInt32(Character("S").asciiValue!)
    )
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let lock = NSLock()

    deinit {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(
        _ descriptor: HotkeyDescriptor,
        eventID: UInt32,
        handler: @escaping () -> Void
    ) -> HotkeyRuntimeRegistration {
        guard installEventHandlerIfNeeded() else {
            return .failed
        }

        let hotkeyID = EventHotKeyID(signature: signature, id: eventID)
        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(descriptor.keyCode),
            descriptor.carbonModifierFlags,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard status == noErr, let hotkeyRef else {
            return .failed
        }

        lock.lock()
        handlers[eventID] = handler
        lock.unlock()

        return .registered(
            HotkeyRuntimeToken { [weak self] in
                UnregisterEventHotKey(hotkeyRef)
                self?.removeHandler(for: eventID)
            }
        )
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else {
            return true
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        return status == noErr
    }

    private func removeHandler(for eventID: UInt32) {
        lock.lock()
        handlers[eventID] = nil
        lock.unlock()
    }

    fileprivate func dispatch(eventID: UInt32) {
        lock.lock()
        let handler = handlers[eventID]
        lock.unlock()
        handler?()
    }
}

private let carbonHotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )

    guard status == noErr else {
        return status
    }

    let runtime = Unmanaged<CarbonHotkeyRuntime>
        .fromOpaque(userData)
        .takeUnretainedValue()
    runtime.dispatch(eventID: hotkeyID.id)
    return noErr
}

private extension HotkeyDescriptor {
    var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }
}
#endif
