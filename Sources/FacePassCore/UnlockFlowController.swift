import Foundation

public protocol UnlockClock {
    var now: Date { get }
}

public protocol UnlockScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
}

public protocol UnlockPermissionProviding {
    func currentUnlockPermissions() -> UnlockPermissionState
}

public protocol UnlockConditionEvaluating {
    func evaluateUnlockConditions() -> UnlockConditionDecision
}

public protocol UnlockPasswordProviding {
    func passwordForUnlock() -> String?
}

public protocol UnlockAutofilling {
    func fillPasswordValue(_ password: String) -> UnlockAutofillOutcome
}

public final class UnlockFlowController {
    private let policy: UnlockFlowPolicy
    private let permissionProvider: any UnlockPermissionProviding
    private let conditionEvaluator: any UnlockConditionEvaluating
    private let passwordProvider: any UnlockPasswordProviding
    private let autofillService: any UnlockAutofilling
    private let clock: any UnlockClock
    private let scheduler: any UnlockScheduler

    private var wakeDelayUntil: Date?
    private var lastUserLockDate: Date?

    public private(set) var lastAutomaticOutcome: UnlockFlowOutcome?

    public init(
        policy: UnlockFlowPolicy,
        permissionProvider: any UnlockPermissionProviding,
        conditionEvaluator: any UnlockConditionEvaluating,
        passwordProvider: any UnlockPasswordProviding,
        autofillService: any UnlockAutofilling,
        clock: any UnlockClock,
        scheduler: any UnlockScheduler
    ) {
        self.policy = policy
        self.permissionProvider = permissionProvider
        self.conditionEvaluator = conditionEvaluator
        self.passwordProvider = passwordProvider
        self.autofillService = autofillService
        self.clock = clock
        self.scheduler = scheduler
    }

    @discardableResult
    public func handleScreenEvent(_ event: ScreenStateEvent) -> UnlockFlowOutcome? {
        switch event {
        case .didWake:
            wakeDelayUntil = clock.now.addingTimeInterval(policy.wakeDelay)
            scheduler.schedule(after: policy.wakeDelay) { [weak self] in
                guard let self else {
                    return
                }
                self.wakeDelayUntil = nil
                self.lastAutomaticOutcome = self.requestUnlock(.automatic)
            }
            return .deferred(.wakeDelayPending)
        case .userDidLock:
            lastUserLockDate = clock.now
            return nil
        case .didUnlock, .didSleep:
            return nil
        }
    }

    @discardableResult
    public func requestUnlock(_ request: UnlockRequestKind) -> UnlockFlowOutcome {
        if request == .automatic {
            if isWakeDelayPending {
                return recordAutomaticOutcome(.deferred(.wakeDelayPending), for: request)
            }

            if isPostLockCooldownActive {
                return recordAutomaticOutcome(.denied(.postLockCooldownActive), for: request)
            }
        }

        guard permissionProvider.currentUnlockPermissions().allRequiredAvailable else {
            return recordAutomaticOutcome(.denied(.requiredPermissionsUnavailable), for: request)
        }

        guard conditionEvaluator.evaluateUnlockConditions().isEligibleForAutoUnlock else {
            return recordAutomaticOutcome(.denied(.conditionsIneligible), for: request)
        }

        guard let password = passwordProvider.passwordForUnlock(), !password.isEmpty else {
            return recordAutomaticOutcome(.denied(.passwordUnavailable), for: request)
        }

        let outcome: UnlockFlowOutcome
        switch autofillService.fillPasswordValue(password) {
        case .filled:
            outcome = .filled
        case .failed:
            outcome = .autofillFailed
        }

        return recordAutomaticOutcome(outcome, for: request)
    }

    private var isWakeDelayPending: Bool {
        guard let wakeDelayUntil else {
            return false
        }
        return clock.now < wakeDelayUntil
    }

    private var isPostLockCooldownActive: Bool {
        guard let lastUserLockDate else {
            return false
        }
        return clock.now.timeIntervalSince(lastUserLockDate) < policy.postLockCooldown
    }

    private func recordAutomaticOutcome(
        _ outcome: UnlockFlowOutcome,
        for request: UnlockRequestKind
    ) -> UnlockFlowOutcome {
        if request == .automatic {
            lastAutomaticOutcome = outcome
        }
        return outcome
    }
}

public struct UnlockFlowPolicy: Equatable {
    public let wakeDelay: TimeInterval
    public let postLockCooldown: TimeInterval

    public init(wakeDelay: TimeInterval, postLockCooldown: TimeInterval) {
        self.wakeDelay = max(0, wakeDelay)
        self.postLockCooldown = max(0, postLockCooldown)
    }
}

public enum UnlockRequestKind: Equatable {
    case automatic
    case manual
}

public enum UnlockFlowOutcome: Equatable {
    case deferred(UnlockFlowDeferralReason)
    case denied(UnlockFlowDenialReason)
    case filled
    case autofillFailed
}

public enum UnlockFlowDeferralReason: Equatable {
    case wakeDelayPending
}

public enum UnlockFlowDenialReason: Equatable {
    case requiredPermissionsUnavailable
    case conditionsIneligible
    case postLockCooldownActive
    case passwordUnavailable
}

public struct UnlockPermissionState: Equatable {
    public let unavailableRequiredPermissions: Set<UnlockRequiredPermission>

    public init(unavailableRequiredPermissions: Set<UnlockRequiredPermission> = []) {
        self.unavailableRequiredPermissions = unavailableRequiredPermissions
    }

    public static let allAvailable = UnlockPermissionState()

    public var allRequiredAvailable: Bool {
        unavailableRequiredPermissions.isEmpty
    }
}

public enum UnlockRequiredPermission: Equatable, Hashable {
    case cameraPermission
    case accessibility
    case keychain
}

public struct UnlockConditionDecision: Equatable {
    public let isEligibleForAutoUnlock: Bool

    public init(isEligibleForAutoUnlock: Bool) {
        self.isEligibleForAutoUnlock = isEligibleForAutoUnlock
    }
}

public enum UnlockAutofillOutcome: Equatable {
    case filled
    case failed
}
