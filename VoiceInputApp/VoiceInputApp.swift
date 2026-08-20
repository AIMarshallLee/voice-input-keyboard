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
                    // Path B: URL Scheme 降级路径 (仅当 BackgroundDictationManager 未启用时)
                    if url.scheme == DictationConstants.urlScheme {
                        if bgDictation.isPipStandbyEnabled {
                            // PiP保活已开启,不应该走 URL Scheme
                            // 但如果 Darwin 通知没送达,键盘会降级到 URL
                            // 这种情况下让 BackgroundDictationManager 处理
                            print("[App] URL Scheme received but standby enabled - redirecting to BG manager")
                            if let settings = DarwinBridge.readDictationSettings() {
                                // 通知 BG manager 处理
                                DarwinBridge.postNotification(DarwinNotificationName.requestStartDictation)
                            }
                        } else {
                            // PiP保活未开启,走传统 DictationView
                            coordinator.dictationURL = url
                            coordinator.showDictation = true
                        }
                    }
                }
        }
    }
}
