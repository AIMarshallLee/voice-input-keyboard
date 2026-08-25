import XCTest
@testable import VoiceInputApp

final class PinyinInputEngineTests: XCTestCase {
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
        XCTAssertTrue(engine.candidates(for: "nihao", limit: 16).contains("泥号"))

        engine.recordSelection(input: "Ni' Hao", candidate: "泥号")

        XCTAssertEqual(engine.candidates(for: "nihao", limit: 4).first, "泥号")
    }

    func testAdaptiveSelectionPersistsAcrossEngineRecreation() throws {
        let suite = "PinyinInputEngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        ).recordSelection(input: "nihao", candidate: "泥号")

        let reloaded = PinyinInputEngine(
            dictionaryText: dictionary,
            learningStore: defaults
        )
        XCTAssertEqual(reloaded.candidates(for: "nihao", limit: 4).first, "泥号")
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
}
