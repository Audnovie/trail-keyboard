// Replays typing sessions (taps, swipes, suggestion picks, deletes, cursor moves) through the
// iPhone typing logic and checks every step against what the JavaScript version did.

import XCTest
@testable import TrailEngine

/// Keeps what the typing logic shows, like the web trial's keyboard.
final class RecordingSurface: KeyboardSurface {
    var layout = LayoutName.letters
    var emoji = false
    var strip: [String?] = [nil, nil, nil]
    var bold = 1
    var flag = -1
    var next = false
    var prompt: String?
    var buttons: [String] = []
    var shifted = false
    var capsLock = false
    var settingsOpened = 0

    func setLayout(_ name: LayoutName) { layout = name }
    func showEmoji(_ show: Bool) { emoji = show }
    func clearStrip() { setSuggestions(nil, nil, nil, bold: 1, flag: -1) }
    func setShift(_ s: Bool, _ l: Bool) {
        shifted = s
        capsLock = l
    }
    func setSuggestions(_ a: String?, _ b: String?, _ c: String?, bold: Int, flag: Int) {
        strip = [a, b, c]
        self.bold = bold
        self.flag = flag
        next = false
        prompt = nil
        buttons = []
    }
    func setNextWords(_ a: String?, _ b: String?, _ c: String?) {
        setSuggestions(a, b, c, bold: -1, flag: -1)
        next = true
    }
    func setPrompt(_ text: String?, _ buttons: [PromptButton]) {
        prompt = text
        self.buttons = text == nil ? [] : buttons.map { $0.label }
    }
    var hasPrompt: Bool { prompt != nil }
    func openSettings() { settingsOpened += 1 }
}

final class SessionParityTests: XCTestCase {
    func testSessions() {
        let f = TestData.fixture("sessions.json")
        let geo = geometry(f)
        let fresh = TestData.fresh
        var count = 0
        for s in f["sessions"].array {
            let name = s["name"].string!
            let lex = TestData.lexicon(s["langs"].strings.compactMap { $0 }, users: s["learned"].bool ? f["users"] : fresh)
            let ed = Editor()
            let view = RecordingSurface()
            var clock = 1000.0
            let engine = InputEngine(target: ed, view: view, lex: lex, now: { clock })
            var corrections = [[String?]]()
            engine.onCorrection = { c in corrections.append([c.picked, c.pickedLang, c.guess, c.guessLang]) }
            engine.onGeometry(geo.cx, geo.cy, geo.kw)
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
            engine.start(settings)
            let events = s["events"].array
            let steps = s["steps"].array
            XCTAssertEqual(events.count, steps.count)
            for (i, (e, want)) in zip(events, steps).enumerated() {
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
                case "lines": engine.onCursorLines(e["n"].int, width: e["w"].int)
                case "moveEnd": engine.onCursorMoveEnd()
                case "place": engine.onCursorPlaced(e["index"].int, editor: ed)
                case "emoji": engine.onEmoji(e["text"].string!)
                case "emojiBack": engine.onEmojiBack()
                case "start": engine.start(settings)
                case "wait": clock += e["ms"].double
                default: XCTFail("unknown event \(e["t"].string!)")
                }
                clock += 1
                let what = "\(name), step \(i) (\(e["t"].string!) \(e["code"].raw ?? e["word"].raw ?? e["slot"].raw ?? e["ch"].raw ?? ""))"
                XCTAssertEqual(ed.text, want["text"].string!, what)
                XCTAssertEqual([ed.sel, ed.cs, ed.ce], [want["sel"].int, want["cs"].int, want["ce"].int], what)
                XCTAssertEqual(view.strip, want["strip"].strings, what)
                XCTAssertEqual([view.bold, view.flag], [want["bold"].int, want["flag"].int], "\(what): bold and red slots")
                XCTAssertEqual(view.next, want["next"].bool, "\(what): next words")
                XCTAssertEqual(view.prompt, want["prompt"].string, what)
                XCTAssertEqual(view.buttons, want["buttons"].strings.compactMap { $0 }, "\(what): prompt buttons")
                XCTAssertEqual([view.shifted, view.capsLock], [want["shifted"].bool, want["lock"].bool], what)
                XCTAssertEqual(view.layout.rawValue, want["layout"].string!, what)
                XCTAssertEqual(view.emoji, want["emoji"].bool, what)
                XCTAssertEqual(view.settingsOpened, want["settingsOpened"].int, what)
                if ed.text != want["text"].string! || view.strip != want["strip"].strings { break }
                count += 1
            }
            XCTAssertEqual(corrections, s["corrections"].array.map { $0.strings }, "\(name): corrections")
            for code in ["en", "es"] {
                let saved = lex.get(code)!.user.saved()
                let want = s["users"][code]
                let rows = want["learned"].array
                let got = saved.learned.map { v -> String in
                    guard case .array(let r) = v, case .string(let w) = r[0], case .number(let u) = r[1],
                          case .number(let rj) = r[2], case .number(let a) = r[3] else { return "?" }
                    return "\(w) \(u) \(rj) \(a)"
                }
                let exp = rows.map { "\($0[0].string!) \($0[1].double) \($0[2].double) \($0[3].double)" }
                XCTAssertEqual(got, exp, "\(name): learned \(code)")
                XCTAssertEqual(saved.blocked ?? [], want["blocked"].strings.compactMap { $0 }, "\(name): blocked \(code)")
                XCTAssertEqual(pairRows(saved.pairs), want["pairs"].array.map { "\($0[0].string!) \($0[1].string!) \($0[2].double)" }, "\(name): pairs \(code)")
            }
        }
        XCTAssertGreaterThan(count, 300)
    }
}

/// Saved word pairs as "prev next times" lines.
func pairRows(_ rows: [JSONValue]) -> [String] {
    rows.map { v -> String in
        guard case .array(let r) = v, r.count == 3, case .string(let a) = r[0], case .string(let b) = r[1], case .number(let n) = r[2] else { return "?" }
        return "\(a) \(b) \(n)"
    }
}
