// The typing logic through the iPhone's way of editing text (insert and delete-backwards only),
// against a stand-in for an app's text field. The recorded sessions must leave exactly the text
// the JavaScript version's model field had, including with smart quotes, short context and an
// app that shows changes late. Other tests change the text behind the keyboard's back and check
// it never deletes or replaces anything it didn't just type.

import XCTest
@testable import TrailEngine

/// A stand-in for an app's text field as a keyboard sees it through UITextDocumentProxy.
final class FakeDocument: TextDocument {
    var units: [UInt16] = []
    var cursor = 0
    /// Turn ' into ’ as it's typed, like iOS smart punctuation.
    var smartQuotes = false
    /// Show at most this many characters before the cursor.
    var beforeLimit: Int?
    /// Show the state from before the last edit (an app that updates what it shows late).
    var lagging = false
    /// Show only the current paragraph around the cursor (as some apps do).
    var paragraphOnly = false
    /// Show no text at all around the cursor (as a few apps do).
    var hidesText = false
    /// What the app keeps showing while frozen (an app that shows the cursor's moves late).
    private var frozenView: (before: String?, after: String?)?
    /// A one-line field: Return does the field's action and adds nothing.
    var singleLine = false
    private var lagged: String?
    var edits = 0

    var text: String { String(decoding: units, as: UTF16.self) }

    private var realBefore: String { String(decoding: units[0..<cursor], as: UTF16.self) }

    /// The app keeps showing what it shows now, until unfreeze.
    func freeze() { frozenView = (textBeforeCursor, textAfterCursor) }
    func unfreeze() { frozenView = nil }

    var textBeforeCursor: String? {
        if let f = frozenView { return f.before }
        if hidesText { return nil }
        var s = lagging ? (lagged ?? realBefore) : realBefore
        if paragraphOnly, let nl = s.lastIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        if let lim = beforeLimit { s = String(s.suffix(lim)) }
        return s.isEmpty ? nil : s
    }

    var textAfterCursor: String? {
        if let f = frozenView { return f.after }
        if hidesText { return nil }
        var s = String(decoding: units[cursor...], as: UTF16.self)
        if paragraphOnly, let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        return s.isEmpty ? nil : s
    }

    var hasText: Bool { !units.isEmpty }

    /// The app changes the text itself (Undo, a Send button clearing the box).
    func appSets(_ t: String, cursor c: Int? = nil) {
        lagged = nil
        units = Array(t.utf16)
        cursor = c ?? units.count
    }

    func insertText(_ t: String) {
        if singleLine && t.contains("\n") { return }
        lagged = realBefore
        edits += 1
        let s = smartQuotes ? t.replacingOccurrences(of: "'", with: "’") : t
        let u = Array(s.utf16)
        units.insert(contentsOf: u, at: cursor)
        cursor += u.count
    }

    func deleteBackward() {
        lagged = realBefore
        edits += 1
        guard let last = realBefore.last else { return }
        let n = String(last).utf16.count
        units.removeSubrange((cursor - n)..<cursor)
        cursor -= n
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        lagged = nil
        cursor = max(0, min(units.count, cursor + offset))
    }

    /// The user taps somewhere in the text.
    func place(_ i: Int) {
        lagged = nil
        cursor = max(0, min(units.count, i))
    }

    /// The app has caught up.
    func settle() { lagged = nil }
}

final class ProxyTargetTests: XCTestCase {
    private func straight(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
    }

