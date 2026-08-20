import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 翻译管理器 - 实时语音翻译
///
/// 对标 Typeless 的翻译功能:
/// - 说中文 → 输出英文(或其他目标语言)
/// - 说英文 → 输出中文
/// - iOS 26+ 使用设备端 LLM 做高质量翻译
/// - 低版本回退到简单词典替换(仅中英互译)
class TranslationManager {

    static let shared = TranslationManager()

    private let sharedDefaults = UserDefaults.standard as UserDefaults?

    // MARK: - 翻译模式

    var translationEnabled: Bool {
        sharedDefaults?.object(forKey: "translationEnabled") as? Bool ?? false
    }

    func setTranslationEnabled(_ enabled: Bool) {
        sharedDefaults?.set(enabled, forKey: "translationEnabled")
    }

    /// 目标翻译语言 ID
    var targetLanguageID: String {
        get {
            sharedDefaults?.string(forKey: "translationTarget") ?? "en-US"
        }
        set {
            sharedDefaults?.set(newValue, forKey: "translationTarget")
        }
    }

    // MARK: - 翻译入口

    /// 翻译文本到目标语言
    /// - Parameter text: 原始文本
    /// - Parameter sourceLang: 源语言 ID
    /// - Returns: 翻译后的文本,如果翻译失败返回 nil
    func translate(_ text: String, from sourceLang: String) async -> String? {
        guard !text.isEmpty else { return nil }

        let targetLang = targetLanguageID
        guard targetLang != sourceLang else { return nil }

        // 获取目标语言名
        let targetConfig = LanguageManager.allLanguages.first { $0.id == targetLang }
        let sourceConfig = LanguageManager.allLanguages.first { $0.id == sourceLang }

        let targetName = targetConfig?.name ?? targetLang
        let sourceName = sourceConfig?.name ?? sourceLang

        // LLM 翻译 (iOS 26+)
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return await llmTranslate(text, from: sourceName, to: targetName)
        }
        #endif

        // 低版本回退: 简单中英互译
        return simpleTranslate(text, from: sourceLang, to: targetLang)
    }

    // MARK: - LLM 翻译 (iOS 26+)

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func llmTranslate(_ text: String, from sourceName: String, to targetName: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let instructions = """
        You are a professional translator. Translate the following text from \(sourceName) to \(targetName).
        Rules:
        1. Translate accurately, preserving the original meaning
        2. Keep the tone and style of the original text
        3. Do NOT add explanations or notes
        4. Return ONLY the translated text
        5. If the text is already in the target language, return it as-is
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text)
            let translated = response.content

            // 安全检查: 翻译结果长度应合理
            if translated.count > text.count * 3 || translated.count < text.count / 5 {
                return nil
            }

            return translated
        } catch {
            return nil
        }
    }
    #endif

    // MARK: - 简单翻译回退 (中英互译)

    private func simpleTranslate(_ text: String, from source: String, to target: String) -> String? {
        // 仅支持中英互译的简单回退
        let isZhSource = source.hasPrefix("zh")
        let isEnTarget = target.hasPrefix("en")

        if isZhSource && isEnTarget {
            // 中→英: 使用简单常用词替换(效果有限,仅作回退)
            // 实际高质量翻译需要 LLM
            return nil // 低版本不提供翻译,提示用户需要 iOS 26+
        }

        if source.hasPrefix("en") && target.hasPrefix("zh") {
            return nil
        }

        return nil
    }

    // MARK: - 翻译可用性

    var translationAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// 翻译模式状态描述
    var statusDescription: String {
        guard translationEnabled else { return "翻译关闭" }
        let target = LanguageManager.allLanguages.first { $0.id == targetLanguageID }
        let targetName = target?.name ?? targetLanguageID
        if translationAvailable {
            return "翻译至\(targetName)"
        } else {
            return "翻译需 iOS 26+"
        }
    }

    // MARK: - 目标语言切换

    /// 切换到下一个翻译目标语言
    @discardableResult
    func cycleTargetLanguage() -> LanguageConfig {
        let allLangs = LanguageManager.allLanguages
        let current = targetLanguageID

        if let idx = allLangs.firstIndex(where: { $0.id == current }) {
            let nextIdx = (idx + 1) % allLangs.count
            targetLanguageID = allLangs[nextIdx].id
            return allLangs[nextIdx]
        }
        targetLanguageID = allLangs[0].id
        return allLangs[0]
    }
}
