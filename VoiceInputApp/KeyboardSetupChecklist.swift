import Combine
import Foundation

@MainActor
final class KeyboardSetupChecklist: ObservableObject {
    @Published private(set) var status: KeyboardSetupStatus

    private let defaults: UserDefaults

    init(defaults: UserDefaults = SharedDefaults.shared) {
        self.defaults = defaults
        status = KeyboardSetupStatusStore.read(defaults: defaults)
    }

    func refresh() {
        status = KeyboardSetupStatusStore.read(defaults: defaults)
    }
}
