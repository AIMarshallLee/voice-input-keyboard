import Foundation

enum KeyboardResultDisposition: Equatable {
    case autoInsert
    case hold
}

enum KeyboardResultDispositionPolicy {
    static func decide(
        launchMode: KeyboardSessionLaunchMode,
        belongsToCurrentExtensionInstance: Bool,
        currentSelectedText: String?,
        hasContextEvidence: Bool,
        contextMatches: Bool,
        operation: EditOperation,
        requiresConfirmation: Bool
    ) -> KeyboardResultDisposition {
        guard launchMode == .inPlace,
              belongsToCurrentExtensionInstance,
              currentSelectedText?.isEmpty != false,
              hasContextEvidence, contextMatches,
              operation == .insertAtCursor, !requiresConfirmation else { return .hold }
        return .autoInsert
    }
}

enum HeldEditApplication: Equatable {
    case insertAtCursor(String)
    case replaceSelection(String)
    case deleteSelection
    case reject
}

enum KeyboardHeldEditValidator {
    static func decide(
        plan: EditPlan,
        previewedToken: SessionToken,
        heldToken: SessionToken,
        snapshotToken: SessionToken?,
        snapshotFingerprint: String?,
        hasContextEvidence: Bool,
        contextMatches: Bool,
        currentSelectedText: String?
    ) -> HeldEditApplication {
        guard previewedToken == heldToken else { return .reject }
        switch plan.operation {
        case .insertAtCursor, .previewOnly:
            guard currentSelectedText?.isEmpty != false, !plan.text.isEmpty else { return .reject }
            return .insertAtCursor(plan.text)
        case .replaceSelection, .deleteSelection:
            guard plan.requiresConfirmation,
                  snapshotToken == previewedToken,
                  hasContextEvidence, contextMatches,
                  let expected = plan.expectedContextFingerprint,
                  expected == snapshotFingerprint,
                  let currentSelectedText, !currentSelectedText.isEmpty else { return .reject }
            if plan.operation == .deleteSelection { return .deleteSelection }
            return plan.text.isEmpty ? .reject : .replaceSelection(plan.text)
        }
    }

    static func consumedResultMatchesPreview(previewed: DictationIPCResult, consumed: DictationIPCResult) -> Bool {
        previewed == consumed
    }
}
