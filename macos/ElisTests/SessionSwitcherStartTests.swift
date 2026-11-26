import XCTest
@testable import Elis

@MainActor
final class SessionSwitcherStartTests: XCTestCase {
    func testStartIndex() {
        XCTAssertNil(SessionSwitcher.startIndex(hasSelection: true, count: 1))
        XCTAssertEqual(SessionSwitcher.startIndex(hasSelection: true, count: 3), 1)
        XCTAssertEqual(SessionSwitcher.startIndex(hasSelection: false, count: 1), 0)
        XCTAssertNil(SessionSwitcher.startIndex(hasSelection: false, count: 0))
    }
}
