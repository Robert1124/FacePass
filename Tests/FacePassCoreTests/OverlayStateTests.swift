import XCTest
@testable import FacePassCore

final class OverlayStateTests: XCTestCase {
    func testInitialStateStartsHiddenAndIdle() {
        let state = OverlayState()

        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.phase, .idle)
    }

    func testShowScanningMakesOverlayVisible() {
        var state = OverlayState()

        state.showScanning()

        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.phase, .scanning)
    }

    func testTerminalStatesRemainVisibleUntilDismissed() {
        var successState = OverlayState()
        var failureState = OverlayState()
        var timeoutState = OverlayState()

        successState.showSuccess()
        failureState.showFailure()
        timeoutState.showTimeout()

        XCTAssertEqual(successState, OverlayState(isVisible: true, phase: .success))
        XCTAssertEqual(failureState, OverlayState(isVisible: true, phase: .failure))
        XCTAssertEqual(timeoutState, OverlayState(isVisible: true, phase: .timeout))
    }

    func testRecognitionPreviewStatesRemainVisibleUntilDismissed() {
        var scanningState = OverlayState()
        var recognizedState = OverlayState()
        var failureState = OverlayState()

        scanningState.showRecognitionPreviewScanning()
        recognizedState.showRecognitionPreviewRecognized()
        failureState.showRecognitionPreviewFailure()

        XCTAssertEqual(scanningState, OverlayState(isVisible: true, phase: .recognitionPreviewScanning))
        XCTAssertEqual(recognizedState, OverlayState(isVisible: true, phase: .recognitionPreviewRecognized))
        XCTAssertEqual(failureState, OverlayState(isVisible: true, phase: .recognitionPreviewFailure))
    }

    func testDismissHidesOverlayAndReturnsToIdle() {
        var state = OverlayState(isVisible: true, phase: .success)

        state.dismiss()

        XCTAssertEqual(state, OverlayState())
    }

    func testUserFacingLabelsAvoidRestrictedClaims() {
        let restrictedFragments = [
            ["Face", "ID"].joined(separator: " "),
            ["bio", "metric"].joined(),
            ["identity", "verified"].joined(separator: " "),
            ["authentication", "replacement"].joined(separator: " ")
        ]

        for phase in OverlayPhase.allCases {
            let labelText = [phase.title, phase.detail].joined(separator: " ")

            for fragment in restrictedFragments {
                XCTAssertFalse(
                    labelText.localizedCaseInsensitiveContains(fragment),
                    "\(phase) label contains restricted fragment: \(fragment)"
                )
            }
        }
    }

    func testRecognitionPreviewLabelsDescribePreviewOnlyBehavior() {
        let previewPhases: [OverlayPhase] = [
            .recognitionPreviewScanning,
            .recognitionPreviewRecognized,
            .recognitionPreviewFailure
        ]

        for phase in previewPhases {
            let labelText = [phase.title, phase.detail].joined(separator: " ")

            XCTAssertTrue(labelText.localizedCaseInsensitiveContains("preview"))
            XCTAssertFalse(labelText.localizedCaseInsensitiveContains("Face ID"))
            XCTAssertFalse(labelText.localizedCaseInsensitiveContains("biometric"))
            XCTAssertFalse(labelText.localizedCaseInsensitiveContains("authentication replacement"))
        }
    }
}
