import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 智能格式化器 - 自动检测口语中的列表/步骤模式并格式化
///
/// 对标 Typeless 的 auto-formatting 功能:
/// - 检测编号列表模式 ("第一" "第二" "第三")
/// - 检测步骤模式 ("首先" "其次" "最后")
/// - 检测序数模式 ("第一点" "第二点")
/// - 检测英文列表 ("number one" "number two" / "first" "second")
/// - 检测清单触发词 ("列个清单" "列个列表")
/// - LLM 模式下智能格式化(iOS 26+)
class SmartFormatter {

    static let shared = SmartFormatter()

    private let sharedDefaults = UserDefaults(suiteName: "group.com.voiceinput.shared")

    var autoFormatEnabled: Bool {
        sharedDefaults?.object(forKey: "autoFormat") as? Bool ?? true
    }

    // MARK: - 中文编号列表模式

    /// 中文序数词映射
    private let chineseOrdinals: [(String, Int)] = [
        ("第一", 1), ("第二", 2), ("第三", 3), ("第四", 4), ("第五", 5),
        ("第六", 6), ("第七", 7), ("第八", 8), ("第九", 9), ("第十", 10),
    ]

    /// 中文顺序词
    private let chineseSequence: [(String, Int)] = [
        ("首先", 1), ("其次", 2), ("然后", 3), ("接着", 4), ("最后", 5),
        ("第一点", 1), ("第二点", 2), ("第三点", 3), ("第四点", 4), ("第五点", 5),
    ]

    // MARK: - 英文列表模式

    /// 英文序数词
    private let englishOrdinals: [(String, Int)] = [
        ("number one", 1), ("number two", 2), ("number three", 3),
        ("number four", 4), ("number five", 5), ("number six", 6),
        ("number seven", 7), ("number eight", 8), ("number nine", 9),
        ("number ten", 10),
        ("first", 1), ("second", 2), ("third", 3), ("fourth", 4), ("fifth", 5),
        ("sixth", 6), ("seventh", 7), ("eighth", 8), ("ninth", 9), ("tenth", 10),
        ("step one", 1), ("step two", 2), ("step three", 3),
        ("step four", 4), ("step five", 5),
        ("point one", 1), ("point two", 2), ("point three", 3),
    ]

    /// 日文序数词
    private let japaneseOrdinals: [(String, Int)] = [
        ("1つ目", 1), ("2つ目", 2), ("3つ目", 3), ("4つ目", 4), ("5つ目", 5),
        ("1番目", 1), ("2番目", 2), ("3番目", 3),
        ("第一", 1), ("第二", 2), ("第三", 3),
    ]

    /// 韩文序数词
    private let koreanOrdinals: [(String, Int)] = [
        ("첫째", 1), ("둘째", 2), ("셋째", 3), ("넷째", 4), ("다섯째", 5),
        ("첫번째", 1), ("두번째", 2), ("세번째", 3),
    ]

    // MARK: - 格式化入口

    /// 检测文本中是否包含列表模式，如果包含则格式化
    func formatIfList(_ text: String) -> String {
        guard autoFormatEnabled else { return text }

        let lang = LanguageManager.shared.currentLanguageID

        // 检测是否有列表触发词
        if hasListTrigger(text, lang: lang) || detectListCount(text) >= 2 {
            return formatAsList(text, lang: lang)
        }

        return text
    }

    // MARK: - 列表触发词检测

    private func hasListTrigger(_ text: String, lang: String) -> Bool {
        let triggers: [String]
        switch lang.prefix(2) {
        case "zh":
            triggers = ["列个清单", "列个列表", "列出来", "列举一下", "有几", "清单", "列表", "步骤"]
        case "en":
            triggers = ["make a list", "list the", "list them", "here are", "steps are", "bullet points"]
        case "ja":
            triggers = ["リスト", "箇条書き", "一覧"]
        case "ko":
            triggers = ["목록", "리스트"]
        default:
            triggers = ["make a list", "list", "list"]
        }

        let lower = text.lowercased()
        return triggers.contains { lower.contains($0.lowercased()) }
    }

