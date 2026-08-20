import SwiftUI
import Combine

/// 听写协调器:管理 Darwin 通知监听和听写视图的显示
/// Path A (Darwin 通知) 的入口:键盘发 requestStartDictation → 这里收到 → 显示 DictationView
final class DictationCoordinator: ObservableObject {
    @Published var showDictation = false
    @Published var dictationURL: URL?

    private var startObserver: DarwinNotificationObserver?
    private var stopObserver: DarwinNotificationObserver?

    init() {
        // 监听键盘的 requestStartDictation (Path A)
        startObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.requestStartDictation
        ) { [weak self] in
            guard let self = self else { return }
            print("[App] Path A: requestStartDictation received")
            // URL 为 nil,DictationView 会从 DarwinBridge.readDictationSettings() 读设置
            self.dictationURL = nil
            self.showDictation = true
        }

        // 监听键盘的 requestStopDictation
        stopObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.requestStopDictation
        ) { [weak self] in
            guard let self = self else { return }
            print("[App] requestStopDictation received")
            self.showDictation = false
        }
    }
}

@main
struct VoiceInputApp: App {
    @StateObject private var coordinator = DictationCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $coordinator.showDictation) {
                    DictationView(url: coordinator.dictationURL)
                }
                .onOpenURL { url in
                    // Path B: URL Scheme 降级路径
                    if url.scheme == DictationConstants.urlScheme {
                        coordinator.dictationURL = url
                        coordinator.showDictation = true
                    }
                }
        }
    }
}
