import XCTest
@testable import FacePassCore

final class AppVersionInfoTests: XCTestCase {
    func testDisplayTextIncludesMarketingVersionAndBuildNumber() {
        let infoDictionary: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ]

        let displayText = AppVersionInfo.displayText(infoDictionary: infoDictionary)

        XCTAssertEqual(displayText, "Version 1.2.3 (45)")
    }

    func testDisplayTextOmitsBuildWhenBuildNumberIsMissing() {
        let infoDictionary: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3"
        ]

        let displayText = AppVersionInfo.displayText(infoDictionary: infoDictionary)

        XCTAssertEqual(displayText, "Version 1.2.3")
    }

    func testDisplayTextUsesUnknownFallbackWhenMarketingVersionIsBlank() {
        let infoDictionary: [String: Any] = [
            "CFBundleShortVersionString": "   ",
            "CFBundleVersion": "45"
        ]

        let displayText = AppVersionInfo.displayText(infoDictionary: infoDictionary)

        XCTAssertEqual(displayText, "Version Unknown")
    }
}
