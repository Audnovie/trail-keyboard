// The lines on screen the space-bar trackpad works over, and the sentence-start rule, against the
// JavaScript engine.

import XCTest
@testable import TrailEngine

final class CursorParityTests: XCTestCase {
    func testPadLines() {
        for c in TestData.fixture("cursor.json")["pad"].array {
            let text = c[0].string!, width = c[1].int
            let lines = padLines(text, width: width)
            XCTAssertEqual(lines.map { [$0.0, $0.1] }, c[2].array.map { [$0[0].int, $0[1].int] },
                           "padLines(\(text.debugDescription), width: \(width))")
            for a in c[3].array {
                XCTAssertEqual(padLineOf(lines, a[0].int), a[1].int, "padLineOf(\(text.debugDescription), \(a[0].int))")
            }
        }
    }

    /// Where a cursor can stop: never inside ❤️, 👍🏽, a flag, 👩‍💻 or \r\n (Swift's characters
    /// against the JavaScript engine's Intl.Segmenter).
    func testGraphemeEdges() {
        for c in TestData.fixture("cursor.json")["edges"].array {
            let text = c[0].string!
            let edges = graphemeEdges(text)
            XCTAssertEqual(edges.indices.filter { edges[$0] }, c[1].array.map { $0.int }, "graphemeEdges(\(text.debugDescription))")
        }
    }

    func testSentenceStarts() {
        for c in TestData.fixture("cursor.json")["caps"].array {
            XCTAssertEqual(capsAtEnd(of: c[0].string!), c[1].bool, "capsAtEnd(\(c[0].string!.debugDescription))")
        }
    }
}