    // MARK: - 列表检测

    /// 检测文本中包含多少个序数标记
    func detectListCount(_ text: String) -> Int {
        let patterns = getAllOrdinalPatterns()
        var count = 0
        let lower = text.lowercased()

        for (keyword, _) in patterns {
            let occurrences = lower.components(separatedBy: keyword.lowercased()).count - 1
            count += occurrences
        }

        return count
    }

    private func getAllOrdinalPatterns() -> [(String, Int)] {
        let lang = LanguageManager.shared.currentLanguageID
        switch lang.prefix(2) {
        case "zh":
            return chineseOrdinals + chineseSequence
        case "en":
            return englishOrdinals
        case "ja":
            return japaneseOrdinals
        case "ko":
            return koreanOrdinals
        default:
            return englishOrdinals + chineseOrdinals
        }
    }

    // MARK: - 格式化为列表

    func formatAsList(_ text: String, lang: String) -> String {
        let patterns = getAllOrdinalPatterns()
        var items: [(index: Int, content: String)] = []

        // 按序数词分割文本
        var remainingText = text
        var positions: [(start: Int, length: Int, ordinal: Int)] = []

        for (keyword, ordinal) in patterns {
            var searchStart = remainingText.startIndex
            let lowerRemaining = remainingText.lowercased()
            let lowerKeyword = keyword.lowercased()

            while let range = lowerRemaining.range(of: lowerKeyword, range: searchStart..<lowerRemaining.endIndex) {
                let pos = remainingText.distance(from: remainingText.startIndex, to: range.lowerBound)
                positions.append((pos, keyword.count, ordinal))
                searchStart = range.upperBound
            }
        }

        // 没有序数词或只有1个，不格式化
        if positions.count < 2 {
            return text
        }

        // 按位置排序
        positions.sort { $0.start < $1.start }

        // 提取每个条目的内容
        for i in 0..<positions.count {
            let contentStart = positions[i].start + positions[i].length
            let contentEnd = (i + 1 < positions.count) ? positions[i + 1].start : remainingText.count

            if contentStart < contentEnd && contentStart < remainingText.count {
                let startIdx = remainingText.index(remainingText.startIndex, offsetBy: min(contentStart, remainingText.count))
                let endIdx = remainingText.index(remainingText.startIndex, offsetBy: min(contentEnd, remainingText.count))
                var content = String(remainingText[startIdx..<endIdx])

                // 清理内容: 去除前后逗号、句号、空格
                content = content.trimmingCharacters(in: CharacterSet(charactersIn: ",，。、；; \n\t"))

                if !content.isEmpty {
                    // 使用实际序数值
                    let actualOrdinal = positions[i].ordinal
                    items.append((actualOrdinal, content))
                }
            }
        }

        // 生成格式化文本
        guard items.count >= 2 else { return text }

        var result = ""
        for item in items {
            result += "\(item.index). \(item.content)\n"
        }

        // 去除末尾换行
        result = result.trimmingCharacters(in: .newlines)

        return result
    }

    // MARK: - LLM 智能格式化 (iOS 26+)

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    func llmFormat(_ text: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let lang = LanguageManager.shared.currentLanguage.name

        let instructions = """
        You are a voice-to-text formatting assistant. The input language is \(lang).
        Analyze the following speech-to-text result and format it appropriately:
        1. If the content contains a list, steps, or enumeration, format it as a numbered list
        2. If the content contains distinct points, separate them with line breaks
        3. Do NOT add or remove information
        4. Do NOT change the language or meaning
        5. Return ONLY the formatted text
        6. If the text is a single continuous thought, keep it as-is (no formatting needed)
        7. Use the appropriate numbering format for the language (1. for English, 1. for Chinese, etc.)
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text)
            let formatted = response.content

            // 安全检查: 格式化后不应过短或过长
            if formatted.count < text.count / 3 || formatted.count > text.count * 3 {
                return nil
            }

            return formatted
        } catch {
            return nil
        }
    }
    #endif
}
