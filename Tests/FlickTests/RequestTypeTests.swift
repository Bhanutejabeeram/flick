import XCTest
@testable import InboxCore

final class RequestTypeTests: XCTestCase {
    /// The regression this guards: `finished` is not actionable, and the
    /// notifier used to gate its chime on `isActionable`, so the one event the
    /// user walks away for arrived in silence.
    func testFinishedMakesASound() {
        XCTAssertTrue(RequestType.finished.deservesSound)
        XCTAssertFalse(RequestType.finished.isActionable)
    }

    func testEverythingUserFacingMakesASound() {
        for type in [RequestType.approval, .question, .finished, .error] {
            XCTAssertTrue(type.deservesSound, "\(type) should be audible")
        }
    }

    func testBookkeepingStaysSilent() {
        for type in [RequestType.sessionStart, .sessionEnd] {
            XCTAssertFalse(type.deservesSound, "\(type) should be silent")
            XCTAssertFalse(type.isActionable)
        }
    }
}
