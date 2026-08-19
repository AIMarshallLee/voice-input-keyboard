import SwiftUI

@main
struct VoiceInputApp: App {
    @State private var showDictation = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $showDictation) {
                    DictationView()
                }
                .onOpenURL { url in
                    if url.scheme == DictationConstants.urlScheme {
                        showDictation = true
                    }
                }
        }
    }
}
