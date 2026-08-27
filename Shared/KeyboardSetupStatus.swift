import Foundation

struct KeyboardSetupStatus: Equatable {
    let keyboardObserved: Bool
    let fullAccessObserved: Bool
}

enum KeyboardSetupStatusStore {
    private static let keyboardObservedKey = "keyboardSetup.keyboardObserved"
    private static let fullAccessObservedKey = "keyboardSetup.fullAccessObserved"

    static func recordExtensionAppearance(
        hasFullAccess: Bool,
        defaults: UserDefaults = SharedDefaults.shared
    ) {
        defaults.set(true, forKey: keyboardObservedKey)
        defaults.set(hasFullAccess, forKey: fullAccessObservedKey)
    }

    static func read(
        defaults: UserDefaults = SharedDefaults.shared
    ) -> KeyboardSetupStatus {
        KeyboardSetupStatus(
            keyboardObserved: defaults.bool(forKey: keyboardObservedKey),
            fullAccessObserved: defaults.bool(forKey: fullAccessObservedKey)
        )
    }
}
