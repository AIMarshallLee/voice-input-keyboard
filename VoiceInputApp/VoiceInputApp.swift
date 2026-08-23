import SwiftUI
import Combine

/// 宿主 App 的前台听写页面协调器。
final class DictationCoordinator: ObservableObject {
    @Published var showDictation = false
    @Published var dictationURL: URL?
}

@main
struct VoiceInputApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = DictationCoordinator()
    @StateObject private var bgDictation = BackgroundDictationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $coordinator.showDictation) {
                    DictationView(url: coordinator.dictationURL)
                }
                .onAppear {
                    presentPendingDictationIfNeeded()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        presentPendingDictationIfNeeded()
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == DictationConstants.urlScheme,
                          url.host == DictationConstants.dictationPath,
                          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let session = components.queryItems?.first(where: {
                              $0.name == DictationConstants.paramSession
                          })?.value,
                          UUID(uuidString: session) != nil else {
                        print("[App] Ignoring malformed or unsupported URL")
                        return
                    }

                    print("[App] Valid dictation URL received → showing foreground recorder")
                    coordinator.dictationURL = url
                    coordinator.showDictation = true
                }
        }
    }

    /// 键盘扩展无法可靠启动宿主 App。用户手动打开 VoType 时，
    /// 继续处理一分钟内尚未消费的 App Group 听写请求。
    private func presentPendingDictationIfNeeded() {
        guard !coordinator.showDictation,
              DarwinBridge.peekPendingDictationSettings() != nil else { return }
        coordinator.dictationURL = nil
        coordinator.showDictation = true
    }
}
