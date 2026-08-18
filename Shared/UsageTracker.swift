import Foundation

/// 使用统计追踪器 - 记录使用数据并支持活动仪表盘
///
/// 对标 Typeless 的 Activity Dashboard:
/// - 总输入字数
/// - 总会话数
/// - 语言使用分布
/// - 功能使用统计(翻译/格式化/纠正等)
/// - 每日使用记录(最近7天)
/// - 连续使用天数(Streak)
class UsageTracker {

    static let shared = UsageTracker()

    private let sharedDefaults = UserDefaults(suiteName: "group.com.voiceinput.shared")

    // MARK: - 记录使用

    /// 记录一次语音输入会话
    func recordSession(charCount: Int, language: String, featuresUsed: Set<String> = []) {
        // 总字数
        let totalChars = sharedDefaults?.integer(forKey: "usage_totalChars") ?? 0
        sharedDefaults?.set(totalChars + charCount, forKey: "usage_totalChars")

        // 总会话数
        let totalSessions = sharedDefaults?.integer(forKey: "usage_totalSessions") ?? 0
        sharedDefaults?.set(totalSessions + 1, forKey: "usage_totalSessions")

        // 语言分布
        var langDist = sharedDefaults?.dictionary(forKey: "usage_langDist") as? [String: Int] ?? [:]
        langDist[language, default: 0] += 1
        sharedDefaults?.set(langDist, forKey: "usage_langDist")

        // 功能使用
        var featureCounts = sharedDefaults?.dictionary(forKey: "usage_features") as? [String: Int] ?? [:]
        for feature in featuresUsed {
            featureCounts[feature, default: 0] += 1
        }
        sharedDefaults?.set(featureCounts, forKey: "usage_features")

        // 每日记录
        recordDailyUsage()

        // Streak
        updateStreak()
    }

    // MARK: - 每日记录

    private func recordDailyUsage() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        var daily = sharedDefaults?.dictionary(forKey: "usage_daily") as? [String: Int] ?? [:]
        daily[today, default: 0] += 1

        // 只保留最近7天
        if daily.count > 7 {
            let sortedDates = daily.keys.sorted()
            for oldDate in sortedDates.prefix(daily.count - 7) {
                daily.removeValue(forKey: oldDate)
            }
        }

        sharedDefaults?.set(daily, forKey: "usage_daily")
    }

    // MARK: - Streak 计算

    private func updateStreak() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let yesterday = formatter.string(from: Date(timeIntervalSinceNow: -86400))

        let lastUseDate = sharedDefaults?.string(forKey: "usage_lastUseDate") ?? ""
        var currentStreak = sharedDefaults?.integer(forKey: "usage_streak") ?? 0

        if lastUseDate == today {
            // 今天已经记录过了,不重复加
        } else if lastUseDate == yesterday {
            // 连续使用
            currentStreak += 1
        } else {
            // 断了,重新开始
            currentStreak = 1
        }

        sharedDefaults?.set(currentStreak, forKey: "usage_streak")
        sharedDefaults?.set(today, forKey: "usage_lastUseDate")

        // 最长 streak
        let maxStreak = sharedDefaults?.integer(forKey: "usage_maxStreak") ?? 0
        if currentStreak > maxStreak {
            sharedDefaults?.set(currentStreak, forKey: "usage_maxStreak")
        }
    }

    // MARK: - 读取统计数据

    struct UsageStats {
        let totalChars: Int
        let totalSessions: Int
        let languageDistribution: [(name: String, flag: String, count: Int)]
        let featureUsage: [(feature: String, count: Int)]
        let dailyUsage: [(date: String, count: Int)]
        let currentStreak: Int
        let maxStreak: Int
    }

    var stats: UsageStats {
        let totalChars = sharedDefaults?.integer(forKey: "usage_totalChars") ?? 0
        let totalSessions = sharedDefaults?.integer(forKey: "usage_totalSessions") ?? 0

        let langDist = sharedDefaults?.dictionary(forKey: "usage_langDist") as? [String: Int] ?? [:]
        let languageDistribution = langDist
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (id, count) -> (name: String, flag: String, count: Int) in
                let config = LanguageManager.allLanguages.first { $0.id == id }
                return (config?.name ?? id, config?.flag ?? "", count)
            }

        let featureCounts = sharedDefaults?.dictionary(forKey: "usage_features") as? [String: Int] ?? [:]
        let featureUsage = featureCounts
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }

        let daily = sharedDefaults?.dictionary(forKey: "usage_daily") as? [String: Int] ?? [:]
        let dailyUsage = daily
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }

        let currentStreak = sharedDefaults?.integer(forKey: "usage_streak") ?? 0
        let maxStreak = sharedDefaults?.integer(forKey: "usage_maxStreak") ?? 0

        return UsageStats(
            totalChars: totalChars,
            totalSessions: totalSessions,
            languageDistribution: Array(languageDistribution),
            featureUsage: featureUsage,
            dailyUsage: dailyUsage,
            currentStreak: currentStreak,
            maxStreak: maxStreak
        )
    }

    // MARK: - 重置

    func resetAll() {
        sharedDefaults?.removeObject(forKey: "usage_totalChars")
        sharedDefaults?.removeObject(forKey: "usage_totalSessions")
        sharedDefaults?.removeObject(forKey: "usage_langDist")
        sharedDefaults?.removeObject(forKey: "usage_features")
        sharedDefaults?.removeObject(forKey: "usage_daily")
        sharedDefaults?.removeObject(forKey: "usage_streak")
        sharedDefaults?.removeObject(forKey: "usage_maxStreak")
        sharedDefaults?.removeObject(forKey: "usage_lastUseDate")
    }

    // MARK: - 功能名称

    static func featureDisplayName(_ feature: String) -> String {
        switch feature {
        case "translation": return "翻译"
        case "autoFormat": return "自动格式化"
        case "smartCorrection": return "自我纠正"
        case "llmPolish": return "LLM润色"
        case "autoPunctuation": return "自动标点"
        case "fillerRemoval": return "口水词过滤"
        case "voiceEdit": return "语音编辑"
        case "whisper": return "耳语模式"
        default: return feature
        }
    }
}
