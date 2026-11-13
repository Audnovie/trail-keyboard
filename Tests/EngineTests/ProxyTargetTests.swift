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
    /// A one-line field: Return does the field's action and adds nothing.
    var singleLine = false
    private var lagged: String?
    var edits = 0

    var text: String { String(decoding: units, as: UTF16.self) }

    private var realBefore: String { String(decoding: units[0..<cursor], as: UTF16.self) }

    var textBeforeCursor: String? {
        if hidesText { return nil }
        var s = lagging ? (lagged ?? realBefore) : realBefore
        if paragraphOnly, let nl = s.lastIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        if let lim = beforeLimit { s = String(s.suffix(lim)) }
        return s.isEmpty ? nil : s
    }

    var textAfterCursor: String? {
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
                case "swipe":
                    let xs = e["xs"].doubles
                    engine.onSwipe(xs, e["ys"].doubles, xs.count)
                case "strip": engine.onStripTap(e["slot"].int)
                case "stripLong": engine.onStripLongPress(e["slot"].int)
                case "move": engine.onCursorMove(e["chars"].int)
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
        // (The engine holds the view weakly; these tests only look at the text.)
        _ = view
        return Rig(doc: doc, engine: engine, target: target, advance: { s in
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
