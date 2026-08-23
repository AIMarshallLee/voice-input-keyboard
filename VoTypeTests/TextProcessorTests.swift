import XCTest
@testable import VoiceInputApp

private final class TranslationSpy: TranslationProviding {
    struct Call {
        let text: String
        let source: String
        let target: String
    }

    var result: String?
    private(set) var calls: [Call] = []

    func translate(_ text: String, from sourceLang: String, to targetLang: String) async -> String? {
        calls.append(Call(text: text, source: sourceLang, target: targetLang))
        return result
    }
}

final class TextProcessorTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var translator: TranslationSpy!
    private var usageTracker: UsageTracker!
    private var processor: TextProcessor!

    override func setUp() {
        super.setUp()

        suiteName = "com.daseanle.votype.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        // 禁用依赖运行时能力的步骤，让规则引擎测试保持确定性。
        defaults.set(false, forKey: "llmPolish")
        defaults.set(false, forKey: "fillerWordRemoval")
        defaults.set(false, forKey: "smartCorrection")
        defaults.set(false, forKey: "autoFormat")
        defaults.set(true, forKey: "autoPunctuation")
        defaults.set(true, forKey: "voiceEdit")

        translator = TranslationSpy()
        usageTracker = UsageTracker(defaults: defaults)
        processor = TextProcessor(
            defaults: defaults,
            translationProvider: translator,
            smartFormatter: SmartFormatter(defaults: defaults),
            usageTracker: usageTracker
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        processor = nil
        usageTracker = nil
        translator = nil
        defaults = nil
        super.tearDown()
    }

    func testDeleteVoiceEditHasDedicatedResult() async {
        let result = await processor.process(
            "删除",
            selectedText: "需要删除的文字",
            language: "zh-CN",
            translateEnabled: false,
            translateTarget: "en-US"
        )

        XCTAssertEqual(result, .deleteSelection)
        XCTAssertEqual(usageTracker.stats.totalSessions, 1)
        XCTAssertEqual(usageTracker.stats.totalChars, 0)
    }

    func testEmptyInputIsFailureInsteadOfDelete() async {
        let result = await processor.process(
            "   ",
            selectedText: "不能误删",
            language: "zh-CN",
            translateEnabled: false,
            translateTarget: "en-US"
        )

        XCTAssertEqual(result, .failure(.emptyInput))
        XCTAssertEqual(usageTracker.stats.totalSessions, 0)
    }

    func testEmptyProcessedOutputIsFailureInsteadOfDelete() async {
        defaults.set(true, forKey: "fillerWordRemoval")

        let result = await processor.process(
            "嗯",
            language: "zh-CN",
            translateEnabled: false,
            translateTarget: "en-US"
        )

        XCTAssertEqual(result, .failure(.emptyOutput))
        XCTAssertEqual(usageTracker.stats.totalSessions, 0)
    }

    func testSelfCorrectionKeepsCompleteReplacement() {
        XCTAssertEqual(
            processor.detectSelfCorrection(in: "明天上午9点，不对，明天下午3点"),
            "明天下午3点"
        )
        XCTAssertEqual(
            processor.detectSelfCorrection(in: "叫什么来着，对，王若虚"),
            "王若虚"
        )
        XCTAssertEqual(
            processor.detectSelfCorrection(in: "算了，应该是明天"),
            "明天"
        )
    }

    func testAutoPunctuationUsesExplicitLanguage() {
        XCTAssertEqual(processor.addAutoPunctuation(to: "你好", languageID: "zh-CN"), "你好。")
        XCTAssertEqual(processor.addAutoPunctuation(to: "hello", languageID: "en-US"), "hello.")
        XCTAssertEqual(processor.addAutoPunctuation(to: "where are we", languageID: "en-US"), "where are we?")
        XCTAssertEqual(processor.addAutoPunctuation(to: "今日は晴れ", languageID: "ja-JP"), "今日は晴れ。")
    }

    func testProcessUsesSessionLanguageForFormattingAndStatistics() async {
        LanguageManager(defaults: defaults).currentLanguageID = "zh-CN"
        defaults.set(true, forKey: "autoFormat")

        let result = await processor.process(
            "first apples second oranges",
            language: "en-US",
            translateEnabled: false,
            translateTarget: "zh-CN"
        )

        XCTAssertEqual(result, .insert("1. apples\n2. oranges"))
        XCTAssertEqual(usageTracker.stats.languageDistribution.first?.name, "English (US)")
        XCTAssertTrue(translator.calls.isEmpty)
    }

    func testProcessUsesSessionTranslationTargetAndTargetPunctuation() async {
        TranslationManager(defaults: defaults).setTranslationEnabled(false)
        translator.result = "翻訳済み"

        let result = await processor.process(
            "translated",
            language: "en-US",
            translateEnabled: true,
            translateTarget: "ja-JP"
        )

        XCTAssertEqual(result, .insert("翻訳済み。"))
        XCTAssertEqual(translator.calls.count, 1)
        XCTAssertEqual(translator.calls.first?.source, "en-US")
        XCTAssertEqual(translator.calls.first?.target, "ja-JP")
        XCTAssertEqual(usageTracker.stats.featureUsage.first(where: { $0.feature == "translation" })?.count, 1)
    }

    func testSessionCanDisableTranslationEvenWhenGlobalSettingIsOn() async {
        TranslationManager(defaults: defaults).setTranslationEnabled(true)
        translator.result = "不应使用"

        let result = await processor.process(
            "hello",
            language: "en-US",
            translateEnabled: false,
            translateTarget: "zh-CN"
        )

        XCTAssertEqual(result, .insert("hello."))
        XCTAssertTrue(translator.calls.isEmpty)
    }

    func testManagersShareInjectedDefaultsSuite() {
        let languageWriter = LanguageManager(defaults: defaults)
        let languageReader = LanguageManager(defaults: defaults)
        let translationWriter = TranslationManager(defaults: defaults)
        let translationReader = TranslationManager(defaults: defaults)

        languageWriter.currentLanguageID = "fr-FR"
        translationWriter.targetLanguageID = "de-DE"

        XCTAssertEqual(languageReader.currentLanguageID, "fr-FR")
        XCTAssertEqual(translationReader.targetLanguageID, "de-DE")
        XCTAssertEqual(SharedDefaults.suiteName, "group.com.daseanle.votype.shared")
    }
}
