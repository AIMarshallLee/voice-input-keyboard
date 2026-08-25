import XCTest
@testable import VoiceInputApp

final class PinyinInputEngineTests: XCTestCase {
    private static let bundledEngine = PinyinInputEngine(
        bundle: Bundle(for: PinyinInputEngineTests.self)
    )
    private let commonPhraseCorpus: [(pinyin: String, expected: String)] = [
        ("beijing", "北京"), ("pinyin", "拼音"), ("pingguo", "苹果"),
        ("meiyou", "没有"), ("mingtian", "明天"), ("diannao", "电脑"),
        ("tianqi", "天气"), ("nihao", "你好"), ("gongzuo", "工作"),
        ("kaifa", "开发"), ("keyi", "可以"), ("huiyi", "会议"),
        ("jianpan", "键盘"), ("jintian", "今天"), ("xiaoxi", "消息"),
        ("xiangmu", "项目"), ("xiexie", "谢谢"), ("zhongguo", "中国"),
        ("zhongwen", "中文"), ("shanghai", "上海"), ("shijian", "时间"),
        ("shouji", "手机"), ("ceshi", "测试"), ("youjian", "邮件"),
        ("wancheng", "完成"), ("wenti", "问题"), ("women", "我们"),
        ("shurufa", "输入法")
    ]

    private let dictionary = """
    # minimal test dictionary
    ---
    name: test
    ...
    尼\tni\t10
    你\tni\t1000
    号\thao\t20
    好\thao\t900
    吗\tma\t800
    你好\tni hao\t5000
    """

    func testNormalizesContinuousPinyin() {
        XCTAssertEqual(PinyinInputEngine.normalize("Ni' Hao 123"), "nihao")
    }

    func testExactPhraseRanksFirst() {
        let engine = PinyinInputEngine(dictionaryText: dictionary)
        XCTAssertEqual(engine.candidates(for: "nihao", limit: 4).first, "你好")
    }

    func testExactPhraseOutranksHigherFrequencyCharacterComposition() {
        let engine = PinyinInputEngine(
            dictionaryText: """
            你\tni\t10
            泥\tni\t1000000
            好\thao\t10
            号\thao\t1000000
            你好\tni hao\t1
            """
        )
        XCTAssertEqual(engine.candidates(for: "nihao", limit: 4).first, "你好")
    }

    func testBeamSearchComposesPhraseNotPresentInDictionary() {
        let engine = PinyinInputEngine(dictionaryText: dictionary)
        XCTAssertEqual(engine.candidates(for: "nihaoma", limit: 4).first, "你好吗")
    }

    func testUnknownIncompletePinyinReturnsNoFabricatedCandidate() {
        let engine = PinyinInputEngine(dictionaryText: dictionary)
        XCTAssertTrue(engine.candidates(for: "n").isEmpty)
    }

    func testIncompleteContinuousPinyinSuggestsKnownPhrase() {
        let engine = PinyinInputEngine(dictionaryText: dictionary)
        XCTAssertEqual(engine.candidates(for: "niha", limit: 4).first, "你好")
    }

    func testCandidatesAreDeduplicatedAndLimited() {
        let engine = PinyinInputEngine(dictionaryText: dictionary)
        let candidates = engine.candidates(for: "nihao", limit: 2)
        XCTAssertEqual(candidates.count, Set(candidates).count)
        XCTAssertLessThanOrEqual(candidates.count, 2)
    }

    func testExplicitSelectionPromotesCandidateForSamePinyin() throws {
        let suite = "PinyinInputEngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        )
        XCTAssertTrue(engine.candidates(for: "nihao", limit: 16).contains("尼号"))

        engine.recordSelection(input: "Ni' Hao", candidate: "尼号")

        XCTAssertEqual(engine.candidates(for: "nihao", limit: 4).first, "尼号")
    }

    func testAdaptiveSelectionPersistsAcrossEngineRecreation() throws {
        let suite = "PinyinInputEngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        ).recordSelection(input: "nihao", candidate: "尼号")

        let reloaded = PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        )
        XCTAssertEqual(reloaded.candidates(for: "nihao", limit: 4).first, "尼号")
    }

    func testLearningRejectsFabricatedCandidate() throws {
        let suite = "PinyinInputEngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        )

        engine.recordSelection(input: "nihao", candidate: "不存在的词")

        XCTAssertEqual(engine.candidates(for: "nihao", limit: 4).first, "你好")
    }

    func testAdaptiveLearningCanBeReset() throws {
        let suite = "PinyinInputEngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learned = PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        )
        learned.recordSelection(input: "nihao", candidate: "尼号")
        XCTAssertEqual(learned.candidates(for: "nihao", limit: 4).first, "尼号")

        PinyinInputEngine.resetAdaptiveLearning(in: defaults)
        let reset = PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        )
        XCTAssertEqual(reset.candidates(for: "nihao", limit: 4).first, "你好")
    }

    func testBundledLexiconCommonPhrasesMeetTopOneGate() throws {
        let engine = try XCTUnwrap(Self.bundledEngine)

        for sample in commonPhraseCorpus {
            XCTAssertEqual(
                engine.candidates(for: sample.pinyin, limit: 5).first,
                sample.expected,
                "Top-1 mismatch for \(sample.pinyin)"
            )
        }
    }

    func testBundledLexiconWarmQueryP95IsUnderFortyMilliseconds() throws {
        let engine = try XCTUnwrap(Self.bundledEngine)
        for sample in commonPhraseCorpus {
            _ = engine.candidates(for: sample.pinyin, limit: 12)
        }

        var durations: [TimeInterval] = []
        for _ in 0..<10 {
            for sample in commonPhraseCorpus {
                let start = ProcessInfo.processInfo.systemUptime
                _ = engine.candidates(for: sample.pinyin, limit: 12)
                durations.append(ProcessInfo.processInfo.systemUptime - start)
            }
        }
        durations.sort()
        let p95Index = min(durations.count - 1, Int(Double(durations.count) * 0.95))
        XCTAssertLessThan(
            durations[p95Index],
            0.040,
            "Warm candidate query p95 exceeded 40 ms"
        )
    }
}
