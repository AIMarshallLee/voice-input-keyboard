import Foundation

struct KeyboardSetupStatus: Equatable {
    let keyboardObserved: Bool
    let fullAccessObserved: Bool
}

enum KeyboardSetupStatusStore {
    static func recordExtensionAppearance(
        hasFullAccess: Bool,
        defaults: UserDefaults = SharedDefaults.shared
    ) {
        // Implemented after the regression tests prove the missing behavior.
    }

    static func read(
        defaults: UserDefaults = SharedDefaults.shared
    ) -> KeyboardSetupStatus {
        KeyboardSetupStatus(
            keyboardObserved: false,
            fullAccessObserved: false
        )
    }
}
