import UIKit
import XCTest
@testable import VoiceInputApp

final class KeyboardResultDispositionPolicyTests: XCTestCase {
    func testOnlyCurrentHotNondestructiveSessionWithoutSelectionCanAutoInsert() {
        for selection in [nil, ""] as [String?] {
            XCTAssertEqual(KeyboardResultDispositionPolicy.decide(
                launchMode: .inPlace, belongsToCurrentExtensionInstance: true,
                currentSelectedText: selection, hasContextEvidence: true, contextMatches: true,
                operation: .insertAtCursor, requiresConfirmation: false), .autoInsert)
        }
        let held: [(KeyboardSessionLaunchMode, Bool, String?, Bool, Bool, EditOperation, Bool)] = [
            (.manualOpen, true, nil, true, true, .insertAtCursor, false),
            (.inPlace, false, nil, true, true, .insertAtCursor, false),
            (.inPlace, true, nil, false, true, .insertAtCursor, false),
            (.inPlace, true, nil, true, false, .insertAtCursor, false),
            (.inPlace, true, "original selection", true, true, .insertAtCursor, false),
            (.inPlace, true, nil, true, true, .replaceSelection, false),
            (.inPlace, true, nil, true, true, .deleteSelection, false),
            (.inPlace, true, nil, true, true, .previewOnly, false),
            (.inPlace, true, nil, true, true, .insertAtCursor, true)
        ]
        for value in held {
            XCTAssertEqual(KeyboardResultDispositionPolicy.decide(
                launchMode: value.0, belongsToCurrentExtensionInstance: value.1,
                currentSelectedText: value.2, hasContextEvidence: value.3, contextMatches: value.4,
                operation: value.5, requiresConfirmation: value.6), .hold)
        }
    }

    func testExplicitInsertionAndLegacyPreviewRejectLiveSelectionAndEmptyOutput() {
        let token = SessionToken()
        for operation in [EditOperation.insertAtCursor, .previewOnly] {
            for selection in [nil, "", "original selection"] as [String?] {
                let plan = EditPlan(intent: .rewrite, operation: operation, text: "result",
                                    expectedContextFingerprint: nil, requiresConfirmation: true)
                XCTAssertEqual(KeyboardHeldEditValidator.decide(
                    plan: plan, previewedToken: token, heldToken: token,
                    snapshotToken: nil, snapshotFingerprint: nil, hasContextEvidence: false,
                    contextMatches: false, currentSelectedText: selection),
                    selection == "original selection" ? .reject : .insertAtCursor("result"))
            }
            let empty = EditPlan(intent: .dictate, operation: operation, text: "",
                                 expectedContextFingerprint: nil, requiresConfirmation: false)
            XCTAssertEqual(KeyboardHeldEditValidator.decide(
                plan: empty, previewedToken: token, heldToken: token,
                snapshotToken: nil, snapshotFingerprint: nil, hasContextEvidence: false,
                contextMatches: false, currentSelectedText: nil), .reject)
        }
    }

    func testReplaceAndDeleteRequireConfirmationAndMatchingSelectionEvidence() {
        let token = SessionToken()
        for operation in [EditOperation.replaceSelection, .deleteSelection] {
            let text = operation == .deleteSelection ? "" : "replacement"
            let plan = EditPlan(intent: .rewrite, operation: operation, text: text,
                                expectedContextFingerprint: "fingerprint", requiresConfirmation: true)
            XCTAssertEqual(KeyboardHeldEditValidator.decide(
                plan: plan, previewedToken: token, heldToken: token,
                snapshotToken: token, snapshotFingerprint: "fingerprint", hasContextEvidence: true,
                contextMatches: true, currentSelectedText: "original"),
                operation == .deleteSelection ? .deleteSelection : .replaceSelection("replacement"))
            let rejected: [(SessionToken, SessionToken?, String?, Bool, Bool, String?)] = [
                (SessionToken(), token, "fingerprint", true, true, "original"),
                (token, SessionToken(), "fingerprint", true, true, "original"),
                (token, nil, "fingerprint", true, true, "original"),
                (token, token, "changed", true, true, "original"),
                (token, token, nil, true, true, "original"),
                (token, token, "fingerprint", false, true, "original"),
                (token, token, "fingerprint", true, false, "original"),
                (token, token, "fingerprint", true, true, nil),
                (token, token, "fingerprint", true, true, "")
            ]
            for value in rejected {
                XCTAssertEqual(KeyboardHeldEditValidator.decide(
                    plan: plan, previewedToken: token, heldToken: value.0,
                    snapshotToken: value.1, snapshotFingerprint: value.2,
                    hasContextEvidence: value.3, contextMatches: value.4,
                    currentSelectedText: value.5), .reject)
            }
            for invalidPlan in [
                EditPlan(intent: .rewrite, operation: operation, text: text,
                         expectedContextFingerprint: "fingerprint", requiresConfirmation: false),
                EditPlan(intent: .rewrite, operation: operation, text: text,
                         expectedContextFingerprint: nil, requiresConfirmation: true)
            ] {
                XCTAssertEqual(KeyboardHeldEditValidator.decide(
                    plan: invalidPlan, previewedToken: token, heldToken: token,
                    snapshotToken: token, snapshotFingerprint: "fingerprint", hasContextEvidence: true,
                    contextMatches: true, currentSelectedText: "original"), .reject)
            }
        }
    }

