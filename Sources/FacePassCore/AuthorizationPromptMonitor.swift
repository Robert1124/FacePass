import Foundation

@MainActor
public final class AuthorizationPromptMonitor {
    public static let defaultInterval: TimeInterval = 0.9

    private let interval: TimeInterval
    private let tickHandler: @MainActor () async -> Void
    private var timer: Timer?

    public private(set) var isRunning = false

    public init(
        interval: TimeInterval = 0.9,
        tickHandler: @escaping @MainActor () async -> Void
    ) {
        self.interval = max(0.75, interval)
        self.tickHandler = tickHandler
    }

    public func start() {
        guard timer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        timer.tolerance = min(0.1, interval / 10)
        self.timer = timer
        isRunning = true
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    public func tick() async {
        await tickHandler()
    }
}
