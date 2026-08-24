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
}