    func testEmptyReplacementAndWrongHeldTokenCannotApply() {
        let token = SessionToken()
        let empty = EditPlan(intent: .rewrite, operation: .replaceSelection, text: "",
                             expectedContextFingerprint: "fingerprint", requiresConfirmation: true)
        XCTAssertEqual(KeyboardHeldEditValidator.decide(
            plan: empty, previewedToken: token, heldToken: token,
            snapshotToken: token, snapshotFingerprint: "fingerprint", hasContextEvidence: true,
            contextMatches: true, currentSelectedText: "original"), .reject)
        let insert = EditPlan(intent: .dictate, operation: .insertAtCursor, text: "result",
                              expectedContextFingerprint: nil, requiresConfirmation: false)
        XCTAssertEqual(KeyboardHeldEditValidator.decide(
            plan: insert, previewedToken: token, heldToken: SessionToken(),
            snapshotToken: nil, snapshotFingerprint: nil, hasContextEvidence: false,
            contextMatches: false, currentSelectedText: nil), .reject)
    }

    func testConsumedPayloadMustMatchEveryPreviewedField() {
        let token = SessionToken()
        let plan = EditPlan(intent: .dictate, operation: .insertAtCursor, text: "result",
                            expectedContextFingerprint: "fingerprint", requiresConfirmation: false)
        let preview = DictationIPCResult(status: .completed, text: "result", token: token,
                                        editPlan: plan, timestamp: 100)
        XCTAssertTrue(KeyboardHeldEditValidator.consumedResultMatchesPreview(previewed: preview, consumed: preview))
        let changedPlan = EditPlan(intent: .dictate, operation: .insertAtCursor, text: "changed",
                                   expectedContextFingerprint: "fingerprint", requiresConfirmation: false)
        let changed = [
            DictationIPCResult(status: .error, text: "result", token: token, editPlan: plan, timestamp: 100),
            DictationIPCResult(status: .completed, text: "changed", token: token, editPlan: plan, timestamp: 100),
            DictationIPCResult(status: .completed, text: "result", token: SessionToken(), editPlan: plan, timestamp: 100),
            DictationIPCResult(status: .completed, text: "result", token: token, editPlan: changedPlan, timestamp: 100),
            DictationIPCResult(status: .completed, text: "result", token: token, editPlan: nil, timestamp: 100),
            DictationIPCResult(status: .completed, text: "result", token: token, editPlan: plan, timestamp: 101)
        ]
        for result in changed {
            XCTAssertFalse(KeyboardHeldEditValidator.consumedResultMatchesPreview(previewed: preview, consumed: result))
        }
    }

    @MainActor
    func testUIKitInsertTextReplacesNonemptySelection() {
        let textView = UITextView(frame: .zero)
        textView.text = "before ORIGINAL after"
        textView.selectedRange = NSRange(location: 7, length: 8)

        // UIKit insertion replaces the eight selected ASCII characters.
        // This characterizes the platform hazard; it is not a device keyboard test.
        textView.insertText("NEW")

        XCTAssertEqual(textView.text, "before NEW after")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 10, length: 0))
    }
}
