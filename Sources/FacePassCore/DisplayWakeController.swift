import Foundation
import IOKit.pwr_mgt

public protocol DisplayWakeControlling {
    func wakeDisplay()
}

public struct DisplayWakeController: DisplayWakeControlling {
    public init() {}

    public func wakeDisplay() {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            "FacePass StandBy Unlock" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )

        if result == kIOReturnSuccess {
            IOPMAssertionRelease(assertionID)
        }
    }
}
