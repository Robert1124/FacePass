import XCTest
@testable import FacePassCore

final class UnlockFlowControllerTests: XCTestCase {
    func testWakeSchedulesPendingRequestAndDefersUntilWakeDelayElapses() {
        let harness = UnlockFlowHarness(wakeDelay: 3)

        let wakeOutcome = harness.controller.handleScreenEvent(.didWake)
        let earlyOutcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(wakeOutcome, .deferred(.wakeDelayPending))
        XCTAssertEqual(earlyOutcome, .deferred(.wakeDelayPending))
        XCTAssertEqual(harness.scheduler.scheduledDelays, [3])
        XCTAssertTrue(harness.autofill.events.isEmpty)

        harness.clock.advance(by: 3)
        harness.scheduler.runNext()

        XCTAssertEqual(harness.controller.lastAutomaticOutcome, .filled)
        XCTAssertEqual(harness.autofill.events.map(\.kind), [.fillValue])
        XCTAssertEqual(harness.autofill.forbiddenConfirmationActionCount, 0)
    }

    func testUserLockBeforeScheduledWakeRequestSuppressesAutofillDuringCooldown() {
        let harness = UnlockFlowHarness(wakeDelay: 3, postLockCooldown: 30)

        let wakeOutcome = harness.controller.handleScreenEvent(.didWake)
        harness.clock.advance(by: 1)
        harness.controller.handleScreenEvent(.userDidLock)

        harness.clock.advance(by: 2)
        harness.scheduler.runNext()

        XCTAssertEqual(wakeOutcome, .deferred(.wakeDelayPending))
        XCTAssertEqual(harness.controller.lastAutomaticOutcome, .denied(.postLockCooldownActive))
        XCTAssertEqual(harness.conditions.evaluationCount, 0)
        XCTAssertEqual(harness.passwords.requestCount, 0)
        XCTAssertTrue(harness.autofill.events.isEmpty)

        harness.clock.advance(by: 28)
        let laterOutcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(laterOutcome, .filled)
        XCTAssertEqual(harness.autofill.events.map(\.kind), [.fillValue])
        XCTAssertEqual(harness.autofill.forbiddenConfirmationActionCount, 0)
    }

    func testPermissionFailureDeniesBeforeConditionsPasswordOrAutofill() {
        let harness = UnlockFlowHarness(
            permissions: UnlockPermissionState(
                unavailableRequiredPermissions: [.cameraPermission]
            )
        )

        let outcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(outcome, .denied(.requiredPermissionsUnavailable))
        XCTAssertEqual(harness.conditions.evaluationCount, 0)
        XCTAssertEqual(harness.passwords.requestCount, 0)
        XCTAssertTrue(harness.autofill.events.isEmpty)
    }

    func testConditionFailureDeniesBeforePasswordOrAutofill() {
        let harness = UnlockFlowHarness(conditionsEligible: false)

        let outcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(outcome, .denied(.conditionsIneligible))
        XCTAssertEqual(harness.conditions.evaluationCount, 1)
        XCTAssertEqual(harness.passwords.requestCount, 0)
        XCTAssertTrue(harness.autofill.events.isEmpty)
    }

    func testRecentManualLockSuppressesAutomaticUnlockUntilCooldownExpires() {
        let harness = UnlockFlowHarness(postLockCooldown: 30)

        harness.controller.handleScreenEvent(.userDidLock)
        let suppressedOutcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(suppressedOutcome, .denied(.postLockCooldownActive))
        XCTAssertTrue(harness.autofill.events.isEmpty)

        harness.clock.advance(by: 30)
        let laterOutcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(laterOutcome, .filled)
        XCTAssertEqual(harness.autofill.events.map(\.kind), [.fillValue])
    }

    func testManualRequestBypassesWakeDelayButNotPermissionsOrConditions() {
        let allowedHarness = UnlockFlowHarness(wakeDelay: 5)
        allowedHarness.controller.handleScreenEvent(.didWake)

        let manualOutcome = allowedHarness.controller.requestUnlock(.manual)

        XCTAssertEqual(manualOutcome, .filled)
        XCTAssertEqual(allowedHarness.autofill.events.map(\.kind), [.fillValue])

        let deniedHarness = UnlockFlowHarness(
            permissions: UnlockPermissionState(
                unavailableRequiredPermissions: [.accessibility]
            ),
            wakeDelay: 5
        )
        deniedHarness.controller.handleScreenEvent(.didWake)

        let deniedOutcome = deniedHarness.controller.requestUnlock(.manual)

        XCTAssertEqual(deniedOutcome, .denied(.requiredPermissionsUnavailable))
        XCTAssertTrue(deniedHarness.autofill.events.isEmpty)
    }

