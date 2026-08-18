import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 文字后处理器 - 核心 AI 层
///
/// 双模式架构:
/// - iOS 26+: 使用 Apple Foundation Models 设备端 LLM 做智能润色
/// - iOS 16+: 使用增强规则引擎(自我纠正检测+口水词过滤+自动标点)
///
/// 对标 Typeless 的 AI 后处理层,但完全离线、完全免费
class TextProcessor {

    // MARK: - 单例

    static let shared = TextProcessor()

    // MARK: - 设置

    private let sharedDefaults = UserDefaults(suiteName: "group.com.voiceinput.shared")

    var autoPunctuationEnabled: Bool {
        sharedDefaults?.object(forKey: "autoPunctuation") as? Bool ?? true
    }
    var fillerWordRemovalEnabled: Bool {
        sharedDefaults?.object(forKey: "fillerWordRemoval") as? Bool ?? true
    }
    var smartCorrectionEnabled: Bool {
        sharedDefaults?.object(forKey: "smartCorrection") as? Bool ?? true
    }
    var llmPolishEnabled: Bool {
        sharedDefaults?.object(forKey: "llmPolish") as? Bool ?? true
    }
    var livePreviewEnabled: Bool {
        sharedDefaults?.object(forKey: "livePreview") as? Bool ?? true
    }

    // MARK: - 口水词

    private let fillerWords: Set<String> = [
        "嗯", "啊", "呃", "哦", "唉", "嘛", "呢", "哈",
        "那个", "这个", "就是", "然后", "所以说", "对吧",
        "怎么说呢", "说实话", "你知道吗", "其实吧",
        "like", "you know", "I mean", "sort of", "kind of"
    ]

    // MARK: - 个人词典

    private var personalDictionary: [String: String] {
        get {
            sharedDefaults?.dictionary(forKey: "personalDictionary") as? [String: String] ?? [:]
        }
        set {
            sharedDefaults?.set(newValue, forKey: "personalDictionary")
        }
    }

    func addDictionaryEntry(speech: String, replacement: String) {
        var dict = personalDictionary
        dict[speech] = replacement
        personalDictionary = dict
    }

    func removeDictionaryEntry(speech: String) {
        var dict = personalDictionary
        dict.removeValue(forKey: speech)
        personalDictionary = dict
    }

    func getAllDictionaryEntries() -> [String: String] {
        personalDictionary
    }

    // MARK: - 主处理入口

    /// 同步快速处理(用于实时预览,不含 LLM)
    func processSync(_ rawText: String) -> String {
        guard !rawText.isEmpty else { return rawText }

        var result = rawText

        result = applyPersonalDictionary(to: result)

        if smartCorrectionEnabled {
            result = detectSelfCorrection(in: result)
        }

        if fillerWordRemovalEnabled {
            result = removeFillerWords(from: result)
        }

        return result
    }

    /// 完整异步处理(停止录音时调用,含 LLM)
    func process(_ rawText: String) async -> String {
        guard !rawText.isEmpty else { return rawText }

        var result = rawText

        // 1. 个人词典替换 (最优先)
        result = applyPersonalDictionary(to: result)

        // 2. 自我纠正检测
        if smartCorrectionEnabled {
            result = detectSelfCorrection(in: result)
        }

        // 3. 口水词过滤
        if fillerWordRemovalEnabled {
            result = removeFillerWords(from: result)
        }

        // 4. 尝试 LLM 润色 (iOS 26+)
        if llmPolishEnabled {
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                result = await llmPolish(result) ?? result
            }
            #endif
        }

        // 5. 自动标点
        if autoPunctuationEnabled {
            result = addAutoPunctuation(to: result)
        }

