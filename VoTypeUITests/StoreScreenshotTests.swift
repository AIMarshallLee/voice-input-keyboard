import XCTest

/// Captures real app screens for the App Store listing.
/// Skipped unless the runner sets VOTYPE_STORE_SCREENSHOTS=1
/// (pass TEST_RUNNER_VOTYPE_STORE_SCREENSHOTS=1 to xcodebuild).
final class StoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VOTYPE_STORE_SCREENSHOTS"] == "1",
            "Store screenshots run only on demand"
        )
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-keyboardSetup.keyboardObserved", "YES",
            "-keyboardSetup.fullAccessObserved", "YES"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["VoType"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// Pages through the whole settings screen in fixed steps.
    func testCapturePages() {
        let app = launchApp()
        let window = app.windows.firstMatch
        capture(named: "page-00")
        for page in 1...9 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            capture(named: String(format: "page-%02d", page))
        }
    }

    /// Opens the add-dictionary sheet so the active keyboard is visible.
    func testCaptureKeyboard() {
        let app = launchApp()
        let header = app.staticTexts["个人词典"].firstMatch
        var attempts = 0
        while !(header.exists && header.isHittable), attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        guard header.exists else { return XCTFail("dictionary header not found") }
        let window = app.windows.firstMatch
        let plus = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.width - 44, dy: header.frame.midY))
        plus.tap()
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { return XCTFail("add sheet did not open") }
        field.tap()
        Thread.sleep(forTimeInterval: 2.0)
        capture(named: "keyboard-00")
        let globe = app.keyboards.buttons["Next keyboard"].firstMatch
        if globe.exists {
            globe.tap()
            Thread.sleep(forTimeInterval: 2.0)
            capture(named: "keyboard-01")
        }
    }

    private func capture(named name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
