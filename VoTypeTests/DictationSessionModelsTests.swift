import XCTest
@testable import VoiceInputApp

final class DictationSessionModelsTests: XCTestCase {
    func testGeneratedAndDecodedTokensRequireUUIDs() throws {
        let generated = SessionToken()
        XCTAssertNotNil(UUID(uuidString: generated.rawValue))
        XCTAssertNil(SessionToken(rawValue: "not-a-uuid"))

        let data = try JSONEncoder().encode(generated)
        XCTAssertEqual(try JSONDecoder().decode(SessionToken.self, from: data), generated)
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionToken.self, from: Data(#""not-a-uuid""#.utf8))
        )
    }

    func testNewCompletedPayloadRoundTripsEditPlanWithoutLegacyFlag() throws {
        let token = SessionToken()
        let plan = EditPlan(
            intent: .dictate,
            operation: .insertAtCursor,
            text: "你好",
            expectedContextFingerprint: "context-digest",
            requiresConfirmation: false
        )
        let result = DictationIPCResult(
            status: .completed,
            text: plan.text,
            token: token,
            editPlan: plan,
            timestamp: 100
        )

        let data = try JSONEncoder().encode(result)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("editPlan"))
        XCTAssertFalse(json.contains("deleteSelected"))
        XCTAssertEqual(try JSONDecoder().decode(DictationIPCResult.self, from: data), result)
    }

    func testLegacyInsertPayloadDecodesAsInsertAtCursor() throws {
        let session = UUID().uuidString
        let json = """
        {"status":"completed","text":"旧结果","session":"\(session)","deleteSelected":false,"timestamp":100}
        """
        let decoded = try JSONDecoder().decode(
            DictationIPCResult.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.editPlan?.operation, .insertAtCursor)
        XCTAssertEqual(decoded.editPlan?.requiresConfirmation, false)
    }

    func testLegacyDestructivePayloadDecodesAsPreviewOnly() throws {
        let session = UUID().uuidString
        let json = """
        {"status":"completed","text":"替换结果","session":"\(session)","deleteSelected":true,"timestamp":100}
        """
        let decoded = try JSONDecoder().decode(
            DictationIPCResult.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.editPlan?.operation, .previewOnly)
        XCTAssertEqual(decoded.editPlan?.requiresConfirmation, true)
        XCTAssertFalse(decoded.deleteSelected)
    }

    func testResultPayloadRejectsNonUUIDSession() {
        let json = """
        {"status":"completed","text":"结果","session":"not-a-uuid","deleteSelected":false,"timestamp":100}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(DictationIPCResult.self, from: Data(json.utf8))
        )
    }
}
