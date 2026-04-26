import XCTest
@testable import FacePassCore

final class ScreenStateMonitorTests: XCTestCase {
    func testEmitsScreenStateEventsToHandler() {
        var receivedEvents: [ScreenStateEvent] = []
        let monitor = ScreenStateMonitor { event in
            receivedEvents.append(event)
        }

        let wakeResult = monitor.emit(.didWake)
        let lockResult = monitor.emit(.userDidLock)

        XCTAssertEqual(wakeResult, .delivered)
        XCTAssertEqual(lockResult, .delivered)
        XCTAssertEqual(receivedEvents, [.didWake, .userDidLock])
    }

    func testNoHandlerDropsEventWithoutStartingRuntimeObservation() {
        let monitor = ScreenStateMonitor()

        let result = monitor.emit(.didWake)

        XCTAssertEqual(result, .noHandler)
        XCTAssertFalse(monitor.isRuntimeObserverActive)
    }

    func testHandlerCanBeReplaced() {
        var firstHandlerCount = 0
        var secondHandlerEvents: [ScreenStateEvent] = []
        let monitor = ScreenStateMonitor { _ in
            firstHandlerCount += 1
        }

        monitor.emit(.didWake)
        monitor.setEventHandler { event in
            secondHandlerEvents.append(event)
        }
        monitor.emit(.userDidLock)

        XCTAssertEqual(firstHandlerCount, 1)
        XCTAssertEqual(secondHandlerEvents, [.userDidLock])
    }

    func testNotificationObserverStartsAndStopsRuntimeActiveState() {
        let monitor = ScreenStateMonitor()
        let observer = ScreenStateNotificationObserver(
            monitor: monitor,
            notificationCenter: NotificationCenter(),
            mappings: [Notification.Name("test.didWake"): .didWake]
        )

        observer.start()

        XCTAssertTrue(monitor.isRuntimeObserverActive)

        observer.stop()

        XCTAssertFalse(monitor.isRuntimeObserverActive)
    }

    func testNotificationObserverStopRemovesInstalledHandlers() {
        let notificationCenter = NotificationCenter()
        let wakeName = Notification.Name("test.didWake")
        var receivedEvents: [ScreenStateEvent] = []
        let monitor = ScreenStateMonitor { event in
            receivedEvents.append(event)
        }
        let observer = ScreenStateNotificationObserver(
            monitor: monitor,
            notificationCenter: notificationCenter,
            mappings: [wakeName: .didWake],
            debounceInterval: 0
        )

        observer.start()
        observer.stop()
        notificationCenter.post(name: wakeName, object: nil)

        XCTAssertEqual(receivedEvents, [])
        XCTAssertFalse(monitor.isRuntimeObserverActive)
    }

    func testNotificationObserverMapsNotificationsToScreenStateEvents() {
        let notificationCenter = NotificationCenter()
        let wakeName = Notification.Name("test.didWake")
        let lockName = Notification.Name("test.userDidLock")
        let unlockName = Notification.Name("test.didUnlock")
        let sleepName = Notification.Name("test.didSleep")
        var receivedEvents: [ScreenStateEvent] = []
        let monitor = ScreenStateMonitor { event in
            receivedEvents.append(event)
        }
        let observer = ScreenStateNotificationObserver(
            monitor: monitor,
            notificationCenter: notificationCenter,
            mappings: [
                wakeName: .didWake,
                lockName: .userDidLock,
                unlockName: .didUnlock,
                sleepName: .didSleep
            ],
            debounceInterval: 0
        )

        observer.start()
        notificationCenter.post(name: wakeName, object: nil)
        notificationCenter.post(name: lockName, object: nil)
        notificationCenter.post(name: unlockName, object: nil)
        notificationCenter.post(name: sleepName, object: nil)

        XCTAssertEqual(receivedEvents, [.didWake, .userDidLock, .didUnlock, .didSleep])
    }

    func testNotificationObserverRepeatedStartDoesNotInstallDuplicateHandlers() {
        let notificationCenter = NotificationCenter()
        let wakeName = Notification.Name("test.didWake")
        var receivedEvents: [ScreenStateEvent] = []
        let monitor = ScreenStateMonitor { event in
            receivedEvents.append(event)
        }
        let observer = ScreenStateNotificationObserver(
            monitor: monitor,
            notificationCenter: notificationCenter,
            mappings: [wakeName: .didWake],
            debounceInterval: 0
        )

        observer.start()
        observer.start()
        notificationCenter.post(name: wakeName, object: nil)

        XCTAssertEqual(receivedEvents, [.didWake])
    }

    func testNotificationObserverDebouncesDuplicateEvents() {
        let notificationCenter = NotificationCenter()
        let wakeName = Notification.Name("test.didWake")
        let screensWakeName = Notification.Name("test.screensDidWake")
        let clock = ManualScreenStateObserverClock(now: Date(timeIntervalSince1970: 10))
        var receivedEvents: [ScreenStateEvent] = []
        let monitor = ScreenStateMonitor { event in
            receivedEvents.append(event)
        }
        let observer = ScreenStateNotificationObserver(
            monitor: monitor,
            notificationCenter: notificationCenter,
            mappings: [
                wakeName: .didWake,
                screensWakeName: .didWake
            ],
            debounceInterval: 0.25,
            clock: clock
        )

        observer.start()
        notificationCenter.post(name: wakeName, object: nil)
        clock.advance(by: 0.1)
        notificationCenter.post(name: screensWakeName, object: nil)
        clock.advance(by: 0.25)
        notificationCenter.post(name: screensWakeName, object: nil)

        XCTAssertEqual(receivedEvents, [.didWake, .didWake])
    }
}

private final class ManualScreenStateObserverClock: ScreenStateObserverClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
