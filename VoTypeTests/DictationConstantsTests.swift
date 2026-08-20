import XCTest
@testable import VoiceInputApp

final class DictationConstantsTests: XCTestCase {

    func testBuildDictationURL() {
        let url = DictationConstants.buildDictationURL(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en",
            selectedText: nil,
            keyboardType: 0,
            session: "test-session-123"
        )

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "votype")
        XCTAssertEqual(url?.host, "dictation")

        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryDict = Dictionary(comps?.queryItems?.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        } ?? [], uniquingKeysWith: { _, last in last })

        XCTAssertEqual(queryDict["lang"], "zh-CN")
        XCTAssertEqual(queryDict["whisper"], "0")
        XCTAssertEqual(queryDict["translate"], "0")
        XCTAssertEqual(queryDict["translateTarget"], "en")
        XCTAssertEqual(queryDict["kbType"], "0")
        XCTAssertEqual(queryDict["session"], "test-session-123")
        XCTAssertNil(queryDict["selectedText"])
    }

    func testBuildDictationURLWithSelectedText() {
        let url = DictationConstants.buildDictationURL(
            language: "en-US",
            whisper: true,
            translateEnabled: true,
            translateTarget: "zh-Hans",
            selectedText: "hello world",
            keyboardType: 1,
            session: "session-456"
        )

        XCTAssertNotNil(url)
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryDict = Dictionary(comps?.queryItems?.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        } ?? [], uniquingKeysWith: { _, last in last })

        XCTAssertEqual(queryDict["lang"], "en-US")
        XCTAssertEqual(queryDict["whisper"], "1")
        XCTAssertEqual(queryDict["translate"], "1")
        XCTAssertEqual(queryDict["translateTarget"], "zh-Hans")
        XCTAssertEqual(queryDict["selectedText"], "hello world")
        XCTAssertEqual(queryDict["session"], "session-456")
    }

    func testWriteAndReadResult() {
        let testText = "这是一段测试语音识别结果"
        let testSession = UUID().uuidString

        DictationConstants.writeResult(text: testText, session: testSession)

        let result = DictationConstants.readAndConsumeResult()
        XCTAssertEqual(result.text, testText)
        XCTAssertNil(result.error)
    }

    func testWriteAndReadError() {
        let testError = "未识别到语音"
        let testSession = UUID().uuidString

        DictationConstants.writeError(message: testError, session: testSession)

        let result = DictationConstants.readAndConsumeResult()
        XCTAssertNil(result.text)
        XCTAssertEqual(result.error, testError)
    }

    func testReadAfterConsumeReturnsNil() {
        let testText = "测试"
        let testSession = UUID().uuidString

        DictationConstants.writeResult(text: testText, session: testSession)
        _ = DictationConstants.readAndConsumeResult()

        // 第二次读应该返回 nil (已被消费)
        let result = DictationConstants.readAndConsumeResult()
        XCTAssertNil(result.text)
        XCTAssertNil(result.error)
    }

    func testReadEmptyPasteboard() {
        // 先清除剪贴板
        if let pb = UIPasteboard(name: UIPasteboard.Name(rawValue: DictationConstants.pasteboardName), create: false) {
            pb.string = ""
        }

        let result = DictationConstants.readAndConsumeResult()
        XCTAssertNil(result.text)
        XCTAssertNil(result.error)
    }
}
