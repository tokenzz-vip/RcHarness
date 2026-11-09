import XCTest
@testable import RcHarness

@MainActor
final class HarnessActivationTests: XCTestCase {
    func testRejectedBackgroundActivationUsesAccessibilityAndSucceeds() {
        var calls: [String] = []
        let result = HarnessApplicationActivation.perform(isAvailable: {
            calls.append("validate")
            return true
        }, requestActivation: {
            calls.append("native rejected")
            return false
        }, makeFrontmost: {
            calls.append("accessibility focus")
            return true
        }, requestReopen: {
            calls.append("reopen")
            return true
        })
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(calls, ["validate", "native rejected", "validate", "accessibility focus", "validate", "reopen"])
    }

    func testSuccessfulNativeActivationStillReopensClosedWindows() {
        var reopened = false
        let result = HarnessApplicationActivation.perform(isAvailable: { true }, requestActivation: { true }, makeFrontmost: {
            XCTFail("Native activation already succeeded")
            return false
        }, requestReopen: {
            reopened = true
            return true
        })
        XCTAssertTrue(reopened)
        XCTAssertEqual(result, .activated)
    }

    func testUnavailableApplicationIsNeverActivatedOrLaunched() {
        let result = HarnessApplicationActivation.perform(isAvailable: { false }, requestActivation: {
            XCTFail("Unavailable app must not be activated")
            return true
        }, makeFrontmost: {
            XCTFail("Unavailable app must not be focused")
            return true
        }, requestReopen: {
            XCTFail("Unavailable app must not be reopened")
            return true
        })
        XCTAssertEqual(result, .unavailable)
    }

    func testAppThatExitsOrIsDisabledDuringNativeActivationIsNotFocused() {
        var available = true
        let result = HarnessApplicationActivation.perform(isAvailable: { available }, requestActivation: {
            available = false
            return false
        }, makeFrontmost: {
            XCTFail("The original process snapshot is no longer valid")
            return true
        }, requestReopen: {
            XCTFail("Exited or disabled app must not be reopened")
            return true
        })
        XCTAssertEqual(result, .unavailable)
    }

    func testAppThatExitsOrIsDisabledAfterSuccessfulActivationIsNotReopened() {
        var available = true
        let result = HarnessApplicationActivation.perform(isAvailable: { available }, requestActivation: {
            available = false
            return true
        }, makeFrontmost: { false }, requestReopen: {
            XCTFail("Exited or disabled app must not be reopened")
            return true
        })
        XCTAssertEqual(result, .unavailable)
    }

    func testRejectedReopenIsNotReportedAsSuccess() {
        let result = HarnessApplicationActivation.perform(isAvailable: { true }, requestActivation: { true },
                                                         makeFrontmost: { false }, requestReopen: { false })
        XCTAssertEqual(result, .failed)
    }

    func testBothActivationPathsFailWithoutReportingSuccess() {
        let result = HarnessApplicationActivation.perform(isAvailable: { true }, requestActivation: { false }, makeFrontmost: { false }, requestReopen: {
            XCTFail("Failed activation must not report a successful reopen")
            return true
        })
        XCTAssertEqual(result, .failed)
    }
}
