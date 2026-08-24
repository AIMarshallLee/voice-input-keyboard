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
    private struct Path {
        let text: String
        let score: Double
        let segmentCount: Int
    }

    private var entries: [String: [PinyinCandidate]] = [:]
    private var maximumCodeLength = 0
    private let perCodeLimit: Int

    init(dictionaryText: String, perCodeLimit: Int = 8) {
        self.perCodeLimit = max(1, perCodeLimit)
        load(dictionaryText)
    }

    convenience init?(bundle: Bundle = .main) {
        guard let url = bundle.url(
            forResource: "pinyin_simp",
            withExtension: "dict"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        self.init(dictionaryText: text)
    }

    var isReady: Bool { !entries.isEmpty }

    func candidates(for rawInput: String, limit: Int = 10) -> [String] {
        let code = Self.normalize(rawInput)
        guard !code.isEmpty, limit > 0 else { return [] }

        var ranked: [PinyinCandidate] = entries[code] ?? []
        ranked.append(contentsOf: composedCandidates(for: code, limit: limit * 2))

        var bestScoreByText: [String: Double] = [:]
        for candidate in ranked where !candidate.text.isEmpty {
            bestScoreByText[candidate.text] = max(
                bestScoreByText[candidate.text] ?? -.infinity,
                candidate.score
            )
        }

        return bestScoreByText
            .map { PinyinCandidate(text: $0.key, score: $0.value) }
            .sorted {
                if $0.score == $1.score {
                    return $0.text.count < $1.text.count
                }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map(\.text)
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
                        let segmentPenalty = path.segmentCount == 0 ? 0 : 1.8
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
}
