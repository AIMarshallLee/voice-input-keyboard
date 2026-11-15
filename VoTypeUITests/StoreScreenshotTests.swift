import XCTest

/// Captures real app screens for the App Store listing.
/// Skipped unless the runner sets VOTYPE_STORE_SCREENSHOTS=1
/// (pass TEST_RUNNER_VOTYPE_STORE_SCREENSHOTS=1 to xcodebuild).
final class StoreScreenshotTests: XCTestCase {
    private let sections = ["免切换语音", "AI 处理设置", "语言偏好", "个人词典", "隐私说明"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VOTYPE_STORE_SCREENSHOTS"] == "1",
            "Store screenshots run only on demand"
        )
    }

    func testCaptureStoreScreens() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-keyboardSetup.keyboardObserved", "YES",
            "-keyboardSetup.fullAccessObserved", "YES"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["VoType"].firstMatch.waitForExistence(timeout: 10))
        capture(app, named: "01-home")

        for (index, title) in sections.enumerated() {
            let header = app.staticTexts[title].firstMatch
            scrollUntilNearTop(app, element: header)
            capture(app, named: String(format: "%02d-%@", index + 2, title))
        }
    }

    private func scrollUntilNearTop(_ app: XCUIApplication, element: XCUIElement) {
        let window = app.windows.firstMatch
        var attempts = 0
        while attempts < 20 {
            if element.exists, element.isHittable,
               element.frame.minY < window.frame.height * 0.35 {
                return
            }
            if element.exists, element.isHittable,
               element.frame.minY < window.frame.height * 0.6 {
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                app.swipeUp()
            }
            attempts += 1
        }
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