    /// Replays every recorded session through ProxyTarget and a FakeDocument.
    /// - Parameters:
    ///   - gap: seconds between events (1 is slower than any app's lag, so every check is strict).
    ///   - settles: whether the app catches up after each event; if not, a lagging app is still
    ///     behind when the next key comes (it catches up during pauses).
    private func replay(smartQuotes: Bool = false, beforeLimit: Int? = nil, lagging: Bool = false, paragraphOnly: Bool = false,
                        gap: Double = 0.05, settles: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let f = TestData.fixture("sessions.json")
        let geo = geometry(f)
        var steps = 0
        for s in f["sessions"].array {
            let name = s["name"].string!
            let quotedSession = name == "apostrophes"
            let lex = TestData.lexicon(s["langs"].strings.compactMap { $0 }, users: s["learned"].bool ? f["users"] : TestData.fresh)
            let doc = FakeDocument()
            doc.appSets(s["text"].string ?? "")
            doc.smartQuotes = smartQuotes
            doc.beforeLimit = beforeLimit
            doc.lagging = lagging
            doc.paragraphOnly = paragraphOnly
            var seconds = 100.0
            let target = ProxyTarget(proxy: { doc }, now: { seconds })
            let view = RecordingSurface()
            var clock = 1000.0
            let engine = InputEngine(target: target, view: view, lex: lex, now: { clock })
            engine.onGeometry(geo.cx, geo.cy, geo.kw)
            target.onExternalChange = { [weak engine] in engine?.onExternalChange() }
            let st = s["settings"]
            var settings = TypingSettings()
            settings.swipe = st["swipe"].bool
            settings.smartFix = st["smartFix"].bool
            settings.autocorrect = st["autocorrect"].bool
            settings.doubleSpace = st["doubleSpace"].bool
            settings.learn = st["learn"].bool
            settings.pairs = st["pairs"].bool
            settings.typingLang = st["typingLang"].string ?? "auto"
            settings.lastLang = st["lastLang"].string
            target.sync()
            engine.start(settings)
            for (i, (e, want)) in zip(s["events"].array, s["steps"].array).enumerated() {
                let editsBefore = doc.edits
                switch e["t"].string! {
                case "key": engine.onKey(e["code"].int)
                case "alt": engine.typeAlt(e["ch"].string!)
                case "del": engine.onDelete()
                case "delHeld": engine.onDelete(repeating: true)
                case "delEnd": engine.onDeleteEnd()
                case "swipe":
                    let xs = e["xs"].doubles
                    engine.onSwipe(xs, e["ys"].doubles, xs.count)
                case "strip": engine.onStripTap(e["slot"].int)
                case "stripLong": engine.onStripLongPress(e["slot"].int)
                case "move": engine.onCursorMove(e["chars"].int)
                case "padStart": engine.onTrackpadStart(width: e["w"].int, lineTravel: e["lt"].double)
                case "pad": engine.onTrackpadMove(cols: e["x"].double, lines: e["y"].double)
                case "padEnd": engine.onTrackpadEnd()
                case "moveEnd": engine.onCursorMoveEnd()
                case "place":
                    doc.place(e["index"].int)
                    if target.checkExternal() { engine.onExternalChange() }
                case "emoji": engine.onEmoji(e["text"].string!)
                case "emojiBack": engine.onEmojiBack()
                case "start":
                    doc.settle()
                    target.sync()
                    engine.start(settings)
                case "wait":
                    clock += e["ms"].double
                    seconds += e["ms"].double / 1000
                    doc.settle()
                default: XCTFail("unknown event")
                }
                clock += 1
                seconds += gap
                // What iOS does after an edit: tell the keyboard the text changed. With a
                // lagging app, it still shows the old text at that moment.
                if target.checkExternal() { engine.onExternalChange() }
                // A lagging app is behind only for a moment: by a key that made no edit, it has caught up.
                if settles || doc.edits == editsBefore { doc.settle() }
                let what = "\(name), step \(i) (\(e["t"].string!))"
                let wantText = want["text"].string!
                // Smart quotes turn the session's own quote marks curly too; compare them straight.
                let got = smartQuotes || quotedSession ? straight(doc.text) : doc.text
                let exp = smartQuotes || quotedSession ? straight(wantText) : wantText
                XCTAssertEqual(got, exp, what, file: file, line: line)
                XCTAssertEqual(doc.cursor, want["sel"].int, "\(what): cursor", file: file, line: line)
                XCTAssertEqual(view.strip, want["strip"].strings, "\(what): suggestions", file: file, line: line)
                if got != exp { break }
                steps += 1
            }
        }
        XCTAssertGreaterThan(steps, 300, file: file, line: line)
    }

    func testSessionsThroughTheProxyMatchTheModelField() {
        replay()
    }

    func testSessionsWithSmartQuotes() {
        replay(smartQuotes: true)
    }

    func testSessionsWhenTheAppShowsOnlyRecentText() {
        replay(beforeLimit: 200)
    }

    func testSessionsWhenTheAppShowsChangesLate() {
        replay(lagging: true)
    }

    func testSessionsWhenTheAppStaysBehindUntilTheNextKey() {
        replay(lagging: true, settles: false)
    }

    func testSessionsWhenTheAppShowsOnlyTheCurrentParagraph() {
        replay(paragraphOnly: true)
    }

    // Typed slowly, no difference can pass as the app being behind: every check is strict.

    func testSessionsTypedSlowly() {
        replay(gap: 1)
    }

    func testSessionsTypedSlowlyWithSmartQuotes() {
        replay(smartQuotes: true, gap: 1)
    }

    func testSessionsTypedSlowlyWhenTheAppShowsOnlyRecentText() {
        replay(beforeLimit: 200, gap: 1)
    }

