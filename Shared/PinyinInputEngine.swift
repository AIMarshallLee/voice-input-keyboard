import Foundation

struct PinyinCandidate: Equatable {
    let text: String
    let score: Double
}

/// Lightweight, offline Pinyin-to-Hanzi converter for the keyboard extension.
///
/// The bundled dictionary is the Apache-2.0 `pinyin_simp.dict.yaml` data from
/// Rime. The engine keeps only a small candidate list for each spelling and
/// performs a bounded beam search so continuous Pinyin can still be converted
/// when the complete phrase is not present in the dictionary.
final class PinyinInputEngine {
    private static let learningStorageKey = "pinyinAdaptiveSelectionCounts.v1"
    private static let maximumLearnedCodes = 2_000
    private static let maximumLearnedCandidatesPerCode = 16

    private struct Path {
        let text: String
        let score: Double
        let segmentCount: Int
    }

    private var entries: [String: [PinyinCandidate]] = [:]
    private var sortedCodes: [String] = []
    private var maximumCodeLength = 0
    private let perCodeLimit: Int
    private let learningStore: UserDefaults?
    private var selectionCounts: [String: [String: Int]]

    init(
        dictionaryText: String,
        perCodeLimit: Int = 8,
        learningStore: UserDefaults? = nil
    ) {
        self.perCodeLimit = max(1, perCodeLimit)
        self.learningStore = learningStore
        self.selectionCounts = Self.loadSelectionCounts(from: learningStore)
        load(dictionaryText)
    }

    convenience init?(bundle: Bundle = .main) {
        guard let url = bundle.url(
            forResource: "pinyin_simp",
            withExtension: "txt"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        self.init(
            dictionaryText: text,
            learningStore: SharedDefaults.shared
        )
    }

    var isReady: Bool { !entries.isEmpty }

    func candidates(for rawInput: String, limit: Int = 10) -> [String] {
        let code = Self.normalize(rawInput)
        guard !code.isEmpty, limit > 0 else { return [] }

        // A dictionary entry matching the complete spelling is more reliable
        // than a high-frequency character path. Keep those lexical candidates
        // first, then fill remaining slots with beam-search compositions.
        var result: [String] = []
        var seen: Set<String> = []
        let exact = entries[code] ?? []
        let ranked = exact
            + (exact.isEmpty ? prefixCandidates(for: code, limit: limit) : [])
            + composedCandidates(for: code, limit: limit * 2)
        for candidate in ranked where !candidate.text.isEmpty {
            guard seen.insert(candidate.text).inserted else { continue }
            result.append(candidate.text)
        }

        // 学习只在同一拼音的现有词库候选之间调整顺序，不会凭空制造文字。
        // 对数增益让少量明确选择能纠正首选，同时避免长期使用后永远无法改回。
        let learned = selectionCounts[code] ?? [:]
        return result.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = log1p(Double(learned[lhs.element] ?? 0)) * 4
                    - Double(lhs.offset) * 0.22
                let rhsScore = log1p(Double(learned[rhs.element] ?? 0)) * 4
                    - Double(rhs.offset) * 0.22
                if lhsScore == rhsScore { return lhs.offset < rhs.offset }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map(\.element)
    }

    /// 用户点选或用空格确认候选后进行纯本地学习。
    func recordSelection(input rawInput: String, candidate: String) {
        let code = Self.normalize(rawInput)
        guard !code.isEmpty,
              !candidate.isEmpty,
              candidates(for: code, limit: 64).contains(candidate) else { return }

        var counts = selectionCounts[code] ?? [:]
        counts[candidate] = min(10_000, (counts[candidate] ?? 0) + 1)
        if counts.count > Self.maximumLearnedCandidatesPerCode {
            counts = Dictionary(
                uniqueKeysWithValues: counts
                    .sorted { $0.value > $1.value }
                    .prefix(Self.maximumLearnedCandidatesPerCode)
                    .map { ($0.key, $0.value) }
            )
        }
        selectionCounts[code] = counts

        if selectionCounts.count > Self.maximumLearnedCodes {
            let weakestCodes = selectionCounts
                .map { (code: $0.key, total: $0.value.values.reduce(0, +)) }
                .sorted { $0.total < $1.total }
                .prefix(selectionCounts.count - Self.maximumLearnedCodes)
            for item in weakestCodes {
                selectionCounts.removeValue(forKey: item.code)
            }
        }
        persistSelectionCounts()
    }

    static func normalize(_ input: String) -> String {
        String(
            input.lowercased().unicodeScalars.compactMap { scalar in
                switch scalar.value {
                case 97...122:
                    return Character(String(scalar))
                default:
                    return nil
                }
            }
        )
    }

    private func load(_ text: String) {
        var loaded: [String: [PinyinCandidate]] = [:]

        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  line.first != "#",
                  line.first != "-",
                  line != "..." else { return }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }

            let hanzi = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let code = Self.normalize(String(fields[1]))
            guard !hanzi.isEmpty, !code.isEmpty else { return }

            let weight = fields.count >= 3 ? Double(fields[2]) ?? 0 : 0
            let candidate = PinyinCandidate(
                text: hanzi,
                score: log(max(0, weight) + 1) + Double(hanzi.count) * 0.15
            )
            loaded[code, default: []].append(candidate)
        }

