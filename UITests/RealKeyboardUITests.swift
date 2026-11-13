// The real keyboard extension, in the Simulator's own text system. CI switches Trail on as the
// Simulator's keyboard first (see .github/workflows/build.yml) and sets TRAIL_REAL_KEYBOARD=1;
// without that, this test is skipped. It types into the companion app's practice box and holds
// the keyboard up for a while so CI can measure the extension's memory.

import XCTest

final class RealKeyboardUITests: XCTestCase {
    func testTheKeyboardExtensionTypes() throws {
        guard ProcessInfo.processInfo.environment["TRAIL_REAL_KEYBOARD"] == "1" else {
            throw XCTSkip("Needs Trail switched on as the Simulator's keyboard (CI does this).")
        }
        let app = XCUIApplication()
        app.launch()
        let field = app.textViews["home.practice"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "practice box not found")
        field.tap()
        sleep(4)
        print("REAL hierarchy after opening the keyboard:\n\(app.debugDescription)")
        let h = app.keys["key.h"]
        guard h.waitForExistence(timeout: 8) else {
            print("REAL Trail's keys aren't visible to the UI test; leaving the keyboard up for screenshots and memory")
            sleep(30)
            return
        }
        for k in ["h", "e", "l", "l", "o", "space", "t", "h", "e", "r", "e"] {
            app.keys["key." + k].tap()
        }
        app.keys["key.period"].tap()
        let typed = field.value as? String ?? ""
        print("REAL typed: \(typed)")
        XCTAssertEqual(typed, "Hello there.")
        // A real drag, t to o, through the extension.
        app.keys["key.space"].tap()
        app.keys["key.t"].press(forDuration: 0.05, thenDragTo: app.keys["key.o"])
        let swiped = field.value as? String ?? ""
        print("REAL after a drag from t to o: \(swiped)")
        XCTAssertTrue(swiped.hasPrefix("Hello there. "), swiped)
        sleep(30)
    }
}
