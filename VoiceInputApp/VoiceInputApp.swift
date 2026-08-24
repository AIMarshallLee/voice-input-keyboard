import SwiftUI
import Combine

/// 宿主 App 的前台听写页面协调器。
struct DictationPresentation: Identifiable, Equatable {
    let id: String
    let url: URL?
}

@MainActor
final class DictationCoordinator: ObservableObject {
    @Published var presentation: DictationPresentation?
    private var queuedPresentations: [DictationPresentation] = []
    private var transitioningPresentation: DictationPresentation?

    func enqueue(session: String, url: URL?) {
        guard DictationConstants.isValidSession(session),
              presentation?.id != session,
              transitioningPresentation?.id != session,
              !queuedPresentations.contains(where: { $0.id == session }) else { return }
        let request = DictationPresentation(id: session, url: url)
        if presentation == nil, transitioningPresentation == nil {
            presentation = request
        } else {
            queuedPresentations.append(request)
        }
    }

    func didDismiss() {
        guard transitioningPresentation == nil,
              !queuedPresentations.isEmpty else { return }
        transitioningPresentation = queuedPresentations.removeFirst()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let nextPresentation = self.transitioningPresentation else { return }
            self.transitioningPresentation = nil
            if self.presentation == nil {
                self.presentation = nextPresentation
            } else {
                self.queuedPresentations.insert(nextPresentation, at: 0)
            }
        }
    }
}

@main
struct VoiceInputApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = DictationCoordinator()
    @StateObject private var bgDictation = BackgroundDictationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(
                    item: $coordinator.presentation,
                    onDismiss: coordinator.didDismiss
                ) { request in
                    DictationView(
                        expectedSession: request.id,
                        url: request.url
                    )
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
                    coordinator.enqueue(session: session, url: url)
                }
        }
    }

    /// 键盘扩展无法可靠启动宿主 App。用户手动打开 VoType 时，
    /// 继续处理一分钟内尚未消费的 App Group 听写请求。
    private func presentPendingDictationIfNeeded() {
        guard let pending = DarwinBridge.peekPendingDictationSettings() else { return }
        coordinator.enqueue(session: pending.session, url: nil)
    }
}
