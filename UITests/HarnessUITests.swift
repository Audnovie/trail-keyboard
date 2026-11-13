// UI tests on the iOS Simulator. The app's test harness hosts the keyboard inside the app (a
// keyboard extension can't be driven reliably from a UI test), so these exercise the real
// keyboard view and typing logic with real taps and drags, plus scripted swipes for paths a UI
// test can't draw.

import XCTest

final class HarnessUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ script: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestHarness", "-HarnessReset"]
        if let s = script { app.launchArguments += ["-HarnessScript", s] }
        app.launch()
        XCTAssertTrue(app.staticTexts["harness.text"].waitForExistence(timeout: 10))
        return app
    }

    private func text(_ app: XCUIApplication) -> String {
        app.staticTexts["harness.text"].value as? String ?? ""
    }

    /// Plays the next batch of the launch script and waits for it to finish.
    private func run(_ app: XCUIApplication) {
        app.buttons["harness.run"].tap()
        let done = NSPredicate(format: "label BEGINSWITH 'done'")
        expectation(for: done, evaluatedWith: app.staticTexts["harness.done"])
        waitForExpectations(timeout: 20)
    }

    private func key(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let k = app.keys["key." + id]
        XCTAssertTrue(k.waitForExistence(timeout: 5), "key \(id) not found")
        return k
    }

    private func memory(_ app: XCUIApplication, _ what: String) {
        print("HARNESS memory \(what): \(app.staticTexts["harness.memory"].label)")
    }

    /// Saves a screenshot next to the repository (CI keeps it with the logs).
    private func shot(_ name: String) {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("logs/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testTappingWordsWithSmartFixes() {
        let app = launch()
        for k in ["d", "o", "n", "t", "space", "i", "space", "k", "n", "o", "w"] { key(app, k).tap() }
        key(app, "period").tap()
        XCTAssertEqual(text(app), "Don't I know.")
        shot("typing")
        memory(app, "after typing")
    }

    func testSwipedWordsGetSpacesAndCapitals() {
        let app = launch("swipe:hello;swipe:world;tap:.;swipe:thanks")
        run(app)
        XCTAssertEqual(text(app), "Hello world. Thanks")
        shot("swiped")
        memory(app, "after swiping")
    }

    func testRealDragAcrossTheTopRowTypesAWord() {
        let app = launch()
        let t = key(app, "t")
        let o = key(app, "o")
        t.press(forDuration: 0.05, thenDragTo: o)
        let typed = text(app)
        XCTAssertEqual(typed, "To", "a drag from t to o typed \(typed)")
    }

    func testDeleteRemovesAWholeSwipedWord() {
        let app = launch("swipe:hello;swipe:world")
        run(app)
        XCTAssertEqual(text(app), "Hello world")
        key(app, "delete").tap()
        XCTAssertEqual(text(app), "Hello")
    }

    func testPickingAnotherSuggestionReplacesTheSwipe() {
        let app = launch("swipe:sense|tap:slot0")
        run(app)
        let first = text(app)
        XCTAssertEqual(first, "Sense")
        let strip = app.descendants(matching: .any)["trail.strip"]
        let shown = strip.value as? String ?? ""
        let alternative = shown.components(separatedBy: " | ").first ?? ""
        XCTAssertFalse(alternative.isEmpty, "no alternative offered: \(shown)")
        run(app)
        XCTAssertEqual(text(app), alternative)
    }

    func testTrainingRound() {
        let app = launch("tap:gear|swipeTraining;swipeTraining;swipeTraining")
        run(app)
        let start = app.cells["train.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "settings didn't open")
        shot("settings")
        start.tap()
        XCTAssertTrue(app.staticTexts["training.word"].waitForExistence(timeout: 5), "training didn't start")
        run(app)
        let result = app.staticTexts["training.result"].label
        XCTAssertTrue(result.contains("right first time") || result.contains("came out as"), result)
        let profile = app.staticTexts["training.profile"].label
        XCTAssertTrue(profile.contains("3 of 20"), profile)
        shot("training")
        // Nothing reached the text box while training.
        XCTAssertEqual(text(app), "")
        app.buttons["training.done"].tap()
        XCTAssertFalse(app.staticTexts["training.word"].exists)
        memory(app, "after training")
    }

    func testLearnedWordsAreListedAndRemovable() {
        let app = launch("swipe:hello;tap:space;swipe:world;tap:space|tap:gear")
        run(app)
        run(app)
        let table = app.tables["panel.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5), "settings didn't open")
        let link = app.cells["link.words.en"]
        // The list only makes the rows on screen: scroll down to it.
        var tries = 0
        while !link.exists && tries < 8 {
            table.swipeUp(velocity: .slow)
            tries += 1
        }
        XCTAssertTrue(link.waitForExistence(timeout: 3), "no Learned words link")
        link.tap()
        let row = app.cells["word.hello"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "hello isn't in the learned words")
        shot("learned-words")
        app.buttons["word.hello.button"].tap()
        XCTAssertFalse(app.cells["word.hello"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.cells["word.world"].exists)
    }

    func testHoldingASuggestionOffersToBlockIt() {
        let app = launch("swipe:sense")
        run(app)
        let kb = app.otherElements["harness.keyboard"]
        XCTAssertTrue(kb.exists)
        let f = kb.frame
        // The suggestion bar's left slot, held.
        kb.coordinate(withNormalizedOffset: CGVector(dx: 0.5 / 3, dy: 22 / f.height)).press(forDuration: 0.9)
        let strip = app.descendants(matching: .any)["trail.strip"]
        let value = strip.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("Never suggest"), value)
        shot("block-prompt")
        // Block.
        kb.coordinate(withNormalizedOffset: CGVector(dx: (f.width - 1.5 * 84) / f.width, dy: 22 / f.height)).tap()
        let after = strip.value as? String ?? ""
        XCTAssertFalse(after.hasPrefix("Never suggest"), after)
    }

    func testEmojiPanel() {
        let app = launch()
        key(app, "emoji").tap()
        let grid = app.collectionViews["trail.emoji"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        shot("emoji")
        grid.cells.element(boundBy: 0).tap()
        XCTAssertEqual(text(app), "😀")
        app.buttons["ABC"].tap()
        XCTAssertTrue(key(app, "a").exists)
        memory(app, "after emoji")
    }
}