    func testSessionsTypedSlowlyWhenTheAppShowsOnlyTheCurrentParagraph() {
        replay(paragraphOnly: true, gap: 1)
    }

    /// A keyboard on a stand-in field, with a clock the test moves.
    private struct Rig {
        let doc: FakeDocument
        let engine: InputEngine
        let target: ProxyTarget
        /// What the bar shows (the engine only holds it weakly).
        let view: RecordingSurface
        /// Lets this many seconds pass.
        let advance: (Double) -> Void

        /// Time passes and iOS tells the keyboard the text may have changed.
        func tick(_ s: Double = 1.5) {
            advance(s)
            if target.checkExternal() { engine.onExternalChange() }
        }
    }

    private func rig(_ start: String = "") -> Rig {
        let doc = FakeDocument()
        doc.appSets(start)
        var seconds = 100.0
        let target = ProxyTarget(proxy: { doc }, now: { seconds })
        let lex = TestData.lexicon(["en"], users: TestData.fresh)
        let view = RecordingSurface()
        var ms = 1000.0
        let engine = InputEngine(target: target, view: view, lex: lex, now: { ms })
        let geo = geometry(TestData.fixture("sessions.json"))
        engine.onGeometry(geo.cx, geo.cy, geo.kw)
        target.onExternalChange = { [weak engine] in engine?.onExternalChange() }
        target.sync()
        engine.start(TypingSettings())
        return Rig(doc: doc, engine: engine, target: target, view: view, advance: { s in
            seconds += s
            ms += s * 1000
        })
    }

    private func type(_ engine: InputEngine, _ s: String) {
        for c in s { engine.onKey(c == " " ? KeyCode.space : Int(c.unicodeScalars.first!.value)) }
    }

    /// A clean swipe through a word's letters: the key centres, with points in between.
    private func swipe(_ engine: InputEngine, _ word: String) {
        let geo = geometry(TestData.fixture("sessions.json"))
        let keys = word.unicodeScalars.map { Int($0.value) - 97 }
        var xs = [Double](), ys = [Double]()
        for (n, k) in keys.enumerated() {
            if n > 0 {
                let p = keys[n - 1]
                for step in 1..<7 {
                    let f = Double(step) / 7
                    xs.append(geo.cx[p] + (geo.cx[k] - geo.cx[p]) * f)
                    ys.append(geo.cy[p] + (geo.cy[k] - geo.cy[p]) * f)
                }
            }
            xs.append(geo.cx[k])
            ys.append(geo.cy[k])
        }
        engine.onSwipe(xs, ys, xs.count)
    }

    /// Automatic fixes and red words only where the keyboard learns: not where the app turned
    /// autocorrection off, nor in user name, address and similar fields.
    func testNoAutomaticFixesWhereTheKeyboardDoesNotLearn() {
        let r = rig()
        r.engine.setField(suggest: true, sentenceCaps: true, allCaps: false, learn: false)
        type(r.engine, "teh ")
        XCTAssertEqual(r.doc.text, "Teh ")
        type(r.engine, "blorf ")
        XCTAssertEqual(r.doc.text, "Teh blorf ")
        XCTAssertEqual(r.view.flag, -1, "no red word")
        // The same in an ordinary field.
        let s = rig()
        type(s.engine, "teh ")
        XCTAssertEqual(s.doc.text, "The ")
        type(s.engine, "blorf ")
        XCTAssertEqual(s.doc.text, "The blorf ")
        XCTAssertEqual(s.view.flag, 0)
        XCTAssertEqual(s.view.strip, ["blorf", "blood", "blog"])
    }

