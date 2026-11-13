// The typing logic through the iPhone's way of editing text (insert and delete-backwards only),
// against a stand-in for an app's text field. The recorded sessions must leave exactly the text
// the JavaScript version's model field had, including with smart quotes and short context.

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
    private var lagged: String?
    var edits = 0

    var text: String { String(decoding: units, as: UTF16.self) }

    private var realBefore: String { String(decoding: units[0..<cursor], as: UTF16.self) }

    var textBeforeCursor: String? {
        var s = lagging ? (lagged ?? realBefore) : realBefore
        if let lim = beforeLimit { s = String(s.suffix(lim)) }
        return s.isEmpty ? nil : s
    }

    var textAfterCursor: String? {
        let s = String(decoding: units[cursor...], as: UTF16.self)
        return s.isEmpty ? nil : s
    }

    func insertText(_ t: String) {
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
    private func replay(smartQuotes: Bool = false, beforeLimit: Int? = nil, lagging: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
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
            let target = ProxyTarget { doc }
            let view = RecordingSurface()
            var clock = 1000.0
            let engine = InputEngine(target: target, view: view, lex: lex, now: { clock })
            engine.onGeometry(geo.cx, geo.cy, geo.kw)
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
                    target.sync()
                    engine.start(settings)
                case "wait": clock += e["ms"].double
                default: XCTFail("unknown event")
                }
                clock += 1
                // What iOS does after an edit: tell the keyboard the text changed. With a
                // lagging app, it still shows the old text at that moment.
                if target.checkExternal() { engine.onExternalChange() }
                doc.settle()
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
