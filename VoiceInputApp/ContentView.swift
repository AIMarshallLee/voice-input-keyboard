import SwiftUI
import Speech
import AVFoundation

/// 主 App:引导安装 + 设置 + 词典管理 + 隐私说明
struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pipStandby = PiPStandbyManager.shared
    @StateObject private var keyboardSetup = KeyboardSetupChecklist()

    @State private var speechAuthorized = false
    @State private var micAuthorized = false
    @State private var autoPunctuation = true
    @State private var fillerWordRemoval = true
    @State private var livePreview = true
    @State private var smartCorrection = true
    @State private var llmPolish = true
    @State private var autoFormat = true
    @State private var contextAware = true
    @State private var voiceEdit = true
    @State private var enabledLanguageIDs: [String] = []

    // 翻译设置
    @State private var translationEnabled = false
    @State private var translationTargetID = "en-US"

    // 使用统计
    @State private var usageStats: UsageTracker.UsageStats?

    // 词典管理
    @State private var dictionaryEntries: [(String, String)] = []
    @State private var showAddEntry = false
    @State private var newSpeech = ""
    @State private var newReplacement = ""
    @State private var showBatchImport = false
    @State private var batchImportText = ""

    private let sharedDefaults: UserDefaults? = SharedDefaults.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // 标题
                    VStack(spacing: 8) {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.blue)
                        Text("VoType")
                            .font(.title2.bold())
                        Text("声入 · 语音转文字 · 翻译 · 格式化 · 语音编辑 · 场景感知 · 20语言")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    // 安装步骤
                    VStack(alignment: .leading, spacing: 16) {
                        Text("安装设置").font(.headline)

                        StepRow(
                            number: 1,
                            title: "添加键盘",
                            description: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选择「语音输入」",
                            isDone: keyboardSetup.status.keyboardObserved,
                            action: openKeyboardSettings
                        )

                        StepRow(
                            number: 2,
                            title: "允许完全访问",
                            description: "在键盘列表中点击「语音输入」→ 开启「允许完全访问」\n完成后在任意输入框切换到 VoType 一次，状态会自动确认",
                            isDone: keyboardSetup.status.fullAccessObserved,
                            action: openKeyboardSettings
                        )

                        StepRow(
                            number: 3,
                            title: "授权语音识别",
                            description: "点击下方按钮授权语音识别和麦克风权限",
                            isDone: speechAuthorized && micAuthorized,
                            action: requestSpeechPermission
                        )
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 用户主动开启的免切换语音。PiP 承载真实状态与实时文字，
                    // 待命阶段明确保持麦克风关闭。
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("免切换语音").font(.headline)
                                Text(pipStatusText)
                                    .font(.caption)
                                    .foregroundColor(pipStatusColor)
                            }
                            Spacer()
                            Circle()
                                .fill(pipStatusColor)
                                .frame(width: 10, height: 10)
                        }

                        PiPStandbySourceView()
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("VoType 免切换语音状态画面")

                        Text("开启后可回到微信、备忘录或浏览器，键盘上的实心麦克风可原地开始。待命时不录音；只有你点键盘麦克风后才会使用麦克风。")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            if pipStandby.isActive {
                                pipStandby.stopStandby()
                            } else {
                                pipStandby.startStandby()
                            }
                        } label: {
                            Label(
                                pipStandby.isActive ? "关闭免切换语音" : "开启免切换语音",
                                systemImage: pipStandby.isActive
                                    ? "pip.exit"
                                    : "pip.enter"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !pipStandby.canToggleStandby
                        )
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 输入设置
                    VStack(alignment: .leading, spacing: 14) {
                        Text("AI 处理设置").font(.headline)

                        ToggleRow(
                            title: "智能自我纠正",
                            description: "检测「不对,应该是X」等口语纠正,保留最终正确版本",
                            isOn: $smartCorrection
                        )

                        ToggleRow(
                            title: "LLM 文字润色",
                            description: "iOS 26+ 使用设备端大模型润色,低版本自动跳过",
                            isOn: $llmPolish
                        )

                        ToggleRow(
                            title: "自动标点",
                            description: "识别结束后自动添加。！？等标点",
                            isOn: $autoPunctuation
                        )

                        ToggleRow(
                            title: "去口水词",
                            description: "自动去除「嗯、啊、那个」等口水词",
                            isOn: $fillerWordRemoval
                        )

                        ToggleRow(
                            title: "实时预览",
                            description: "说话时实时显示识别结果",
                            isOn: $livePreview
                        )

                        Divider().padding(.vertical, 2)

                        ToggleRow(
                            title: "智能自动格式化",
                            description: "检测口语中的「第一」「首先」等,自动转为编号列表",
                            isOn: $autoFormat
                        )

                        ToggleRow(
                            title: "场景感知",
                            description: "根据输入框类型(邮件/网址/社交)自动调整输出风格",
                            isOn: $contextAware
                        )

                        ToggleRow(
                            title: "语音编辑",
                            description: "选中文字后说话,可替换/追加/删除选中内容",
                            isOn: $voiceEdit
                        )
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 翻译设置
                    VStack(alignment: .leading, spacing: 14) {
                        Text("实时翻译").font(.headline)

                        ToggleRow(
                            title: "翻译模式",
                            description: "说话后自动翻译为目标语言(iOS 26+ 设备端 LLM)",
                            isOn: $translationEnabled
                        )

                        if translationEnabled {
                            Divider().padding(.vertical, 2)

                            Text("翻译目标语言").font(.caption.bold()).foregroundColor(.secondary)

                            Picker("目标语言", selection: $translationTargetID) {
                                ForEach(LanguageManager.allLanguages, id: \.id) { lang in
                                    Text("\(lang.flag) \(lang.name)").tag(lang.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 语言偏好
                    VStack(alignment: .leading, spacing: 12) {
                        Text("语言偏好").font(.headline)
                        Text("选择您常用的语言,键盘上可快速切换。仅启用的语言会出现在切换列表中。")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        ForEach(LanguageManager.allLanguages, id: \.id) { lang in
                            HStack {
                                Text("\(lang.flag) \(lang.name)")
                                    .font(.subheadline)
                                Spacer()
                                if enabledLanguageIDs.contains(lang.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleLanguage(lang.id)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 个人词典
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("个人词典").font(.headline)
                            Spacer()
                            Button(action: { showBatchImport = true }) {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(.orange)
                                    .font(.title3)
                            }
                            Button(action: { showAddEntry = true }) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title3)
                            }
                        }

                        Button(role: .destructive) {
                            PinyinInputEngine.resetAdaptiveLearning()
                            DarwinBridge.postNotification(
                                DarwinNotificationName.pinyinLearningReset
                            )
                        } label: {
                            Label("重置拼音候选学习", systemImage: "arrow.counterclockwise")
                                .font(.caption)
                        }

                        if dictionaryEntries.isEmpty {
                            Text("暂无自定义词条。添加后,语音识别中的匹配词会自动替换为目标词。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(dictionaryEntries.indices, id: \.self) { idx in
                                let entry = dictionaryEntries[idx]
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("识别: \(entry.0)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("替换: \(entry.1)")
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        deleteEntry(entry.0)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 使用统计
                    if let stats = usageStats {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("使用统计").font(.headline)
                                Spacer()
                                Button(role: .destructive) {
                                    UsageTracker.shared.resetAll()
                                    loadUsageStats()
                                } label: {
                                    Text("重置").font(.caption2)
                                }
                            }

                            HStack(spacing: 20) {
                                StatBlock(title: "总字数", value: "\(stats.totalChars)")
                                StatBlock(title: "会话数", value: "\(stats.totalSessions)")
                                StatBlock(title: "连续天数", value: "\(stats.currentStreak)")
                            }

                            if !stats.languageDistribution.isEmpty {
                                Text("语言分布").font(.caption.bold()).foregroundColor(.secondary)
                                ForEach(stats.languageDistribution, id: \.name) { lang in
                                    HStack {
                                        Text("\(lang.flag) \(lang.name)").font(.caption)
                                        Spacer()
                                        Text("\(lang.count) 次").font(.caption.bold())
                                    }
                                }
                            }

                            if !stats.featureUsage.isEmpty {
                                Text("功能使用").font(.caption.bold()).foregroundColor(.secondary)
                                ForEach(stats.featureUsage, id: \.feature) { feature in
                                    HStack {
                                        Text(UsageTracker.featureDisplayName(feature.feature)).font(.caption)
                                        Spacer()
                                        Text("\(feature.count) 次").font(.caption.bold())
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(16)
                    }

                    // 原地录音说明
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("原地录音").font(.headline)
                            Spacer()
                            Image(systemName: "mic.badge.plus")
                                .foregroundColor(.blue)
                        }

                        Text("开启“免切换语音”后，实心麦克风会直接原地录音；空心麦克风表示当前需要短暂打开 VoType。键盘会显示实时文字，再点麦克风结束并自动回填。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("系统或你关闭画中画后，键盘会自动退回空心麦克风，不会假装仍可原地录音。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 使用说明
                    VStack(alignment: .leading, spacing: 12) {
                        Text("使用方法").font(.headline)

                        InstructionRow(text: "先在 VoType 开启一次“免切换语音”，再回到任意输入框")
                        InstructionRow(text: "实心麦克风原地录音；空心麦克风会短暂打开 VoType")
                        InstructionRow(text: "录音开始后立即返回原输入框，键盘会显示实时识别文字")
                        InstructionRow(text: "再次点麦克风结束；文字处理完成后自动插入光标位置")
                        InstructionRow(text: "左滑或点键盘图标可快速补字，右滑返回语音面板")
                        InstructionRow(text: "说错了可以说「不对,应该是...」自动纠正")
                        InstructionRow(text: "说「第一」「第二」等会自动转为编号列表")
                        InstructionRow(text: "选中文字后说话,可替换或追加内容(语音编辑)")
                        InstructionRow(text: "点击翻译按钮开启实时翻译模式")
                        InstructionRow(text: "点击耳朵按钮开启耳语模式(安静环境)")
                        InstructionRow(text: "底部符号栏可快速插入标点和表情")
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 隐私说明
                    VStack(alignment: .leading, spacing: 8) {
                        Text("隐私说明").font(.headline).foregroundColor(.green)

                        Text("• 语音识别优先使用设备端 Apple Speech；设备端识别不可用时，Apple 可能通过网络处理")
                        Text("• LLM 润色和翻译使用 Apple 设备端模型(iOS 26+),零网络传输")
                        Text("• 使用统计仅存储在本地,不上传任何信息")
                        Text("• 拼音候选选择仅用于本机排序学习,不上传输入内容")
                        Text("• 不收集任何用户信息,无账号,无追踪")
                        Text("• 语音数据仅在识别期间使用,不被存储或保留")
                        Text("• 键盘仅在您点击麦克风时才使用麦克风")
                    }
                    .padding()
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(16)
                    .font(.caption)
                }
                .padding()
            }
            .navigationTitle("VoType")
            .onAppear {
                loadSettings()
                loadDictionary()
                loadLanguages()
                loadTranslationSettings()
                loadUsageStats()
                checkStatus()
                BackgroundDictationManager.shared.autoRestoreIfNeeded()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    checkStatus()
                }
            }
            .onChange(of: autoPunctuation) { v in saveSetting("autoPunctuation", v) }
            .onChange(of: fillerWordRemoval) { v in saveSetting("fillerWordRemoval", v) }
            .onChange(of: livePreview) { v in saveSetting("livePreview", v) }
            .onChange(of: smartCorrection) { v in saveSetting("smartCorrection", v) }
            .onChange(of: llmPolish) { v in saveSetting("llmPolish", v) }
            .onChange(of: autoFormat) { v in saveSetting("autoFormat", v) }
            .onChange(of: contextAware) { v in saveSetting("contextAware", v) }
            .onChange(of: voiceEdit) { v in saveSetting("voiceEdit", v) }
            .onChange(of: translationEnabled) { v in
                TranslationManager.shared.setTranslationEnabled(v)
            }
            .onChange(of: translationTargetID) { v in
                TranslationManager.shared.targetLanguageID = v
            }
            .sheet(isPresented: $showAddEntry) {
                AddDictionaryEntrySheet(
                    newSpeech: $newSpeech,
                    newReplacement: $newReplacement,
                    onSave: addEntry
                )
            }
            .sheet(isPresented: $showBatchImport) {
                BatchImportSheet(
                    importText: $batchImportText,
                    onSave: batchImportEntries
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 设置

    private var pipStatusText: String {
        switch pipStandby.state {
        case .unavailable: return "此设备不支持画中画"
        case .ready:
            return pipStandby.isStartPossible
                ? "未开启 · 键盘将使用冷启动"
                : "系统画中画暂不可用"
        case .starting: return "正在请求系统开启画中画…"
        case .standby: return "已待命 · 麦克风关闭"
        case .recording: return "正在录音"
        case .processing: return "正在整理文字"
        case .failed(let message): return "开启失败：\(message)"
        }
    }

    private var pipStatusColor: Color {
        switch pipStandby.state {
        case .standby: return .green
        case .recording: return .red
        case .processing, .starting: return .orange
        case .failed, .unavailable: return .red
        case .ready: return .secondary
        }
    }

    private func loadSettings() {
        autoPunctuation = sharedDefaults?.object(forKey: "autoPunctuation") as? Bool ?? true
        fillerWordRemoval = sharedDefaults?.object(forKey: "fillerWordRemoval") as? Bool ?? true
        livePreview = sharedDefaults?.object(forKey: "livePreview") as? Bool ?? true
        smartCorrection = sharedDefaults?.object(forKey: "smartCorrection") as? Bool ?? true
        llmPolish = sharedDefaults?.object(forKey: "llmPolish") as? Bool ?? true
        autoFormat = sharedDefaults?.object(forKey: "autoFormat") as? Bool ?? true
        contextAware = sharedDefaults?.object(forKey: "contextAware") as? Bool ?? true
        voiceEdit = sharedDefaults?.object(forKey: "voiceEdit") as? Bool ?? true
    }

    private func saveSetting(_ key: String, _ value: Bool) {
        sharedDefaults?.set(value, forKey: key)
    }

    // MARK: - 翻译设置

    private func loadTranslationSettings() {
        translationEnabled = TranslationManager.shared.translationEnabled
        translationTargetID = TranslationManager.shared.targetLanguageID
    }

    // MARK: - 使用统计

    private func loadUsageStats() {
        usageStats = UsageTracker.shared.stats
    }

    // MARK: - 词典

    private func loadDictionary() {
        let dict = sharedDefaults?.dictionary(forKey: "personalDictionary") as? [String: String] ?? [:]
        dictionaryEntries = dict.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    // MARK: - 语言偏好

    private func loadLanguages() {
        enabledLanguageIDs = LanguageManager.shared.enabledLanguageIDs
    }

    private func toggleLanguage(_ id: String) {
        LanguageManager.shared.toggleLanguage(id)
        enabledLanguageIDs = LanguageManager.shared.enabledLanguageIDs
    }

    private func addEntry() {
        guard !newSpeech.isEmpty, !newReplacement.isEmpty else { return }
        var dict = sharedDefaults?.dictionary(forKey: "personalDictionary") as? [String: String] ?? [:]
        dict[newSpeech] = newReplacement
        sharedDefaults?.set(dict, forKey: "personalDictionary")
        newSpeech = ""
        newReplacement = ""
        loadDictionary()
        showAddEntry = false
    }

    private func deleteEntry(_ key: String) {
        var dict = sharedDefaults?.dictionary(forKey: "personalDictionary") as? [String: String] ?? [:]
        dict.removeValue(forKey: key)
        sharedDefaults?.set(dict, forKey: "personalDictionary")
        loadDictionary()
    }

    private func batchImportEntries() {
        // 解析批量导入文本: 每行一个条目,格式 "识别词,替换词" 或 "识别词:替换词"
        let lines = batchImportText.components(separatedBy: .newlines)
        var dict = sharedDefaults?.dictionary(forKey: "personalDictionary") as? [String: String] ?? [:]
        var imported = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // 尝试用逗号或冒号分割
            let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ",，:："))
            if parts.count >= 2 {
                let speech = parts[0].trimmingCharacters(in: .whitespaces)
                let replacement = parts[1].trimmingCharacters(in: .whitespaces)
                if !speech.isEmpty && !replacement.isEmpty {
                    dict[speech] = replacement
                    imported += 1
                }
            }
        }

        if imported > 0 {
            sharedDefaults?.set(dict, forKey: "personalDictionary")
            loadDictionary()
        }

        batchImportText = ""
        showBatchImport = false
    }

    // MARK: - 状态检查

    private func checkStatus() {
        keyboardSetup.refresh()

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechAuthorized = (speechStatus == .authorized)

        let micStatus = AVAudioSession.sharedInstance().recordPermission
        micAuthorized = (micStatus == .granted)
    }

    // MARK: - 操作

    private func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                speechAuthorized = (status == .authorized)
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                micAuthorized = granted
            }
        }
    }
}

// MARK: - 添加词典条目 Sheet

struct AddDictionaryEntrySheet: View {
    @Binding var newSpeech: String
    @Binding var newReplacement: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("识别到的词") {
                    TextField("如:小名", text: $newSpeech)
                }
                Section("替换为") {
                    TextField("如:小明", text: $newReplacement)
                }
                Section {
                    Button("保存", action: onSave)
                        .disabled(newSpeech.isEmpty || newReplacement.isEmpty)
                }
            }
            .navigationTitle("添加词典")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 子视图

struct StepRow: View {
    let number: Int
    let title: String
    let description: String
    let isDone: Bool
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green : Color.blue)
                    .frame(width: 28, height: 28)
                if isDone {
                    Image(systemName: "checkmark")
                        .foregroundColor(.white)
                        .font(.caption.bold())
                } else {
                    Text("\(number)")
                        .foregroundColor(.white)
                        .font(.caption.bold())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("setup-step-\(number)-status")
            .accessibilityLabel(title)
            .accessibilityValue(isDone ? "已完成" : "未完成")

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let action = action, !isDone {
                    Button("前往设置 →", action: action)
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                        .padding(.top, 4)
                }
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(description).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct InstructionRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.blue)
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - 批量导入 Sheet

struct BatchImportSheet: View {
    @Binding var importText: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("批量导入词典") {
                    Text("每行一个条目,格式: 识别词,替换词\n例如:\n小名,小明\n老王,王经理")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("粘贴内容") {
                    TextEditor(text: $importText)
                        .frame(minHeight: 200)
                }

                Section {
                    Button("从剪贴板粘贴") {
                        if let clipboard = UIPasteboard.general.string {
                            importText = clipboard
                        }
                    }
                    .foregroundColor(.blue)

                    Button("导入", action: onSave)
                        .disabled(importText.isEmpty)
                }
            }
            .navigationTitle("批量导入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 统计卡片

struct StatBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(.blue)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray5))
        .cornerRadius(12)
    }
}
