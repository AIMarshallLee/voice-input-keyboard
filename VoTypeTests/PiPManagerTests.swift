import XCTest
@testable import VoiceInputApp

final class PiPManagerTests: XCTestCase {

    func testPiPSingletonExists() {
        let manager = PiPManager.shared
        XCTAssertNotNil(manager)
    }

    func testCanStartPiP() {
        // 在模拟器上 PiP 可能不支持,但方法不应崩溃
        _ = PiPManager.shared.canStartPiP
    }

    func testIsPiPActiveDefaultsToFalse() {
        XCTAssertFalse(PiPManager.shared.isPiPActive)
    }

    func testUpdateLiveTextDoesNotCrash() {
        PiPManager.shared.updateLiveText("测试文本")
        // 给后台队列一点时间执行
        let expectation = XCTestExpectation(description: "updateLiveText")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testStartPiPWithoutSetupDoesNotCrash() {
        // 没有先调用 setup,直接 startPiP 应该安全失败
        PiPManager.shared.startPiP()
        let expectation = XCTestExpectation(description: "startPiP without setup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testStopPiPWithoutStartDoesNotCrash() {
        PiPManager.shared.stopPiP()
    }

    func testCleanupWithoutSetupDoesNotCrash() {
        PiPManager.shared.cleanup()
    }
}
