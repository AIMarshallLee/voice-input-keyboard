import XCTest
@testable import VoiceInputApp

final class DictationLaunchPolicyTests: XCTestCase {
    func testFreshStandbyStartsInPlace() {
        XCTAssertEqual(
            DictationLaunchPolicy.initialAction(canStartInPlace: true),
            .requestInPlace
        )
    }

    func testColdStateOpensContainingAppImmediately() {
        XCTAssertEqual(
            DictationLaunchPolicy.initialAction(canStartInPlace: false),
            .openContainingApp
        )
    }

    func testHotPathFallsBackToColdLaunchAtDeadline() {
        XCTAssertEqual(
            DictationLaunchPolicy.actionAfterNoResponse(
                elapsed: DictationLaunchPolicy.inPlaceResponseDeadline - 0.01,
                initialAction: .requestInPlace
            ),
            .wait
        )
        XCTAssertEqual(
            DictationLaunchPolicy.actionAfterNoResponse(
                elapsed: DictationLaunchPolicy.inPlaceResponseDeadline,
                initialAction: .requestInPlace
            ),
            .openContainingApp
        )
    }

    func testEveryUnresponsiveRouteEndsWithManualRecovery() {
        for initial in [
            DictationLaunchAction.requestInPlace,
            DictationLaunchAction.openContainingApp
        ] {
            XCTAssertEqual(
                DictationLaunchPolicy.actionAfterNoResponse(
                    elapsed: DictationLaunchPolicy.manualRecoveryDeadline,
                    initialAction: initial
                ),
                .showManualRecovery
            )
        }
    }
}