        return result
    }

    // MARK: - 自我纠正检测

    /// 检测口语中的自我纠正,保留最终正确版本
    ///
    /// 示例:
    /// "明天上午9点,不对,明天下午3点" → "明天下午3点"
    /// "叫什么来着,对,王若虚" → "王若虚"
    /// "算了,应该是明天" → "明天"
    func detectSelfCorrection(in text: String) -> String {
        var result = text

        // 模式: "X,不对,是Y" 或 "X,不对,应该是Y" → Y
        let correctionPatterns: [(NSRegularExpression, String)] = [
            // "X 不对 是Y" / "X 不对 应该是Y" → Y
            (try! NSRegularExpression(pattern: "[^,，。！？]+[,，]?不对[,，]?(?:应该是|是)?(.+?)"), "$1"),
            // "X 啊不对 Y" → Y
            (try! NSRegularExpression(pattern: "[^,，。！？]+[,，]?啊不对[,，]?(.+?)"), "$1"),
            // "X 说错了 是Y" → Y
            (try! NSRegularExpression(pattern: "[^,，。！？]+[,，]?说错了[,，]?(?:是)?(.+?)"), "$1"),
            // "X 算了 应该是Y" → Y
            (try! NSRegularExpression(pattern: "[^,，。！？]+[,，]?算了[,，]?(?:应该是|是)?(.+?)"), "$1"),
            // "X 不是 应该是Y" → Y
            (try! NSRegularExpression(pattern: "[^,，。！？]+[,，]?不是[,，]?(?:应该是|是)?(.+?)"), "$1"),
            // "叫什么来着 对 Y" → Y (回忆模式)
            (try! NSRegularExpression(pattern: "叫什么来着[,，]?对[,，]?(.+?)"), "$1"),
            // "那个叫什么 对 Y" → Y
            (try! NSRegularExpression(pattern: "那个叫什么[,，]?对[,，]?(.+?)"), "$1"),
        ]

        for (pattern, replacement) in correctionPatterns {
            let range = NSRange(result.startIndex..., in: result)
            if let match = pattern.firstMatch(in: result, options: [], range: range),
               match.numberOfRanges >= 2,
               let captureRange = Range(match.range(at: 1), in: result) {
                result = String(result[captureRange])
                break // 只处理第一个纠正
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 口水词过滤

    func removeFillerWords(from text: String) -> String {
        var result = text
        for word in fillerWords {
            result = result.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 自动标点

    func addAutoPunctuation(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        let punctuationSet: Set<Character> = ["。", "！", "？", "，", "、", "：", "；", ".", "!", "?", ","]
        if let last = result.last, punctuationSet.contains(last) {
            return result
        }

        let questionEndings = ["吗", "呢", "吧", "嘛"]
        let questionWords = ["怎么", "什么", "为什么", "哪里", "哪儿", "谁", "哪个", "哪些", "多少", "几", "是不是", "能不能", "可不可以", "难道"]

        let lastChar = String(result.last ?? Character(" "))

        var isQuestion = false
        if questionEndings.contains(lastChar) {
            isQuestion = true
        }
        for word in questionWords {
            if result.contains(word) {
                isQuestion = true
                break
            }
        }

        if isQuestion {
            result += "？"
        } else {
            result += "。"
        }

        return result
    }

    // MARK: - 个人词典替换

    private func applyPersonalDictionary(to text: String) -> String {
        var result = text
        for (speech, replacement) in personalDictionary {
            result = result.replacingOccurrences(
                of: speech,
                with: replacement,
                options: .caseInsensitive
            )
        }
        return result
    }

    // MARK: - LLM 润色 (iOS 26+)

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func llmPolish(_ text: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let instructions = """
        你是语音输入的文字清理助手。请清理以下语音转文字的结果:
        1. 移除多余的口水词(嗯、啊、那个等)
        2. 修复明显的识别错误
        3. 保持原意不变,不要添加或删除信息
        4. 不要改变说话者的语气和风格
        5. 只返回清理后的文字,不要解释

        注意:不要自作主张改变格式,不要添加列表或分段,保持原始的一段文字。
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text)
            let cleaned = response.content

            // 如果 LLM 返回的结果比原文长太多或短太多,说明可能出了问题,放弃使用
            if cleaned.count > text.count * 2 || cleaned.count < text.count / 3 {
                return nil
            }

            return cleaned
        } catch {
            return nil
        }
    }
    #endif

    // MARK: - 语言检测

    /// 使用 NaturalLanguage 框架检测文本语言
    func detectLanguage(in text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        if let language = recognizer.dominantLanguage {
            switch language {
            case .simplifiedChinese, .traditionalChinese:
                return "zh-CN"
            case .english:
                return "en-US"
            case .japanese:
                return "ja-JP"
            case .korean:
                return "ko-KR"
            case .french:
                return "fr-FR"
            case .german:
                return "de-DE"
            case .spanish:
                return "es-ES"
            default:
                return "zh-CN" // 默认中文
            }
        }
        return "zh-CN"
    }

    // MARK: - LLM 可用性

    var llmAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
}
