import SwiftUI
import Speech
import AVFoundation

/// 主 App:引导安装 + 设置 + 词典管理 + 隐私说明
struct ContentView: View {

    @State private var speechAuthorized = false
    @State private var micAuthorized = false
    @State private var keyboardAdded = false

    @State private var autoPunctuation = true
    @State private var fillerWordRemoval = true
    @State private var livePreview = true
    @State private var smartCorrection = true
    @State private var llmPolish = true
    @State private var enabledLanguageIDs: [String] = []

    // 词典管理
    @State private var dictionaryEntries: [(String, String)] = []
    @State private var showAddEntry = false
    @State private var newSpeech = ""
    @State private var newReplacement = ""

    private let sharedDefaults = UserDefaults(suiteName: "group.com.voiceinput.shared")

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // 标题
                    VStack(spacing: 8) {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.blue)
                        Text("语音输入键盘")
                            .font(.title2.bold())
                        Text("离线语音转文字 · 中英混输 · AI润色 · 自我纠正 · 去口水词")
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
                            isDone: keyboardAdded,
                            action: openKeyboardSettings
                        )

                        StepRow(
                            number: 2,
                            title: "允许完全访问",
                            description: "在键盘列表中点击「语音输入」→ 开启「允许完全访问」\n这是使用麦克风的必要条件",
                            isDone: micAuthorized
                        )

                        StepRow(
                            number: 3,
                            title: "授权语音识别",
                            description: "点击下方按钮授权语音识别和麦克风权限",
                            isDone: speechAuthorized,
                            action: requestSpeechPermission
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
                            Button(action: { showAddEntry = true }) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title3)
                            }
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

                    // 使用说明
                    VStack(alignment: .leading, spacing: 12) {
                        Text("使用方法").font(.headline)

                        InstructionRow(text: "在 UU远程(或其他任何 App)中点击输入框")
                        InstructionRow(text: "键盘弹出后,切换到「语音输入」键盘")
                        InstructionRow(text: "点击中间的大麦克风按钮")
                        InstructionRow(text: "开始说话,文字会实时显示")
                        InstructionRow(text: "说完后再次点击按钮,AI 自动处理后插入")
                        InstructionRow(text: "说错了可以说「不对,应该是...」自动纠正")
                        InstructionRow(text: "底部符号栏可快速插入标点和表情")
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 隐私说明
                    VStack(alignment: .leading, spacing: 8) {
                        Text("隐私说明").font(.headline).foregroundColor(.green)

                        Text("• 所有语音识别在设备本地完成,不上传任何数据")
                        Text("• LLM 润色使用 Apple 设备端模型,零网络传输")
                        Text("• 不收集任何用户信息")
                        Text("• 无网络连接也可正常工作(除 LLM 润色需 iOS 26+)")
                        Text("• 键盘仅在您点击麦克风时才使用麦克风")
                    }
                    .padding()
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(16)
                    .font(.caption)
                }
                .padding()
            }
            .navigationTitle("语音输入键盘")
            .onAppear {
                loadSettings()
                loadDictionary()
                loadLanguages()
                checkStatus()
            }
            .onChange(of: autoPunctuation) { v in saveSetting("autoPunctuation", v) }
            .onChange(of: fillerWordRemoval) { v in saveSetting("fillerWordRemoval", v) }
            .onChange(of: livePreview) { v in saveSetting("livePreview", v) }
            .onChange(of: smartCorrection) { v in saveSetting("smartCorrection", v) }
            .onChange(of: llmPolish) { v in saveSetting("llmPolish", v) }
            .sheet(isPresented: $showAddEntry) {
                AddDictionaryEntrySheet(
                    newSpeech: $newSpeech,
                    newReplacement: $newReplacement,
                    onSave: addEntry
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 设置

    private func loadSettings() {
        autoPunctuation = sharedDefaults?.object(forKey: "autoPunctuation") as? Bool ?? true
        fillerWordRemoval = sharedDefaults?.object(forKey: "fillerWordRemoval") as? Bool ?? true
        livePreview = sharedDefaults?.object(forKey: "livePreview") as? Bool ?? true
        smartCorrection = sharedDefaults?.object(forKey: "smartCorrection") as? Bool ?? true
        llmPolish = sharedDefaults?.object(forKey: "llmPolish") as? Bool ?? true
    }

    private func saveSetting(_ key: String, _ value: Bool) {
        sharedDefaults?.set(value, forKey: key)
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

    // MARK: - 状态检查

    private func checkStatus() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechAuthorized = (speechStatus == .authorized)

        let micStatus = AVAudioSession.sharedInstance().recordPermission
        micAuthorized = (micStatus == .granted)
    }

    // MARK: - 操作

    private func openKeyboardSettings() {
        if let url = URL(string: "App-prefs:Keyboard") {
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
