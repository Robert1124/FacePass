import AppKit
import Foundation

public protocol ScreenStateObserverClock {
    var now: Date { get }
}

public struct SystemScreenStateObserverClock: ScreenStateObserverClock {
    public init() {}

    public var now: Date {
        Date()
    }
}

public final class ScreenStateNotificationObserver {
    public static let defaultMacOSMappings: [Notification.Name: ScreenStateEvent] = [
        NSWorkspace.didWakeNotification: .didWake,
        NSWorkspace.screensDidWakeNotification: .didWake,
        NSWorkspace.willSleepNotification: .didSleep,
        NSWorkspace.screensDidSleepNotification: .didSleep,
        NSWorkspace.sessionDidResignActiveNotification: .userDidLock,
        NSWorkspace.sessionDidBecomeActiveNotification: .didUnlock
    ]

    private let monitor: ScreenStateMonitor
    private let notificationCenter: NotificationCenter
    private let mappings: [Notification.Name: ScreenStateEvent]
    private let debounceInterval: TimeInterval
    private let clock: any ScreenStateObserverClock

    private var observerTokens: [NSObjectProtocol] = []
    private var lastDeliveredEvent: (event: ScreenStateEvent, date: Date)?

    public convenience init(monitor: ScreenStateMonitor) {
        self.init(
            monitor: monitor,
            notificationCenter: NSWorkspace.shared.notificationCenter,
            mappings: Self.defaultMacOSMappings
        )
    }

    public init(
        monitor: ScreenStateMonitor,
        notificationCenter: NotificationCenter,
        mappings: [Notification.Name: ScreenStateEvent],
        debounceInterval: TimeInterval = 0.25,
        clock: any ScreenStateObserverClock = SystemScreenStateObserverClock()
    ) {
        self.monitor = monitor
        self.notificationCenter = notificationCenter
        self.mappings = mappings
        self.debounceInterval = max(0, debounceInterval)
        self.clock = clock
    }

    deinit {
        stop()
    }

    public func start() {
        guard observerTokens.isEmpty, !mappings.isEmpty else {
            return
        }

        observerTokens = mappings.map { name, event in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.emit(event)
            }
        }
        monitor.setRuntimeObserverActive(true)
    }

    public func stop() {
        guard !observerTokens.isEmpty else {
            monitor.setRuntimeObserverActive(false)
            return
        }

        observerTokens.forEach(notificationCenter.removeObserver)
        observerTokens = []
        lastDeliveredEvent = nil
        monitor.setRuntimeObserverActive(false)
    }

    private func emit(_ event: ScreenStateEvent) {
        let now = clock.now
        if shouldDebounce(event, at: now) {
            return
        }

        let delivery = monitor.emit(event)
        if delivery == .delivered {
            lastDeliveredEvent = (event, now)
        }
    }

    private func shouldDebounce(_ event: ScreenStateEvent, at date: Date) -> Bool {
        guard debounceInterval > 0,
              let lastDeliveredEvent,
              lastDeliveredEvent.event == event else {
            return false
        }

        let elapsed = date.timeIntervalSince(lastDeliveredEvent.date)
        return elapsed >= 0 && elapsed < debounceInterval
    }
}