    /// In an app that doesn't show its text, the keyboard can't tell what's before the cursor, so
    /// it offers nothing that would replace text: no undo after an automatic fix (delete is just
    /// delete), and no red word.
    func testNoUndoOfferOrRedWordWhereTheAppHidesItsText() {
        let r = rig()
        r.doc.hidesText = true
        type(r.engine, "so teh ")
        XCTAssertEqual(r.doc.text, "So the ")
        r.advance(1.5)
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "So the")
        XCTAssertEqual(r.view.strip, [nil, nil, nil], "no undo offer")
        type(r.engine, " blorf ")
        XCTAssertEqual(r.doc.text, "So the blorf ")
        XCTAssertEqual(r.view.flag, -1, "no red word")
        // The same in an app that shows its text.
        let s = rig()
        type(s.engine, "so teh ")
        s.advance(1.5)
        s.engine.onDelete()
        XCTAssertEqual(s.doc.text, "So the")
        XCTAssertEqual(s.view.strip, ["“teh”", "the", nil])
    }

    /// Undo in the app after a word: the keyboard must notice, and not delete real text.
    func testUndoInTheAppIsNoticed() {
        let r = rig("I like ")
        type(r.engine, "pizza")
        XCTAssertEqual(r.doc.text, "I like pizza")
        r.doc.appSets("I like ")
        r.tick()
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "I like", "only the space before the cursor goes")
    }

    /// The same Undo when iOS doesn't tell the keyboard: found out at the next key, which then
    /// deletes one character, not the word that's gone. A second key straight after doesn't
    /// type the old word back.
    func testWordThatVanishedWithoutNoticeIsNotDeletedAgain() {
        let r = rig("I like ")
        type(r.engine, "pizza")
        r.doc.appSets("I like ")
        r.advance(0.5)
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "I like")
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "I lik")
    }

    /// A Send button clears the box: the next word starts afresh.
    func testClearedFieldStartsAfresh() {
        let r = rig()
        type(r.engine, "ok")
        XCTAssertEqual(r.doc.text, "Ok")
        r.doc.appSets("")
        r.tick()
        type(r.engine, "x")
        XCTAssertEqual(r.doc.text, "X")
        XCTAssertEqual(r.engine.typed, "X")
    }

    /// The box cleared without iOS saying so: the next swipe starts a new text (capital, no
    /// space in front).
    func testClearedFieldWithoutNoticeGetsNoLeadingSpace() {
        let r = rig()
        type(r.engine, "hello")
        r.doc.appSets("")
        r.advance(0.5)
        swipe(r.engine, "world")
        XCTAssertEqual(r.doc.text, "World")
    }

    /// A one-line field (a search box) swallows Return: the keyboard's picture catches up.
    func testOneLineFieldThatSwallowsReturn() {
        let r = rig()
        r.doc.singleLine = true
        type(r.engine, "pizza")
        r.engine.onKey(KeyCode.enter)
        XCTAssertEqual(r.doc.text, "Pizza")
        r.tick()
        type(r.engine, "near")
        XCTAssertEqual(r.doc.text, "Pizzanear", "no capital: it isn't a new line")
    }

    /// Delete right after a swipe, when the app had removed the word without telling the
    /// keyboard: one character goes, not the length of the word that's gone.
    func testDeletingASwipeAfterAnUnnoticedChangeDeletesOneCharacter() {
        let r = rig("We are here")
        swipe(r.engine, "pizza")
        XCTAssertTrue(r.doc.text.hasPrefix("We are here ") && r.doc.text.count > 12, r.doc.text)
        r.doc.appSets("We are here")
        r.advance(0.5)
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "We are her")
    }

    /// Undoing an automatic fix (don't → dont) after the app changed the text without telling
    /// the keyboard: one character goes, and nothing is typed.
    func testUndoingAFixAfterAnUnnoticedChangeTypesNothing() {
        let r = rig()
        type(r.engine, "dont ")
        XCTAssertEqual(r.doc.text, "Don't ")
        r.doc.appSets("I like ")
        r.advance(0.5)
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "I like")
    }

    /// A tap elsewhere in the text that iOS doesn't pass on, straight after a swipe: delete
    /// works where the cursor really is, one character, even within the app's lag allowance.
    func testCursorMovedWithoutNoticeRightAfterASwipe() {
        for wait in [0.2, 0.5] {
            let r = rig("Some text here.")
            swipe(r.engine, "tomorrow")
            let full = r.doc.text
            XCTAssertTrue(full.hasPrefix("Some text here. ") && full.count > 16, full)
            r.doc.place(4)
            r.advance(wait)
            r.engine.onDelete()
            XCTAssertEqual(r.doc.text, "Som" + String(full.dropFirst(4)), "after \(wait) s")
        }
    }

    /// Return after the app changed the text without notice: the new line still goes in.
    func testKeyStillWorksAfterAnUnnoticedChange() {
        let r = rig()
        type(r.engine, "pizza")
        r.doc.appSets("Hi ")
        r.advance(0.5)
        r.engine.onKey(KeyCode.enter)
        XCTAssertEqual(r.doc.text, "Hi \n")
    }

    /// An app that shows the keyboard no text at all: the keyboard trusts its own picture, so
    /// a pause doesn't drop the word in progress, and delete after a swipe still removes it.
    func testAppThatShowsNoTextKeepsTheWordInProgress() {
        let r = rig()
        r.doc.hidesText = true
        swipe(r.engine, "hello")
        XCTAssertFalse(r.doc.text.isEmpty)
        r.advance(1.5)
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "")
    }

    /// The same app, when iOS says the text or cursor changed (not right after the keyboard's
    /// own edit): that's believed, so delete then removes one character, not the swiped word.
    func testAppThatShowsNoTextIsBelievedWhenIOSSaysSomethingChanged() {
        let r = rig()
        r.doc.hidesText = true
        swipe(r.engine, "hello")
        let full = r.doc.text
        r.tick()
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, String(full.dropLast()))
    }

    /// An app that shows only the current paragraph, with the cursor tapped onto an empty line
    /// after a swipe: seeing nothing there is real (this field has shown text), so delete
    /// removes one character at the empty line, not the swiped word's length.
    func testEmptyLineInAnAppThatShowsOneParagraph() {
        let r = rig("Dear Sam,\n\nThanks")
        r.doc.paragraphOnly = true
        swipe(r.engine, "again")
        let full = r.doc.text
        XCTAssertTrue(full.hasPrefix("Dear Sam,\n\nThanks ") && full.count > 18, full)
        r.doc.place(10)
        r.tick()
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, String(full.prefix(9)) + String(full.dropFirst(10)))
    }

    /// An app that shows only the current paragraph: the trackpad still takes the cursor into the
    /// paragraph above, and once the app shows the text there it's the keyboard's picture, so the
    /// word the cursor stops after is picked back up.
    func testTrackpadGoesPastTheParagraphTheAppShows() {
        let r = rig("First line here\nSecond")
        r.doc.paragraphOnly = true
        r.target.sync()
        XCTAssertEqual(r.target.contextBefore(limit: 100, beforeComposing: false), "Second")
        r.engine.onCursorMove(-10)
        XCTAssertEqual(r.doc.cursor, 12, "First line h|ere")
        r.tick()
        XCTAssertEqual(r.target.contextBefore(limit: 100, beforeComposing: false), "First line h")
        r.engine.onCursorMove(3)
        r.engine.onCursorMoveEnd()
        XCTAssertEqual(r.doc.cursor, 15)
        XCTAssertEqual(r.view.strip[1], "here", "the word is picked back up")
        type(r.engine, "s")
        XCTAssertEqual(r.doc.text, "First line heres\nSecond")
    }

    /// The trackpad over a field that shows only the paragraph the cursor is in: pushing on past
    /// the first line steps into the paragraph above, and once the app shows it, the cursor goes
    /// as far along it as you were.
    func testTrackpadStepsIntoAParagraphTheAppHides() {
        let r = rig("First line here\nSecond")
        r.doc.paragraphOnly = true
        r.target.sync(newField: true)
        XCTAssertTrue(r.target.mayHideParagraphs)
        r.engine.onTrackpadStart(width: 40)
        r.engine.onTrackpadMove(cols: 0, lines: -1.9)
        XCTAssertEqual(r.doc.cursor, 22, "not yet: a push of two lines past it")
        r.engine.onTrackpadMove(cols: 0, lines: -0.2)
        XCTAssertEqual(r.doc.cursor, 15, "past the line break, to the end of the paragraph above")
        r.tick()
        r.engine.onTrackpadMove(cols: 0, lines: 0.1)
        XCTAssertEqual(r.doc.cursor, 6, "as far along as before: First |line here")
        r.engine.onTrackpadEnd()
        type(r.engine, "x")
        XCTAssertEqual(r.doc.text, "First xline here\nSecond")
    }

    /// A thumb drifting up while dragging along a line with no line breaks doesn't send the cursor
    /// anywhere. A clear push past the line tries once for a paragraph out of sight, and when the
    /// app shows there's nothing there, the cursor comes back to where the finger is.
    func testTrackpadDriftOnALineWithNoBreaks() {
        let r = rig()
        r.doc.appSets("See you at the cafe at noon tomorrow", cursor: 10)
        r.target.sync(newField: true)
        XCTAssertTrue(r.target.mayHideParagraphs, "no line break seen yet")
        r.engine.onTrackpadStart(width: 48)
        r.engine.onTrackpadMove(cols: 0, lines: -1.3)
        XCTAssertEqual(r.doc.cursor, 10, "drifting up by more than a line doesn't move it")
        r.engine.onTrackpadMove(cols: 1, lines: 0)
        XCTAssertEqual(r.doc.cursor, 11)
        r.doc.freeze()
        r.engine.onTrackpadMove(cols: 0, lines: -1)
        XCTAssertEqual(r.doc.cursor, 0, "a push past two lines tries for text above")
        r.engine.onTrackpadMove(cols: 0, lines: 0.05)
        r.engine.onTrackpadMove(cols: 0, lines: -0.05)
        XCTAssertEqual(r.doc.cursor, 0, "it waits until the app shows where that went")
        r.doc.unfreeze()
        r.tick(0.1)
        r.engine.onTrackpadMove(cols: 0, lines: 0)
        XCTAssertEqual(r.doc.cursor, 0, "the app gets a moment to show where that went")
        r.tick(0.3)
        r.engine.onTrackpadMove(cols: 0, lines: 0)
        XCTAssertEqual(r.doc.cursor, 11, "nothing above: back where the finger is")
        r.engine.onTrackpadMove(cols: 0, lines: -3)
        XCTAssertEqual(r.doc.cursor, 11, "and it doesn't try again this drag")
        r.engine.onTrackpadEnd()
        type(r.engine, "x")
        XCTAssertEqual(r.doc.text, "See you at xthe cafe at noon tomorrow")
    }

    /// Let go right after a push past the first line, before the app has shown where that went:
    /// the cursor goes back to where it was (it isn't left at the start of the text).
    func testTrackpadLetGoWhileWaitingGoesBack() {
        let r = rig()
        r.doc.appSets("See you at the cafe at noon tomorrow", cursor: 10)
        r.target.sync(newField: true)
        r.engine.onTrackpadStart(width: 48)
        r.engine.onTrackpadMove(cols: 1, lines: 0)
        XCTAssertEqual(r.doc.cursor, 11)
        r.engine.onTrackpadMove(cols: 0, lines: -2.1)
        XCTAssertEqual(r.doc.cursor, 0, "a push past two lines tries for text above")
        r.engine.onTrackpadEnd()
        XCTAssertEqual(r.doc.cursor, 11, "let go before the app showed anything: back where it was")
        type(r.engine, "x")
        XCTAssertEqual(r.doc.text, "See you at xthe cafe at noon tomorrow")
    }

    /// Stepping up from the very start of a paragraph in an app that shows only that paragraph:
    /// iOS shows a keyboard the app's text a moment after a move, and until then the field looks
    /// just as it would with nothing above. The trackpad waits for the app before deciding.
    func testTrackpadWaitsForTheAppAtTheStartOfAParagraph() {
        let r = rig("First line here\nSecond")
        r.doc.paragraphOnly = true
        r.doc.place(16)
        r.target.sync(newField: true)
        r.engine.onTrackpadStart(width: 40)
        r.doc.freeze()
        r.engine.onTrackpadMove(cols: 0, lines: -2.1)
        XCTAssertEqual(r.doc.cursor, 15, "into the paragraph above")
        r.advance(0.1)
        r.engine.onTrackpadMove(cols: 0, lines: 0.05)
        r.doc.unfreeze()
        r.tick(0.1)
        r.engine.onTrackpadMove(cols: 0, lines: 0.1)
        XCTAssertEqual(r.doc.cursor, 0, "as far along the line above as before: |First")
        r.engine.onTrackpadEnd()
        type(r.engine, "x")
        XCTAssertEqual(r.doc.text, "XFirst line here\nSecond", "(capital: the start of the text)")
    }

    /// Dragging along a line over characters made of several (👩‍💻, a flag) keeps the keyboard in
    /// step with the iPhone, which moves the cursor over them whole.
    func testTrackpadAlongALineOverEmoji() {
        let r = rig("dev 👩‍💻 and 🇨🇦 ok\nnext")
        r.engine.onTrackpadStart(width: 48)
        r.engine.onTrackpadMove(cols: 0, lines: -1)
        XCTAssertEqual(r.doc.cursor, 4, "dev |👩‍💻")
        r.engine.onTrackpadMove(cols: 1, lines: 0)
        r.engine.onTrackpadMove(cols: 1, lines: 0)
        XCTAssertEqual(r.doc.cursor, 4, "not over 👩‍💻 until the place is past all of it")
        r.engine.onTrackpadMove(cols: 1, lines: 0)
        XCTAssertEqual(r.doc.cursor, 9, "dev 👩‍💻| and")
        r.engine.onTrackpadMove(cols: 6, lines: 0)
        XCTAssertEqual(r.doc.cursor, 14, "and |🇨🇦")
        r.engine.onTrackpadMove(cols: 1, lines: 0)
        XCTAssertEqual(r.doc.cursor, 18, "🇨🇦| ok")
        r.engine.onTrackpadMove(cols: 20, lines: 0)
        XCTAssertEqual(r.doc.cursor, 21, "ok|")
        r.engine.onTrackpadEnd()
        type(r.engine, "s")
        XCTAssertEqual(r.doc.text, "dev 👩‍💻 and 🇨🇦 oks\nnext")
    }

    /// What the app changes during a drag (it isn't looked at then) is taken in when the finger
    /// lifts, before the word there is picked up.
    func testTrackpadEndTakesInWhatTheAppChanged() {
        let r = rig("one two\nthree")
        r.engine.onTrackpadStart(width: 48)
        r.engine.onTrackpadMove(cols: 0, lines: -1)
        XCTAssertEqual(r.doc.cursor, 5, "one t|wo")
        r.doc.appSets("one twenty\nthree", cursor: 10)
        r.engine.onTrackpadEnd()
        XCTAssertEqual(r.view.strip[1], "twenty", "the word now before the cursor is picked up")
        type(r.engine, "s")
        XCTAssertEqual(r.doc.text, "one twentys\nthree")
    }

    /// In a field that has shown its line breaks, pushing past the first line just stays on it.
    func testTrackpadStaysOnTheFirstLine() {
        let r = rig("one\ntwo words")
        XCTAssertFalse(r.target.mayHideParagraphs)
        r.engine.onTrackpadStart(width: 40)
        r.engine.onTrackpadMove(cols: 0, lines: -3)
        XCTAssertEqual(r.doc.cursor, 3, "One|: as far along as the line goes")
        r.engine.onTrackpadMove(cols: 0, lines: 1.2)
        XCTAssertEqual(r.doc.cursor, 13, "back down, as far along as before")
        r.engine.onTrackpadEnd()
    }

    /// While the trackpad is in use, an app that shows the cursor's moves late (a fast drag) isn't
    /// taken over the keyboard's own picture, so the cursor ends where the finger says.
    func testTrackpadIgnoresAnAppThatShowsMovesLate() {
        let r = rig("one\ntwo words\nthree")
        r.engine.onTrackpadStart(width: 40)
        r.doc.freeze()
        // (Longer than an app is allowed to lag at other times, ProxyTarget.lagWindow.)
        r.engine.onTrackpadMove(cols: 0, lines: -1)
        r.tick(0.8)
        XCTAssertEqual(r.doc.cursor, 9, "two w|ords")
        r.engine.onTrackpadMove(cols: -2, lines: 0)
        r.tick(0.8)
        r.engine.onTrackpadMove(cols: 0, lines: -1)
        r.tick(0.8)
        XCTAssertEqual(r.doc.cursor, 3, "one|")
        r.doc.unfreeze()
        r.engine.onTrackpadEnd()
        type(r.engine, "s")
        XCTAssertEqual(r.doc.text, "ones\ntwo words\nthree")
    }

    /// Moved past the text the app had shown, and let go before the app shows the text there: the
    /// word at the old spot in the keyboard's picture isn't picked up, and keys act where the
    /// cursor really is.
    func testNothingPickedUpWhileTheTextThereIsUnknown() {
        let r = rig("one two\nthree four")
        r.doc.paragraphOnly = true
        r.doc.place(3)
        r.tick()
        XCTAssertEqual(r.target.contextAfter(limit: 100), " two")
        r.engine.onCursorMove(10)
        XCTAssertEqual(r.doc.cursor, 13, "one two\nthree| four")
        r.engine.onCursorMoveEnd()
        XCTAssertNil(r.target.composing, "“two” isn't before the cursor any more")
        XCTAssertEqual(r.view.strip, [nil, nil, nil])
        r.engine.onDelete()
        XCTAssertEqual(r.doc.text, "one two\nthre four")
        type(r.engine, "x")
        XCTAssertEqual(r.doc.text, "one two\nthrex four")
    }

    /// Up a line where one character is several code points (an emoji with a skin tone, a flag, a
    /// \r\n): the cursor lands where the model field puts it, not partway.
    func testTrackpadOverWideCharacters() {
        for (text, want) in [("Hi 👍🏽👍🏽\nok", "Hi"), ("first\r\nsecond", "first"), ("Go 🇨🇦🇨🇦 team\nyes", "Go ")] {
            let r = rig(text)
            r.engine.onTrackpadStart(width: 40)
            r.engine.onTrackpadMove(cols: 0, lines: -1)
            r.engine.onTrackpadEnd()
            XCTAssertEqual(r.doc.cursor, want.utf16.count, text.debugDescription)
            let e = Editor(text: text)
            let engine = InputEngine(target: e, view: nil, lex: TestData.lexicon(["en"], users: TestData.fresh), now: { 0 })
            engine.start(TypingSettings())
            engine.onTrackpadStart(width: 40)
            engine.onTrackpadMove(cols: 0, lines: -1)
            engine.onTrackpadEnd()
            XCTAssertEqual(e.sel, want.utf16.count, "model field: \(text.debugDescription)")
        }
    }

    /// Past the start or end of the text, the cursor just stops there.
    func testTrackpadStopsAtTheEnds() {
        let r = rig("Hi there")
        r.engine.onCursorMove(-50)
        XCTAssertEqual(r.doc.cursor, 0)
        r.tick()
        r.engine.onCursorMove(50)
        XCTAssertEqual(r.doc.cursor, 8)
        r.engine.onCursorMoveEnd()
        XCTAssertEqual(r.view.strip[1], "there", "picked back up at the end")
        type(r.engine, "s")
        XCTAssertEqual(r.doc.text, "Hi theres")
    }

    /// The four ways what the app shows can fit the keyboard's picture.
    func testHowTheAppsTextFits() {
        let doc = FakeDocument()
        doc.appSets("Hi ")
        doc.lagging = true
        var t = 10.0
        let target = ProxyTarget(proxy: { doc }, now: { t })
        target.sync()
        XCTAssertEqual(target.fit(), .same)
        target.setComposingText("he")
        XCTAssertEqual(target.fit(), .behind, "the app still shows the text before the keyboard's last edit")
        t += 0.5
        XCTAssertEqual(target.fit(), .changed, "too long ago to be the app being slow")
        doc.settle()
        XCTAssertEqual(target.fit(), .same)
        doc.appSets("")
        XCTAssertEqual(target.fit(), .changed, "the box was emptied")

        // An app that has never shown the keyboard this field's text.
        let hidden = FakeDocument()
        hidden.appSets("Secret")
        hidden.hidesText = true
        let blind = ProxyTarget(proxy: { hidden }, now: { t })
        blind.sync(newField: true)
        XCTAssertEqual(blind.fit(), .unknown)
    }

    /// After the cursor moves elsewhere, nothing that wasn't typed by the keyboard is deleted.
    func testNeverDeletesTextAfterTheCursorMoves() {
        let lex = TestData.lexicon(["en"], users: TestData.fresh)
        let doc = FakeDocument()
        doc.insertText("Keep this text, ")
        let target = ProxyTarget { doc }
        target.sync()
        let view = RecordingSurface()
        let engine = InputEngine(target: target, view: view, lex: lex, now: { 1000 })
        let f = TestData.fixture("sessions.json")
        let geo = geometry(f)
        engine.onGeometry(geo.cx, geo.cy, geo.kw)
        engine.start(TypingSettings())
        for c in "hel" { engine.onKey(Int(c.unicodeScalars.first!.value)) }
        XCTAssertEqual(doc.text, "Keep this text, hel")
        // The user taps at the start of the text; iOS reports the change.
        doc.place(0)
        if target.checkExternal() { engine.onExternalChange() }
        // Picking a suggestion now must not delete anything at the new spot.
        engine.onStripTap(0)
        engine.onKey(Int(("x" as Character).unicodeScalars.first!.value))
        XCTAssertTrue(doc.text.hasSuffix("Keep this text, hel"), doc.text)
        XCTAssertTrue(doc.text.hasPrefix("X") || doc.text.hasPrefix("x"), doc.text)
        engine.onDelete()
        XCTAssertEqual(doc.text, "Keep this text, hel")
    }

    func testDeletesWholeCharactersByUTF16Count() {
        let doc = FakeDocument()
        doc.insertText("a😀é")
        let target = ProxyTarget { doc }
        target.sync()
        target.deleteBefore(utf16: 1) // é
        XCTAssertEqual(doc.text, "a😀")
        target.deleteBefore(utf16: 2) // the emoji, one character
        XCTAssertEqual(doc.text, "a")
        XCTAssertEqual(target.textBefore(utf16: 5), "a")
    }

    func testMovesTheCursorByWholeCharacters() {
        let doc = FakeDocument()
        doc.insertText("ab😀cd")
        let target = ProxyTarget { doc }
        target.sync()
        target.moveCursor(-3) // over d, c and the emoji
        XCTAssertEqual(doc.cursor, 2)
        target.moveCursor(1)
        XCTAssertEqual(doc.cursor, 4)
        XCTAssertEqual(target.textBefore(utf16: 2), "😀")
    }

    func testOwnEditsAreNotMistakenForOutsideChanges() {
        let doc = FakeDocument()
        doc.appSets("Hi ")
        doc.lagging = true
        let target = ProxyTarget { doc }
        target.sync()
        target.setComposingText("he")
        XCTAssertFalse(target.checkExternal(), "a late update of the keyboard's own edit isn't an outside change")
        doc.settle()
        XCTAssertFalse(target.checkExternal())
        doc.place(0)
        XCTAssertTrue(target.checkExternal(), "moving the cursor is an outside change")
    }
}
