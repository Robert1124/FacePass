import Foundation

public enum ScreenStateEvent: Equatable {
    case didWake
    case userDidLock
    case didUnlock
    case didSleep
}

public enum ScreenStateMonitorDelivery: Equatable {
    case delivered
    case noHandler
}

public final class ScreenStateMonitor {
    private var eventHandler: ((ScreenStateEvent) -> Void)?

    public private(set) var isRuntimeObserverActive = false

    public init(eventHandler: ((ScreenStateEvent) -> Void)? = nil) {
        self.eventHandler = eventHandler
    }

    public func setEventHandler(_ eventHandler: @escaping (ScreenStateEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func setRuntimeObserverActive(_ isRuntimeObserverActive: Bool) {
        self.isRuntimeObserverActive = isRuntimeObserverActive
    }

    @discardableResult
    public func emit(_ event: ScreenStateEvent) -> ScreenStateMonitorDelivery {
        guard let eventHandler else {
            return .noHandler
        }

        eventHandler(event)
        return .delivered
    }
}