        for (code, values) in loaded {
            var seen: Set<String> = []
            let best = values
                .sorted { $0.score > $1.score }
                .filter { seen.insert($0.text).inserted }
            entries[code] = Array(best.prefix(perCodeLimit))
            maximumCodeLength = max(maximumCodeLength, code.count)
        }
        sortedCodes = entries.keys.sorted()
    }

    /// 连续拼音尚未敲完时提供词条补全。排序数组 + lower-bound 避免每次
    /// 扫描 6 万条词库；最多检查 96 个相邻 code，内存也不复制整棵前缀树。
    private func prefixCandidates(
        for code: String,
        limit: Int
    ) -> [PinyinCandidate] {
        guard code.count >= 2, !sortedCodes.isEmpty else { return [] }
        var lower = 0
        var upper = sortedCodes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sortedCodes[middle] < code {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var result: [PinyinCandidate] = []
        var inspected = 0
        var index = lower
        while index < sortedCodes.count,
              sortedCodes[index].hasPrefix(code),
              inspected < 96,
              result.count < max(limit * 2, 12) {
            let completedCode = sortedCodes[index]
            let completionPenalty = Double(completedCode.count - code.count) * 0.45
            for candidate in (entries[completedCode] ?? []).prefix(2) {
                result.append(
                    PinyinCandidate(
                        text: candidate.text,
                        score: candidate.score - completionPenalty
                    )
                )
            }
            inspected += 1
            index += 1
        }
        return result.sorted { $0.score > $1.score }
    }

    private func composedCandidates(for code: String, limit: Int) -> [PinyinCandidate] {
        let characters = Array(code)
        guard !characters.isEmpty, maximumCodeLength > 0 else { return [] }

        let beamWidth = max(8, min(32, limit))
        var paths = Array(repeating: [Path](), count: characters.count + 1)
        paths[0] = [Path(text: "", score: 0, segmentCount: 0)]

        for start in 0..<characters.count where !paths[start].isEmpty {
            let upperBound = min(characters.count, start + maximumCodeLength)
            guard start < upperBound else { continue }

            for end in (start + 1)...upperBound {
                let key = String(characters[start..<end])
                guard let segmentCandidates = entries[key] else { continue }

                for path in paths[start] {
                    for segment in segmentCandidates.prefix(3) {
                        // Fewer, longer lexical segments read more naturally than
                        // a chain of independently high-frequency single characters.
                        let segmentPenalty = path.segmentCount == 0 ? 0 : 9.0
                        let lengthBonus = Double(segment.text.count * segment.text.count) * 0.22
                        paths[end].append(
                            Path(
                                text: path.text + segment.text,
                                score: path.score + segment.score + lengthBonus - segmentPenalty,
                                segmentCount: path.segmentCount + 1
                            )
                        )
                    }
                }

                if paths[end].count > beamWidth * 3 {
                    paths[end] = bestPaths(paths[end], limit: beamWidth)
                }
            }
        }

        return bestPaths(paths[characters.count], limit: limit).map {
            PinyinCandidate(text: $0.text, score: $0.score - Double($0.segmentCount) * 0.1)
        }
    }

    private func bestPaths(_ paths: [Path], limit: Int) -> [Path] {
        var bestByText: [String: Path] = [:]
        for path in paths {
            if let existing = bestByText[path.text], existing.score >= path.score {
                continue
            }
            bestByText[path.text] = path
        }
        return bestByText.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private static func loadSelectionCounts(
        from store: UserDefaults?
    ) -> [String: [String: Int]] {
        guard let data = store?.data(forKey: learningStorageKey),
              let decoded = try? JSONDecoder().decode(
                [String: [String: Int]].self,
                from: data
              ) else { return [:] }
        return decoded
    }

    private func persistSelectionCounts() {
        guard let learningStore,
              let data = try? JSONEncoder().encode(selectionCounts) else { return }
        learningStore.set(data, forKey: Self.learningStorageKey)
    }
}
