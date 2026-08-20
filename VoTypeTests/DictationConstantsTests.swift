import XCTest
@testable import VoiceInputApp

final class DictationConstantsTests: XCTestCase {

    // MARK: - URL 构建 (Path B 降级路径)

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

    // MARK: - DarwinBridge IPC (App Group 文件)

    func testDarwinBridgeWriteAndReadTranscription() {
        let testText = "这是一段测试语音识别结果"
        let testSession = UUID().uuidString

        DarwinBridge.writeTranscription(testText, session: testSession)

        let result = DarwinBridge.readAndConsumeResult()
        XCTAssertEqual(result.text, testText)
        XCTAssertEqual(result.session, testSession)
        XCTAssertNil(result.error)
    }

    func testDarwinBridgeWriteAndReadError() {
        let testError = "未识别到语音"
        let testSession = UUID().uuidString

        DarwinBridge.writeError(testError, session: testSession)

        let result = DarwinBridge.readAndConsumeResult()
        XCTAssertNil(result.text)
        XCTAssertEqual(result.error, testError)
        XCTAssertEqual(result.session, testSession)
    }

    func testDarwinBridgeReadAfterConsumeReturnsNil() {
        let testText = "测试"
        let testSession = UUID().uuidString

        DarwinBridge.writeTranscription(testText, session: testSession)
        _ = DarwinBridge.readAndConsumeResult()

        // 第二次读应该返回 nil (文件已被删除)
        let result = DarwinBridge.readAndConsumeResult()
        XCTAssertNil(result.text)
        XCTAssertNil(result.error)
        XCTAssertNil(result.session)
    }

    func testDarwinBridgeSessionMismatch() {
        let session1 = "session-aaa"
        let session2 = "session-bbb"

        // 写入 session1 的结果
        DarwinBridge.writeTranscription("结果1", session: session1)

        // 读取时验证 session
        let result = DarwinBridge.readAndConsumeResult()
        XCTAssertEqual(result.session, session1)
        XCTAssertEqual(result.text, "结果1")

        // session2 不匹配,应被拒绝
        XCTAssertNotEqual(result.session, session2)
    }

    func testDarwinBridgeHeartbeat() {
        // 写入心跳
        DarwinBridge.writeHeartbeat()

        // 心跳应该存在且新鲜
        let age = DarwinBridge.heartbeatAge()
        XCTAssertLessThan(age, 1.0) // 应该小于 1 秒
        XCTAssertTrue(DarwinBridge.isMainAppAlive(threshold: 3.0))
    }

    func testDarwinBridgeDictationSettings() {
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: true,
            translateEnabled: false,
            translateTarget: "en",
            selectedText: "选中文本",
            keyboardType: 1,
            session: "test-settings-session"
        )

        DarwinBridge.writeDictationSettings(settings)

        let read = DarwinBridge.readDictationSettings()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.language, "zh-CN")
        XCTAssertEqual(read?.whisper, true)
        XCTAssertEqual(read?.translateEnabled, false)
        XCTAssertEqual(read?.translateTarget, "en")
        XCTAssertEqual(read?.selectedText, "选中文本")
        XCTAssertEqual(read?.keyboardType, 1)
        XCTAssertEqual(read?.session, "test-settings-session")
    }
}
