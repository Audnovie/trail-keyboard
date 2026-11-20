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

    /// The text with the cursor shown as |.
    private func caret(_ app: XCUIApplication) -> String {
        app.staticTexts["harness.text"].label
    }

    /// Where the cursor is, in characters from the start.
    private func caretIndex(_ app: XCUIApplication) -> Int {
        let shown = caret(app)
        guard let i = shown.firstIndex(of: "|") else { return -1 }
        return shown.distance(from: shown.startIndex, to: i)
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

    private func strip(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["trail.strip"].value as? String ?? ""
    }

    /// Holding a suggestion asks: Less often, Never or Cancel, each a button of its own.
    func testHoldingASuggestionOffersLessOftenOrNever() {
        let app = launch("type:hel")
        run(app)
        XCTAssertEqual(strip(app), "He | Hel | Help")
        let kb = app.otherElements["harness.keyboard"]
        XCTAssertTrue(kb.exists)
        let f = kb.frame
        // The suggestion bar's right slot, held.
        kb.coordinate(withNormalizedOffset: CGVector(dx: 2.5 / 3, dy: 18 / f.height)).press(forDuration: 0.9)
        XCTAssertEqual(strip(app), "“help” in English — Less often, Never, Cancel")
        for id in ["prompt.less", "prompt.yes", "prompt.no"] {
            XCTAssertTrue(app.buttons[id].exists, "no \(id) button")
        }
        shot("word-prompt")
        app.buttons["prompt.less"].tap()
        // Help came down: the next likeliest takes its place.
        XCTAssertEqual(strip(app), "He | Hel | Her")
        XCTAssertFalse(app.buttons["prompt.less"].exists)
        XCTAssertEqual(text(app), "Hel")
    }

    /// Delete straight after an automatic fix: the bar offers what you typed, and a tap puts it back.
    func testUndoingAnAutomaticFix() {
        let app = launch("type:teh |tap:delete|tap:slot0")
        run(app)
        XCTAssertEqual(text(app), "The ")
        run(app)
        XCTAssertEqual(text(app), "The")
        XCTAssertEqual(strip(app), "“Teh” | The | ")
        shot("undo-offer")
        run(app)
        XCTAssertEqual(text(app), "Teh ")
    }

    /// A word it doesn't know and can't fix for sure is red in the bar, with fixes to tap.
    func testUnknownWordShowsInRedWithFixes() {
        let app = launch("type:blorf |tap:slot1")
        run(app)
        XCTAssertEqual(text(app), "Blorf ")
        XCTAssertEqual(strip(app), "Blorf (check spelling) | Blood | Blog")
        shot("red-word")
        run(app)
        XCTAssertEqual(text(app), "Blood ")
    }

    /// After a space, the word you usually write next is in the bar, and the settings button
    /// stays at its left.
    func testNextWordAfterASpace() {
        let app = launch("type:see you see you see |tap:slot1|tap:gear")
        run(app)
        XCTAssertEqual(text(app), "See you see you see ")
        XCTAssertEqual(strip(app), " | you | ")
        shot("next-word")
        run(app)
        XCTAssertEqual(text(app), "See you see you see you ")
        XCTAssertEqual(strip(app), " | see | ")
        run(app)
        XCTAssertTrue(app.tables["panel.table"].waitForExistence(timeout: 5), "settings didn't open beside the next words")
    }

    /// Deleting back into a word picks it up again: "start", space, back to "st", then "ar": the
    /// bar suggests for "star", not for "ar".
    func testDeletingBackIntoAWordPicksItUp() {
        let app = launch("type:then it will start |tap:delete;tap:delete;tap:delete;tap:delete|type:ar")
        run(app)
        XCTAssertEqual(text(app), "Then it will start ")
        run(app)
        XCTAssertEqual(text(app), "Then it will st")
        XCTAssertEqual(strip(app).components(separatedBy: " | ").dropFirst().first, "st", strip(app))
        run(app)
        XCTAssertEqual(text(app), "Then it will star")
        XCTAssertEqual(strip(app).components(separatedBy: " | ").dropFirst().first, "star", "suggestions for the whole word: \(strip(app))")
        shot("back-into-a-word")
    }

    /// Holding the space bar makes it a trackpad: the cursor follows the finger (a real hold and
    /// drag), and no space is typed.
    func testHoldingTheSpaceBarMovesTheCursor() {
        let app = launch("type:hello world")
        run(app)
        XCTAssertEqual(caret(app), "Hello world|")
        let from = key(app, "space").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // About 9 characters' worth to the left.
        from.press(forDuration: 0.9, thenDragTo: from.withOffset(CGVector(dx: -80, dy: 0)))
        XCTAssertEqual(text(app), "Hello world", "nothing typed")
        let at = caretIndex(app)
        XCTAssertTrue((1...4).contains(at), "the cursor should have moved about 9 characters left: \(caret(app))")
    }

    /// Up and down: across line breaks, keeping the place along the line, and a line's worth along
    /// a long paragraph (a keyboard can't see where the app wraps it, so it goes by the screen's width).
    func testTrackpadUpAndDown() {
        let app = launch("type:one;tap:enter;type:two words|trackpad:0,-1|trackpad:2,0|trackpad:0,1")
        run(app)
        XCTAssertEqual(caret(app), "One\nTwo words|")
        run(app)
        XCTAssertEqual(caret(app), "One|\nTwo words")
        run(app)
        XCTAssertEqual(caret(app), "One\nT|wo words")
        run(app)
        XCTAssertEqual(caret(app), "One\nTwo words|", "down from the last line goes to the end")

        let long = launch("type:the quick brown fox jumps over the lazy dog and runs off|trackpad:0,-1")
        run(long)
        XCTAssertEqual(caretIndex(long), 56)
        run(long)
        let at = caretIndex(long)
        XCTAssertTrue((10...22).contains(at), "up a line's worth (about 40 characters): \(caret(long))")
        shot("trackpad-up")
    }

    /// Each theme (screenshots), and the list in the settings with the current one ticked.
    func testThemes() {
        let ids = ["midnight", "ocean", "forest", "sunset", "rose", "lavender", "paper", "system", "graphite"]
        let app = launch("type:the quick brown fox|" + ids.map { "theme:" + $0 }.joined(separator: "|") + "|tap:gear")
        run(app)
        for id in ids {
            run(app)
            shot("theme-" + id)
        }
        run(app)
        let table = app.tables["panel.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5), "settings didn't open")
        let link = app.cells["link.theme"]
        var tries = 0
        while !link.exists && tries < 8 {
            table.swipeUp(velocity: .slow)
            tries += 1
        }
        XCTAssertTrue(link.waitForExistence(timeout: 3), "no Theme link")
        link.tap()
        let graphite = app.cells["theme.graphite"]
        XCTAssertTrue(graphite.waitForExistence(timeout: 5), "theme list didn't open")
        XCTAssertTrue(graphite.isSelected, "the theme in use is ticked")
        shot("theme-list")
        app.cells["theme.system"].tap()
        XCTAssertTrue(app.cells["theme.system"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.cells["theme.system"].isSelected)
        XCTAssertFalse(app.cells["theme.graphite"].isSelected)
        XCTAssertEqual(text(app), "The quick brown fox", "picking a theme types nothing")
    }

    /// Word pairs are listed in the keyboard's settings, and each can be forgotten.
    func testWordPairsAreListedAndForgettable() {
        let app = launch("type:see you see you ok |tap:gear")
        run(app)
        run(app)
        let table = app.tables["panel.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5), "settings didn't open")
        let link = app.cells["link.pairs.en"]
        var tries = 0
        while !link.exists && tries < 8 {
            table.swipeUp(velocity: .slow)
            tries += 1
        }
        XCTAssertTrue(link.waitForExistence(timeout: 3), "no Word pairs link")
        link.tap()
        let row = app.cells["pair.see.you"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "see you isn't in the word pairs")
        XCTAssertTrue(app.cells["pair.you.see"].exists)
        // Kept as typed ("ok", though the word list has "OK").
        XCTAssertTrue(app.cells["pair.you.ok"].exists)
        shot("word-pairs")
        app.buttons["pair.see.you.button"].tap()
        XCTAssertFalse(app.cells["pair.see.you"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.cells["pair.you.see"].exists)
    }

    func testEmojiPanel() {
        let app = launch()
        key(app, "emoji").tap()
        let grid = app.collectionViews["trail.emoji"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        shot("emoji")
        grid.cells["😀"].tap()
        XCTAssertEqual(text(app), "😀")
        app.buttons["trail.emoji.abc"].tap()
        XCTAssertTrue(key(app, "a").exists)
        memory(app, "after emoji")
    }

    /// Like Apple's: the emoji scroll sideways, and the buttons along the bottom jump to a category.
    func testEmojiPanelScrollsSidewaysByCategory() {
        let app = launch()
        key(app, "emoji").tap()
        let grid = app.collectionViews["trail.emoji"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let first = grid.cells["😀"]
        XCTAssertTrue(first.exists)
        let before = first.frame.minX
        grid.swipeLeft()
        XCTAssertTrue(!first.exists || first.frame.minX < before - 50, "the emoji should move sideways")
        app.buttons["trail.emoji.cat8"].tap()
        let flag = grid.cells["🏁"]
        XCTAssertTrue(flag.waitForExistence(timeout: 3), "Flags")
        XCTAssertTrue(app.buttons["trail.emoji.cat8"].isSelected)
        shot("emoji-flags")
        flag.tap()
        app.buttons["trail.emoji.cat1"].tap()
        XCTAssertTrue(grid.cells["😀"].waitForExistence(timeout: 3), "back to Smileys & People")
        XCTAssertEqual(text(app), "🏁")
        memory(app, "after scrolling the emoji")
    }

    /// Searching: the letter keys type into the search box, matches show in a row, a tap types
    /// one, and Done goes back; Spanish names work too; what was used opens the panel next time.
    func testEmojiSearch() {
        let app = launch()
        key(app, "emoji").tap()
        let search = app.buttons["trail.emoji.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        for k in ["h", "e", "a", "r", "t"] { key(app, k).tap() }
        let results = app.collectionViews["trail.emoji.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        let heart = results.cells["❤️"]
        XCTAssertTrue(heart.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["trail.emoji.query"].value as? String, "heart")
        shot("emoji-search")
        heart.tap()
        XCTAssertEqual(text(app), "❤️")
        for _ in 0..<5 { key(app, "delete").tap() }
        for k in ["c", "o", "r", "a", "z", "o", "n"] { key(app, k).tap() }
        XCTAssertTrue(results.cells["❤️"].waitForExistence(timeout: 3), "Spanish: corazón")
        app.buttons["trail.emoji.searchDone"].tap()
        XCTAssertTrue(app.collectionViews["trail.emoji"].waitForExistence(timeout: 5))
        XCTAssertFalse(results.exists)
        app.buttons["trail.emoji.abc"].tap()
        key(app, "emoji").tap()
        XCTAssertTrue(app.buttons["trail.emoji.cat0"].waitForExistence(timeout: 5), "the Recent page")
        XCTAssertTrue(app.collectionViews["trail.emoji"].cells["❤️"].exists)
        XCTAssertEqual(text(app), "❤️")
        memory(app, "after searching emoji")
    }

    /// The 123 and #+= pages are laid out like Apple's keyboard.
    func testSymbolPagesMatchApplesLayout() {
        let app = launch()
        key(app, "123").tap()
        func inOrder(_ ids: [String], _ what: String) {
            let keys = ids.map { key(app, $0) }
            for (a, b) in zip(keys, keys.dropFirst()) {
                XCTAssertLessThan(a.frame.midX, b.frame.midX, what)
                XCTAssertEqual(a.frame.midY, b.frame.midY, accuracy: 2, what)
            }
        }
        inOrder(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], "123 page, row 1")
        inOrder(["-", "/", ":", ";", "(", ")", "$", "&", "@", "quote"], "123 page, row 2")
        inOrder(["sym2", "period", "comma", "question", "exclamation", "apostrophe", "delete"], "123 page, row 3")
        inOrder(["abc", "emoji", "space", "return"], "123 page, row 4")
        XCTAssertLessThan(key(app, "1").frame.midY, key(app, "-").frame.midY)
        XCTAssertLessThan(key(app, "-").frame.midY, key(app, "period").frame.midY)
        shot("symbols")
        key(app, "quote").tap()
        key(app, "apostrophe").tap()
        key(app, "sym2").tap()
        inOrder(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], "#+= page, row 1")
        inOrder(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], "#+= page, row 2")
        inOrder(["123", "period", "comma", "question", "exclamation", "apostrophe", "delete"], "#+= page, row 3")
        shot("symbols2")
        key(app, "€").tap()
        key(app, "123").tap()
        XCTAssertTrue(key(app, "@").exists)
        key(app, "abc").tap()
        XCTAssertTrue(key(app, "q").exists)
        XCTAssertEqual(text(app), "\"'€")
    }
}
