import UIKit
import XCTest

final class KeyboardResultDispositionPolicyTests: XCTestCase {
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
