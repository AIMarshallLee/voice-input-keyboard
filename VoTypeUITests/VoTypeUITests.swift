import XCTest

final class VoTypeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHostShowsTruthfulStandbyEntryAndPrivacyState() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        XCTAssertTrue(app.staticTexts["VoType"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["免切换语音"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["开启免切换语音"].exists
                || app.buttons["关闭免切换语音"].exists,
            "The user must always have a visible standby control"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "待命时不录音")
            ).firstMatch.exists,
            "The standby screen must disclose that the microphone is off"
        )
    }

    func testPinyinLearningResetIsDiscoverable() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let reset = app.buttons["重置拼音候选学习"]
        var attempts = 0
        while !reset.exists, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(reset.exists)
    }

    func testPrivacyCopyDisclosesSpeechServiceFallbackAccurately() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let disclosure = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "设备端识别不可用时，Apple 可能通过网络处理"
            )
        ).firstMatch
        var attempts = 0
        while !disclosure.exists, attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(
            disclosure.exists,
            "The in-app privacy copy must distinguish on-device recognition from Apple service fallback"
        )
    }
}
