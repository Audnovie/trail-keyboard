// The cursor up and down lines (the space bar as a trackpad) and the sentence-start rule, against
// the JavaScript engine.

import XCTest
@testable import TrailEngine

final class CursorParityTests: XCTestCase {
    func testLineMoves() {
        for c in TestData.fixture("cursor.json")["lines"].array {
            let before = c[0].string!, after = c[1].string!, dir = c[2].int, width = c[3].int
            XCTAssertEqual(lineMove(before, after, dir, width: width), c[4].int,
                           "lineMove(\(before.debugDescription), \(after.debugDescription), \(dir), width: \(width))")
        }
    }

    func testSentenceStarts() {
        for c in TestData.fixture("cursor.json")["caps"].array {
            XCTAssertEqual(capsAtEnd(of: c[0].string!), c[1].bool, "capsAtEnd(\(c[0].string!.debugDescription))")
        }
    }
}
