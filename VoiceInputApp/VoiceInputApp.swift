import SwiftUI

@main
struct VoiceInputApp: App {
    @State private var showDictation = false
    @State private var dictationURL: URL?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $showDictation) {
                    DictationView(url: dictationURL)
                }
                .onOpenURL { url in
                    if url.scheme == DictationConstants.urlScheme {
                        dictationURL = url
                        showDictation = true
                    }
                }
        }
    }
}
