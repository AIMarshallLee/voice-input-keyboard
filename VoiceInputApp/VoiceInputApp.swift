import SwiftUI
import Combine

/// 听写协调器
///
/// Path A (Darwin 通知): 由 BackgroundDictationManager 在后台处理,不显示 UI
/// Path B (URL Scheme): 显示 DictationView 全屏页面 (仅首次使用或 App 被杀后)
final class DictationCoordinator: ObservableObject {
    @Published var showDictation = false
    @Published var dictationURL: URL?

    private var stopObserver: DarwinNotificationObserver?

    init() {
        // 监听键盘的 requestStopDictation
        stopObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.requestStopDictation
        ) { [weak self] in
            guard let self = self else { return }
            print("[App] requestStopDictation received")
            // 如果 DictationView 在显示,关闭它
            DispatchQueue.main.async {
                self.showDictation = false
            }
        }
    }
}

@main
struct VoiceInputApp: App {
    @StateObject private var coordinator = DictationCoordinator()
    @StateObject private var bgDictation = BackgroundDictationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $coordinator.showDictation) {
                    DictationView(url: coordinator.dictationURL)
                }
                .onOpenURL { url in
                    // ★ Build 33: 永远显示 DictationView！
                    // 之前: isPipStandbyEnabled=true 时重定向到 BackgroundDictationManager
                    //       后台 SFSpeechRecognizer 必定失败 (Apple 不支持后台语音识别)
                    // 现在: 永远走前台 DictationView，前台识别可靠
                    if url.scheme == DictationConstants.urlScheme {
                        print("[App] URL Scheme received → showing DictationView (foreground recognition)")
                        coordinator.dictationURL = url
                        coordinator.showDictation = true
                    }
                }
        }
    }
}