    func testMissingPasswordDeniesBeforeAutofill() {
        let harness = UnlockFlowHarness(password: nil)

        let outcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(outcome, .denied(.passwordUnavailable))
        XCTAssertEqual(harness.passwords.requestCount, 1)
        XCTAssertTrue(harness.autofill.events.isEmpty)
    }

    func testFailedAutofillReportsFailureWithoutConfirmationAction() {
        let harness = UnlockFlowHarness(autofillOutcome: .failed)

        let outcome = harness.controller.requestUnlock(.automatic)

        XCTAssertEqual(outcome, .autofillFailed)
        XCTAssertEqual(harness.autofill.events.map(\.kind), [.fillValue])
        XCTAssertEqual(harness.autofill.forbiddenConfirmationActionCount, 0)
    }

    func testSuccessfulInjectedAutofillReportsFilledWithoutAutoConfirm() {
        let harness = UnlockFlowHarness()

        let outcome = harness.controller.requestUnlock(.manual)

        XCTAssertEqual(outcome, .filled)
        XCTAssertEqual(harness.autofill.events.map(\.kind), [.fillValue])
        XCTAssertEqual(harness.autofill.forbiddenConfirmationActionCount, 0)
    }
}

private final class UnlockFlowHarness {
    let clock: ManualUnlockClock
    let scheduler: ManualUnlockScheduler
    let permissions: StubUnlockPermissionProvider
    let conditions: StubUnlockConditionEvaluator
    let passwords: StubUnlockPasswordProvider
    let autofill: SpyUnlockAutofillService
    let controller: UnlockFlowController

    init(
        permissions: UnlockPermissionState = .allAvailable,
        conditionsEligible: Bool = true,
        password: String? = "phase5-test-password",
        autofillOutcome: UnlockAutofillOutcome = .filled,
        wakeDelay: TimeInterval = 0,
        postLockCooldown: TimeInterval = 0
    ) {
        self.clock = ManualUnlockClock(now: Date(timeIntervalSince1970: 1_000))
        self.scheduler = ManualUnlockScheduler()
        self.permissions = StubUnlockPermissionProvider(state: permissions)
        self.conditions = StubUnlockConditionEvaluator(isEligible: conditionsEligible)
        self.passwords = StubUnlockPasswordProvider(password: password)
        self.autofill = SpyUnlockAutofillService(outcome: autofillOutcome)
        self.controller = UnlockFlowController(
            policy: UnlockFlowPolicy(
                wakeDelay: wakeDelay,
                postLockCooldown: postLockCooldown
            ),
            permissionProvider: self.permissions,
            conditionEvaluator: self.conditions,
            passwordProvider: self.passwords,
            autofillService: self.autofill,
            clock: self.clock,
            scheduler: self.scheduler
        )
    }
}

private final class ManualUnlockClock: UnlockClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

private final class ManualUnlockScheduler: UnlockScheduler {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var scheduledActions: [() -> Void] = []

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduledDelays.append(delay)
        scheduledActions.append(action)
    }

    func runNext() {
        guard !scheduledActions.isEmpty else {
            return
        }
        scheduledActions.removeFirst()()
    }
}

private final class StubUnlockPermissionProvider: UnlockPermissionProviding {
    let state: UnlockPermissionState

    init(state: UnlockPermissionState) {
        self.state = state
    }

    func currentUnlockPermissions() -> UnlockPermissionState {
        state
    }
}

private final class StubUnlockConditionEvaluator: UnlockConditionEvaluating {
    private let isEligible: Bool
    private(set) var evaluationCount = 0

    init(isEligible: Bool) {
        self.isEligible = isEligible
    }

    func evaluateUnlockConditions() -> UnlockConditionDecision {
        evaluationCount += 1
        return UnlockConditionDecision(isEligibleForAutoUnlock: isEligible)
    }
}

private final class StubUnlockPasswordProvider: UnlockPasswordProviding {
    private let password: String?
    private(set) var requestCount = 0

    init(password: String?) {
        self.password = password
    }

    func passwordForUnlock() -> String? {
        requestCount += 1
        return password
    }
}

private final class SpyUnlockAutofillService: UnlockAutofilling {
    private let outcome: UnlockAutofillOutcome
    private(set) var events: [UnlockAutofillEvent] = []
    private(set) var forbiddenConfirmationActionCount = 0

    init(outcome: UnlockAutofillOutcome) {
        self.outcome = outcome
    }

    func fillPasswordValue(_ password: String) -> UnlockAutofillOutcome {
        events.append(.fillValue(passwordLength: password.count))
        return outcome
    }
}

private enum UnlockAutofillEvent: Equatable {
    case fillValue(passwordLength: Int)

    var kind: UnlockAutofillEventKind {
        switch self {
        case .fillValue:
            .fillValue
        }
    }
}

private enum UnlockAutofillEventKind {
    case fillValue
}
