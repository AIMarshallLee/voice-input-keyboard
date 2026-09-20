import XCTest
@testable import VoiceInputApp

final class DictationLaunchPolicyTests: XCTestCase {
    func testFreshStandbyStartsInPlace() {
        XCTAssertEqual(
            DictationLaunchPolicy.initialAction(canStartInPlace: true),
            .requestInPlace
        )
    }

    func testColdStateShowsManualRecoveryImmediately() {
        XCTAssertEqual(
            DictationLaunchPolicy.initialAction(canStartInPlace: false),
            .showManualRecovery
        )
    }

    func testHotPathShowsManualRecoveryAtOnePointTwoSeconds() {
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
            .showManualRecovery
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
