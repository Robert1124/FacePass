import XCTest
@testable import FacePassCore

final class HotkeyManagerTests: XCTestCase {
    func testDispatchInvokesRegisteredEnabledHandler() {
        let manager = HotkeyManager()
        let hotkey = HotkeyDescriptor(keyCode: 12, modifiers: [.command, .option])
        var invocationCount = 0

        let registration = manager.register(hotkey) {
            invocationCount += 1
        }

        XCTAssertEqual(manager.dispatch(registration.id), .handled)
        XCTAssertEqual(invocationCount, 1)
    }

    func testDisabledRegistrationDoesNotInvokeHandler() {
        let manager = HotkeyManager()
        let hotkey = HotkeyDescriptor(keyCode: 12, modifiers: [.command])
        var invocationCount = 0

        let registration = manager.register(hotkey) {
            invocationCount += 1
        }
        manager.setEnabled(false, for: registration.id)

        XCTAssertEqual(manager.dispatch(registration.id), .disabled)
        XCTAssertEqual(invocationCount, 0)
    }

    func testUnregisterPreventsDispatch() {
        let manager = HotkeyManager()
        let hotkey = HotkeyDescriptor(keyCode: 12, modifiers: [.control])
        var invocationCount = 0

        let registration = manager.register(hotkey) {
            invocationCount += 1
        }
        manager.unregister(registration.id)

        XCTAssertEqual(manager.dispatch(registration.id), .notRegistered)
        XCTAssertEqual(invocationCount, 0)
    }

    func testRuntimeRegistrationUsesSystemHandlerToDispatchRegisteredHotkey() {
        let runtime = RecordingHotkeyRuntime()
        let manager = HotkeyManager(runtime: runtime)
        let hotkey = HotkeyDescriptor(keyCode: 35, modifiers: [.command, .option, .control])
        var invocationCount = 0

        let registration = manager.register(hotkey) {
            invocationCount += 1
        }

        XCTAssertEqual(registration.runtimeRegistrationState, .registered)
        XCTAssertEqual(manager.runtimeRegistrationState(for: registration.id), .registered)
        XCTAssertEqual(runtime.registrations.map(\.descriptor), [hotkey])

        runtime.trigger(eventID: runtime.registrations[0].eventID)

        XCTAssertEqual(invocationCount, 1)
    }

    func testDisabledRegistrationDoesNotRegisterRuntimeUntilEnabled() {
        let runtime = RecordingHotkeyRuntime()
        let manager = HotkeyManager(runtime: runtime)
        let hotkey = HotkeyDescriptor(keyCode: 35, modifiers: [.command, .option, .control])
        var invocationCount = 0

        let registration = manager.register(hotkey, enabled: false) {
            invocationCount += 1
        }

        XCTAssertEqual(registration.runtimeRegistrationState, .disabled)
        XCTAssertEqual(manager.runtimeRegistrationState(for: registration.id), .disabled)
        XCTAssertTrue(runtime.registrations.isEmpty)

        manager.setEnabled(true, for: registration.id)

        XCTAssertEqual(manager.runtimeRegistrationState(for: registration.id), .registered)
        XCTAssertEqual(runtime.registrations.count, 1)

        runtime.trigger(eventID: runtime.registrations[0].eventID)

        XCTAssertEqual(invocationCount, 1)

        manager.setEnabled(false, for: registration.id)

        XCTAssertEqual(manager.runtimeRegistrationState(for: registration.id), .disabled)
        XCTAssertEqual(runtime.unregisteredEventIDs, [runtime.registrations[0].eventID])
    }

    func testRuntimeRegistrationFailureLeavesRegistrationFailedWithoutInvokingSystemHandler() {
        let runtime = RecordingHotkeyRuntime(registrationResult: .failed)
        let manager = HotkeyManager(runtime: runtime)
        let hotkey = HotkeyDescriptor(keyCode: 35, modifiers: [.command, .option, .control])
        var invocationCount = 0

        let registration = manager.register(hotkey) {
            invocationCount += 1
        }

        XCTAssertEqual(registration.runtimeRegistrationState, .failed)
        XCTAssertEqual(manager.runtimeRegistrationState(for: registration.id), .failed)
        XCTAssertTrue(runtime.registrations.isEmpty)
        XCTAssertEqual(invocationCount, 0)

        XCTAssertEqual(manager.dispatch(registration.id), .handled)
        XCTAssertEqual(invocationCount, 1)
    }

    func testDefaultManualFillHotkeyUsesConservativeShortcutDisplayName() {
        XCTAssertEqual(
            HotkeyDescriptor.defaultManualFill,
            HotkeyDescriptor(keyCode: 35, modifiers: [.command, .option, .control])
        )
        XCTAssertEqual(HotkeyDescriptor.defaultManualFill.displayName, "Control-Option-Command-P")
    }
}

enum RecordingHotkeyRuntimeResult {
    case registered
    case unavailable
    case failed
}

final class RecordingHotkeyRuntime: HotkeyRuntimeRegistering {
    struct Registration {
        let descriptor: HotkeyDescriptor
        let eventID: UInt32
        let handler: () -> Void
    }

    private let registrationResult: RecordingHotkeyRuntimeResult
    private(set) var registrations: [Registration] = []
    private(set) var unregisteredEventIDs: [UInt32] = []

    init(registrationResult: RecordingHotkeyRuntimeResult = .registered) {
        self.registrationResult = registrationResult
    }

    func register(
        _ descriptor: HotkeyDescriptor,
        eventID: UInt32,
        handler: @escaping () -> Void
    ) -> HotkeyRuntimeRegistration {
        switch registrationResult {
        case .registered:
            registrations.append(Registration(descriptor: descriptor, eventID: eventID, handler: handler))
            return .registered(
                HotkeyRuntimeToken {
                    self.unregisteredEventIDs.append(eventID)
                }
            )
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        }
    }

    func trigger(eventID: UInt32) {
        registrations.first { $0.eventID == eventID }?.handler()
    }
}
