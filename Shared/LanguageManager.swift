import Foundation
import Speech

/// 多语言管理器
///
/// 支持 20 种主流语言,用户可在宿主 App 中选择常用语言,
/// 键盘上通过语言按钮快速切换。
/// SFSpeechRecognizer 原生支持这些语言的离线识别。
struct LanguageConfig: Identifiable, Codable, Equatable {
    let id: String          // BCP 47 locale ID, e.g. "zh-CN"
    let name: String        // 显示名, e.g. "简体中文"
    let flag: String        // 国旗 emoji
    let punctuationRules: PunctuationRules
}

struct PunctuationRules: Codable, Equatable {
    let sentenceEnd: String       // 句末标点
    let questionMark: String      // 问号
    let comma: String             // 逗号
    let questionEndings: [String] // 问句结尾词
    let questionWords: [String]   // 问句关键词
}

class LanguageManager {

    static let shared = LanguageManager(defaults: SharedDefaults.shared)

    private let sharedDefaults: UserDefaults

    init(defaults: UserDefaults = SharedDefaults.shared) {
        self.sharedDefaults = defaults
    }

    // MARK: - 所有支持的语言

    static let allLanguages: [LanguageConfig] = [
        LanguageConfig(
            id: "zh-CN", name: "简体中文", flag: "🇨🇳",
            punctuationRules: PunctuationRules(
                sentenceEnd: "。",
                questionMark: "？",
                comma: "，",
                questionEndings: ["吗", "呢", "吧", "嘛"],
                questionWords: ["怎么", "什么", "为什么", "哪里", "哪儿", "谁", "哪个", "哪些", "多少", "几", "是不是", "能不能", "可不可以", "难道"]
            )
        ),
        LanguageConfig(
            id: "en-US", name: "English (US)", flag: "🇺🇸",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["what", "how", "why", "when", "where", "who", "which", "is", "are", "do", "does", "can", "could", "would", "should", "will"],
                questionWords: ["what", "how", "why", "when", "where", "who", "which"]
            )
        ),
        LanguageConfig(
            id: "en-GB", name: "English (UK)", flag: "🇬🇧",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["what", "how", "why", "when", "where", "who", "which", "is", "are", "do", "does", "can", "could", "would", "should", "will"],
                questionWords: ["what", "how", "why", "when", "where", "who", "which"]
            )
        ),
        LanguageConfig(
            id: "de-DE", name: "Deutsch", flag: "🇩🇪",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["was", "wie", "warum", "wann", "wo", "wer", "welche", "ist", "sind", "kann", "können", "würden", "sollten"],
                questionWords: ["was", "wie", "warum", "wann", "wo", "wer", "welche"]
            )
        ),
        LanguageConfig(
            id: "fr-FR", name: "Français", flag: "🇫🇷",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["quoi", "comment", "pourquoi", "quand", "où", "qui", "quel", "est", "sont", "peut", "peuvent"],
                questionWords: ["quoi", "comment", "pourquoi", "quand", "où", "qui", "quel"]
            )
        ),
        LanguageConfig(
            id: "es-ES", name: "Español", flag: "🇪🇸",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["qué", "cómo", "por qué", "cuándo", "dónde", "quién", "cuál", "es", "está", "puede"],
                questionWords: ["qué", "cómo", "por qué", "cuándo", "dónde", "quién", "cuál"]
            )
        ),
        LanguageConfig(
            id: "it-IT", name: "Italiano", flag: "🇮🇹",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["cosa", "come", "perché", "quando", "dove", "chi", "quale", "è", "sono", "può"],
                questionWords: ["cosa", "come", "perché", "quando", "dove", "chi", "quale"]
            )
        ),
        LanguageConfig(
            id: "pt-BR", name: "Português (BR)", flag: "🇧🇷",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["o que", "como", "por que", "quando", "onde", "quem", "qual", "é", "está", "pode"],
                questionWords: ["o que", "como", "por que", "quando", "onde", "quem", "qual"]
            )
        ),
        LanguageConfig(
            id: "ru-RU", name: "Русский", flag: "🇷🇺",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["что", "как", "почему", "когда", "где", "кто", "какой", "есть", "может"],
                questionWords: ["что", "как", "почему", "когда", "где", "кто", "какой"]
            )
        ),
        LanguageConfig(
            id: "ja-JP", name: "日本語", flag: "🇯🇵",
            punctuationRules: PunctuationRules(
                sentenceEnd: "。",
                questionMark: "？",
                comma: "、",
                questionEndings: ["か", "の", "かな"],
                questionWords: ["何", "どう", "なぜ", "いつ", "どこ", "だれ", "どれ"]
            )
        ),
        LanguageConfig(
            id: "ko-KR", name: "한국어", flag: "🇰🇷",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["뭐", "어떻게", "왜", "언제", "어디", "누가", "어느", "있어", "해"],
                questionWords: ["뭐", "어떻게", "왜", "언제", "어디", "누가", "어느"]
            )
        ),
        LanguageConfig(
            id: "ar-SA", name: "العربية", flag: "🇸🇦",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "؟",
                comma: "،",
                questionEndings: ["ما", "كيف", "لماذا", "متى", "أين", "من", "أي", "هل"],
                questionWords: ["ما", "كيف", "لماذا", "متى", "أين", "من", "أي", "هل"]
            )
        ),
        LanguageConfig(
            id: "hi-IN", name: "हिन्दी", flag: "🇮🇳",
            punctuationRules: PunctuationRules(
                sentenceEnd: "।",
                questionMark: "?",
                comma: ",",
                questionEndings: ["क्या", "कैसे", "क्यों", "कब", "कहाँ", "कौन", "कौनसा"],
                questionWords: ["क्या", "कैसे", "क्यों", "कब", "कहाँ", "कौन", "कौनसा"]
            )
        ),
        LanguageConfig(
            id: "tr-TR", name: "Türkçe", flag: "🇹🇷",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["ne", "nasıl", "neden", "ne zaman", "nerede", "kim", "hangi", "mi", "mı", "mu", "mü"],
                questionWords: ["ne", "nasıl", "neden", "ne zaman", "nerede", "kim", "hangi"]
            )
        ),
        LanguageConfig(
            id: "nl-NL", name: "Nederlands", flag: "🇳🇱",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["wat", "hoe", "waarom", "wanneer", "waar", "wie", "welke", "is", "kan", "zullen"],
                questionWords: ["wat", "hoe", "waarom", "wanneer", "waar", "wie", "welke"]
            )
        ),
        LanguageConfig(
            id: "th-TH", name: "ไทย", flag: "🇹🇭",
            punctuationRules: PunctuationRules(
                sentenceEnd: "",
                questionMark: "?",
                comma: ",",
                questionEndings: ["อะไร", "อย่างไร", "ทำไม", "เมื่อไร", "ที่ไหน", "ใคร", "ไหน"],
                questionWords: ["อะไร", "อย่างไร", "ทำไม", "เมื่อไร", "ที่ไหน", "ใคร", "ไหน"]
            )
        ),
        LanguageConfig(
            id: "vi-VN", name: "Tiếng Việt", flag: "🇻🇳",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["gì", "thế nào", "tại sao", "khi nào", "đâu", "ai", "nào"],
                questionWords: ["gì", "thế nào", "tại sao", "khi nào", "đâu", "ai", "nào"]
            )
        ),
        LanguageConfig(
            id: "sv-SE", name: "Svenska", flag: "🇸🇪",
            punctuationRules: PunctuationRules(
                sentenceEnd: ".",
                questionMark: "?",
                comma: ",",
                questionEndings: ["vad", "hur", "varför", "när", "var", "vem", "vilken", "är", "kan"],
                questionWords: ["vad", "hur", "varför", "när", "var", "vem", "vilken"]
            )
        ),
        LanguageConfig(
            id: "zh-TW", name: "繁體中文", flag: "🇹🇼",
            punctuationRules: PunctuationRules(
                sentenceEnd: "。",
                questionMark: "？",
                comma: "，",
                questionEndings: ["嗎", "呢", "吧", "嘛"],
                questionWords: ["怎麼", "什麼", "為什麼", "哪裡", "哪兒", "誰", "哪個", "哪些", "多少", "幾", "是不是", "能不能", "可不可以", "難道"]
            )
        ),
        LanguageConfig(
            id: "zh-HK", name: "粵語", flag: "🇭🇰",
            punctuationRules: PunctuationRules(
                sentenceEnd: "。",
                questionMark: "？",
                comma: "，",
                questionEndings: ["咩", "呢", "架", "嘛"],
                questionWords: ["點", "乜", "點解", "幾時", "邊度", "邊個", "邊度"]
            )
        ),
    ]

    // MARK: - 用户偏好

    /// 用户启用的语言 ID 列表
    var enabledLanguageIDs: [String] {
        get {
            sharedDefaults.stringArray(forKey: "enabledLanguages") ?? ["zh-CN", "en-US"]
        }
        set {
            sharedDefaults.set(newValue, forKey: "enabledLanguages")
        }
    }

    /// 当前选中的语言 ID
    var currentLanguageID: String {
        get {
            sharedDefaults.string(forKey: "currentLanguage") ?? "zh-CN"
        }
        set {
            sharedDefaults.set(newValue, forKey: "currentLanguage")
        }
    }

    // MARK: - 便捷方法

    /// 用户启用的语言配置列表
    var enabledLanguages: [LanguageConfig] {
        LanguageManager.allLanguages.filter { enabledLanguageIDs.contains($0.id) }
    }

    /// 当前语言配置
    var currentLanguage: LanguageConfig {
        LanguageManager.language(for: currentLanguageID)
    }

    /// 根据 BCP 47 ID 查找配置。兼容 URL 中的短 ID（如 `en`）和
    /// Apple 常见脚本标签（如 `zh-Hans` / `zh-Hant`）。
    static func language(for id: String) -> LanguageConfig {
        if let exact = allLanguages.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return exact
        }

        let normalized = id.lowercased()
        if normalized.hasPrefix("zh-hant") {
            return allLanguages.first(where: { $0.id == "zh-TW" }) ?? allLanguages[0]
        }
        if normalized.hasPrefix("zh-hk") || normalized.hasPrefix("yue") {
            return allLanguages.first(where: { $0.id == "zh-HK" }) ?? allLanguages[0]
        }

        let languageCode = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return allLanguages.first {
            let candidateCode = $0.id.lowercased().split(separator: "-").first.map { String($0) }
            return candidateCode == languageCode
        } ?? allLanguages[0]
    }

    /// 切换到下一个启用的语言
    @discardableResult
    func cycleToNextLanguage() -> LanguageConfig {
        let enabled = enabledLanguages
        guard !enabled.isEmpty else {
            return LanguageManager.allLanguages[0]
        }

        if let currentIdx = enabled.firstIndex(where: { $0.id == currentLanguageID }) {
            let nextIdx = (currentIdx + 1) % enabled.count
            currentLanguageID = enabled[nextIdx].id
            return enabled[nextIdx]
        } else {
            currentLanguageID = enabled[0].id
            return enabled[0]
        }
    }

    /// 设置当前语言
    func setLanguage(_ id: String) {
        currentLanguageID = id
    }

    /// 启用/禁用语言
    func toggleLanguage(_ id: String) {
        var current = enabledLanguageIDs
        if let idx = current.firstIndex(of: id) {
            // 至少保留一个语言
            if current.count > 1 {
                current.remove(at: idx)
            }
        } else {
            current.append(id)
            current.sort()
        }
        enabledLanguageIDs = current
    }

    /// 创建 SFSpeechRecognizer (基于当前语言)
    func createSpeechRecognizer() -> SFSpeechRecognizer? {
        let locale = Locale(identifier: currentLanguageID)
        var recognizer = SFSpeechRecognizer(locale: locale)
        if recognizer == nil {
            recognizer = SFSpeechRecognizer()
        }
        return recognizer
    }
}
