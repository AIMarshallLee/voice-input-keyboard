import SwiftUI
import Speech
import AVFoundation

/// 主 App 界面:引导用户安装键盘、授权权限、查看使用说明
struct ContentView: View {

    @State private var speechAuthorized = false
    @State private var micAuthorized = false
    @State private var keyboardAdded = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // 标题区
                    VStack(spacing: 8) {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 72))
                            .foregroundColor(.blue)

                        Text("语音输入键盘")
                            .font(.title2.bold())

                        Text("一键语音转文字,专为远程控制场景优化")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    // 安装步骤
                    VStack(alignment: .leading, spacing: 16) {

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
                            description: "点击下方按钮授权语音识别权限",
                            isDone: speechAuthorized,
                            action: requestSpeechPermission
                        )
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 使用说明
                    VStack(alignment: .leading, spacing: 12) {
                        Text("使用方法")
                            .font(.headline)

                        InstructionRow(text: "在 UU远程(或其他任何 App)中点击输入框")
                        InstructionRow(text: "键盘弹出后,切换到「语音输入」键盘")
                        InstructionRow(text: "点击中间的大麦克风按钮")
                        InstructionRow(text: "开始说话,文字会实时显示")
                        InstructionRow(text: "说完后再次点击按钮,文字自动插入")
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(16)

                    // 注意事项
                    VStack(alignment: .leading, spacing: 8) {
                        Text("注意事项")
                            .font(.headline)
                            .foregroundColor(.orange)

                        Text("• 首次使用时,iOS 会弹窗请求麦克风和语音识别权限")
                        Text("• 中文识别优先使用设备端模型,无需网络也可工作")
                        Text("• 如识别不准确,可在系统设置中关闭再重新打开键盘")
                        Text("• 本键盘不收集任何数据,所有识别在设备本地完成")
                    }
                    .padding()
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(16)
                    .font(.caption)
                }
                .padding()
            }
            .navigationTitle("语音输入键盘")
            .onAppear {
                checkStatus()
            }
        }
    }

    // MARK: - 检查状态

    private func checkStatus() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechAuthorized = (speechStatus == .authorized)

        let micStatus = AVAudioSession.sharedInstance().recordPermission
        micAuthorized = (micStatus == .granted)

        // 检查键盘是否已安装
        // (iOS 不提供直接检查方式,这里始终显示未完成,用户手动确认)
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

        // 同时请求麦克风权限
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                micAuthorized = granted
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
