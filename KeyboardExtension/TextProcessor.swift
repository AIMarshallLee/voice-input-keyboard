import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 输入场景类型
enum InputContext: Int {
    case general = 0    // 普通文本
    case email = 1      // 邮箱输入
    case url = 2        // URL 输入
    case phone = 3      // 电话号码
    case number = 4     // 纯数字
    case social = 5     // 社交媒体/短文本

    /// 从 UIKeyboardType 转换
    static func from(keyboardType: Int) -> InputContext {
        switch keyboardType {
        case 7: return .email    // .emailAddress
        case 3: return .url       // .URL
        case 5: return .phone      // .phonePad
        case 4: return .number    // .numberPad
        case 9: return .social     // .twitter
        default: return .general
        }
    }

    var displayName: String {
        switch self {
        case .general: return "通用"
        case .email: return "邮件"
        case .url: return "网址"
        case .phone: return "电话"
        case .number: return "数字"
        case .social: return "社交"
        }
    }
}

/// 文字后处理器 - 核心 AI 层
///
/// 全功能架构:
/// - iOS 26+: LLM 智能润色 + 翻译 + 格式化 + 语音编辑
/// - iOS 16+: 规则引擎(自我纠正+口水词+标点+格式化+翻译回退)
///
/// 全面对标并超越 Typeless,完全离线、完全免费
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
    var autoFormatEnabled: Bool {
        sharedDefaults?.object(forKey: "autoFormat") as? Bool ?? true
    }
    var contextAwareEnabled: Bool {
        sharedDefaults?.object(forKey: "contextAware") as? Bool ?? true
    }
    var voiceEditEnabled: Bool {
        sharedDefaults?.object(forKey: "voiceEdit") as? Bool ?? true
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
    /// - Parameters:
    ///   - rawText: 原始识别文本
    ///   - selectedText: 用户选中的文本(如有,进入语音编辑模式)
    ///   - keyboardType: 当前输入框类型(用于场景感知)
    func process(_ rawText: String, selectedText: String? = nil, keyboardType: Int = 0) async -> String {
        guard !rawText.isEmpty else { return rawText }

        var result = rawText
        let context = InputContext.from(keyboardType: keyboardType)
        var featuresUsed: Set<String> = []
        var isVoiceEdit = false

        // 0. 语音编辑: 如果有选中文本,进入编辑模式
        if voiceEditEnabled, let selected = selectedText, !selected.isEmpty {
            isVoiceEdit = true
            featuresUsed.insert("voiceEdit")
            result = await processVoiceEdit(spoken: result, selectedText: selected, context: context)
        }

        if !isVoiceEdit {
            // 1. 个人词典替换 (最优先)
            result = applyPersonalDictionary(to: result)

            // 2. 自我纠正检测
            if smartCorrectionEnabled {
                result = detectSelfCorrection(in: result)
                featuresUsed.insert("smartCorrection")
            }

            // 3. 口水词过滤
            if fillerWordRemovalEnabled {
                result = removeFillerWords(from: result)
                featuresUsed.insert("fillerRemoval")
            }

            // 4. 尝试 LLM 润色 (iOS 26+, 场景感知)
            if llmPolishEnabled {
                #if canImport(FoundationModels)
                if #available(iOS 26, *) {
                    if let polished = await llmPolish(result, context: context) {
                        result = polished
                        featuresUsed.insert("llmPolish")
                    }
                }
                #endif
            }
        }

        // 5. 翻译 (如果启用)
        if TranslationManager.shared.translationEnabled {
            let sourceLang = LanguageManager.shared.currentLanguageID
            if let translated = await TranslationManager.shared.translate(result, from: sourceLang) {
                result = translated
                featuresUsed.insert("translation")
            }
        }

        // 6. 自动格式化 (列表检测)
        if autoFormatEnabled && !isVoiceEdit {
            let formatted = SmartFormatter.shared.formatIfList(result)
            if formatted != result {
                result = formatted
                featuresUsed.insert("autoFormat")
            } else {
                // 没有格式化为列表,则添加标点
                if autoPunctuationEnabled {
                    result = addAutoPunctuation(to: result)
                    featuresUsed.insert("autoPunctuation")
                }
            }
        } else if autoPunctuationEnabled && !isVoiceEdit {
            // 7. 自动标点
            result = addAutoPunctuation(to: result)
            featuresUsed.insert("autoPunctuation")
        }

        // 记录使用统计
        UsageTracker.shared.recordSession(
            charCount: result.count,
            language: LanguageManager.shared.currentLanguageID,
            featuresUsed: featuresUsed
        )

        return result
    }

    // MARK: - 语音编辑

    /// 语音编辑: 根据用户说的内容,修改选中的文本
    ///
    /// 模式:
    /// 1. "替换为XXX" / "改成XXX" → 直接替换为 XXX
    /// 2. "删掉" / "删除" → 返回空字符串(删除选中文本)
    /// 3. "在后面加XXX" / "加上XXX" → 选中文本 + XXX
    /// 4. 无明确指令 → LLM 智能合并(iOS 26+) 或直接替换
    func processVoiceEdit(spoken: String, selectedText: String, context: InputContext) async -> String {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)

        // 模式1: 明确替换指令
        let replacePatterns = ["替换为", "替换成", "改成", "改为", "换成", "改成", "replace with", "change to"]
        for pattern in replacePatterns {
            if let range = trimmed.range(of: pattern, options: .caseInsensitive) {
                let replacement = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !replacement.isEmpty {
                    return replacement
                }
            }
        }

        // 模式2: 删除指令
        let deletePatterns = ["删掉", "删除", "去掉", "移除", "delete", "remove"]
        for pattern in deletePatterns {
            if trimmed.lowercased() == pattern || trimmed.lowercased().contains(pattern + "这个") || trimmed.lowercased().contains(pattern + "它") {
                return "" // 空字符串表示删除
            }
        }

        // 模式3: 追加指令
        let appendPatterns = ["在后面加", "在后面加上", "后面加", "加上", "追加", "append", "add after"]
        for pattern in appendPatterns {
            if let range = trimmed.range(of: pattern, options: .caseInsensitive) {
                let addition = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !addition.isEmpty {
                    return selectedText + addition
                }
            }
        }

        // 模式4: LLM 智能合并 (iOS 26+)
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if let merged = await llmVoiceEdit(spoken: trimmed, selectedText: selectedText, context: context) {
                return merged
            }
        }
        #endif

        // 模式5: 回退 - 直接替换选中文本
        return trimmed
    }

    // MARK: - LLM 语音编辑 (iOS 26+)

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func llmVoiceEdit(spoken: String, selectedText: String, context: InputContext) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let instructions = """
        You are a voice editing assistant. The user has selected some text and is speaking to edit it.
        Selected text: "\(selectedText)"
        Spoken instruction: "\(spoken)"

        Apply the user's spoken instruction to the selected text and return the result.
        Rules:
        1. If the user is correcting or replacing, return the new version
        2. If the user is adding to the text, return the combined result
        3. If the user wants to delete, return an empty string
        4. Return ONLY the final text, no explanations
        5. Keep the same language as the selected text
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: spoken)
            return response.content
        } catch {
            return nil
        }
    }
    #endif

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

        for (pattern, _) in correctionPatterns {
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

    // MARK: - 自动标点 (基于当前语言规则)

    func addAutoPunctuation(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        let lang = LanguageManager.shared.currentLanguage
        let rules = lang.punctuationRules

        // 如果已有标点结尾,不重复添加
        let punctuationSet: Set<Character> = Set("。！？，、：；.!?,;\(rules.sentenceEnd)\(rules.questionMark)\(rules.comma)")
        if let last = result.last, punctuationSet.contains(last) {
            return result
        }

        let lastChar = String(result.last ?? Character(" ")).lowercased()

        var isQuestion = false

        // 检查问句结尾词
        for ending in rules.questionEndings {
            if lastChar.hasSuffix(ending.lowercased()) {
                isQuestion = true
                break
            }
        }

        // 检查问句关键词
        if !isQuestion {
            let lowerResult = result.lowercased()
            for word in rules.questionWords {
                if lowerResult.contains(word.lowercased()) {
                    isQuestion = true
                    break
                }
            }
        }

        if isQuestion {
            result += rules.questionMark
        } else {
            result += rules.sentenceEnd
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

    // MARK: - LLM 润色 (iOS 26+, 场景感知)

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func llmPolish(_ text: String, context: InputContext = .general) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let lang = LanguageManager.shared.currentLanguage
        let langName = lang.name

        // 场景感知: 根据输入框类型调整润色策略
        var contextInstruction = ""
        if contextAwareEnabled {
            switch context {
            case .email:
                contextInstruction = "The user is typing in an email field. Format as a proper email address if applicable (no spaces, lowercase)."
            case .url:
                contextInstruction = "The user is typing a URL. Remove spaces, use proper URL format."
            case .phone:
                contextInstruction = "The user is typing a phone number. Keep only digits and + symbol."
            case .number:
                contextInstruction = "The user is typing numbers. Keep only numeric characters."
            case .social:
                contextInstruction = "The user is typing on a social media platform. Keep it concise and casual."
            case .general:
                contextInstruction = ""
            }
        }

        let instructions = """
        You are a voice-to-text cleanup assistant. The input language is \(langName).
        Clean up the following speech-to-text result:
        1. Remove filler words (um, uh, er, like, etc.)
        2. Fix obvious recognition errors
        3. Keep the original meaning, do not add or remove information
        4. Do not change the speaker's tone or style
        5. Return ONLY the cleaned text, no explanations
        6. Do NOT reformat: no lists, no paragraphs, keep it as one continuous text
        7. Do NOT auto-correct grammar unless it's clearly a recognition error
        \(contextInstruction.isEmpty ? "" : "8. \(contextInstruction)")
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
