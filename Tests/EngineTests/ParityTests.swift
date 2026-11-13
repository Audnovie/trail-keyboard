// The iPhone engine must give the same answers as the JavaScript engine it was ported from.
// Each test replays one fixture from tools/fixtures/gen.js.

import XCTest
@testable import TrailEngine

final class TextParityTests: XCTestCase {
    func testKeyOfAndLearnable() {
        let f = TestData.fixture("text.json")
        for c in f["keyOf"].array {
            XCTAssertEqual(keyOf(c[0].string!), c[1].string!, "keyOf(\(c[0].string!))")
        }
        for c in f["isLearnable"].array {
            XCTAssertEqual(isLearnable(c[0].string!), c[1].bool, "isLearnable(\(c[0].string!))")
        }
    }

    func testCaps() {
        let f = TestData.fixture("text.json")
        for c in f["caps"].array {
            let w = c[0].string!
            XCTAssertEqual(capsOf(w), c[1].int, "capsOf(\(w))")
            XCTAssertEqual(withCaps(w, 0), c[2].string!, "withCaps(\(w), 0)")
            XCTAssertEqual(withCaps(w, 1), c[3].string!, "withCaps(\(w), 1)")
            XCTAssertEqual(withCaps(w, 2), c[4].string!, "withCaps(\(w), 2)")
        }
    }

    func testSentenceStart() {
        let f = TestData.fixture("text.json")
        for c in f["capsAtEnd"].array {
            let b = c[0].string!
            XCTAssertEqual(capsAtEnd(of: b), c[1].bool, "capsAtEnd(\(b.debugDescription))")
            let e = Editor()
            e.commitText(b)
            XCTAssertEqual(e.capsAtCursor(), c[1].bool, "Editor.capsAtCursor(\(b.debugDescription))")
        }
    }
}

final class WordListParityTests: XCTestCase {
    func testLookups() {
        let f = TestData.fixture("wordlist.json")
        for code in ["en", "es"] {
            let W = TestData.list(code)
            let g = f[code]
            XCTAssertEqual(W.size, g["size"].int)
            for c in g["find"].array {
                XCTAssertEqual(W.find(c[0].string!), c[1].int, "\(code) find(\(c[0].string!))")
            }
            for c in g["withKey"].array {
                XCTAssertEqual(W.withKey(c[0].string!), c[1].ints, "\(code) withKey(\(c[0].string!))")
            }
            for c in g["prefixRange"].array {
                let r = W.prefixRange(c[0].string!)
                XCTAssertEqual([r.lowerBound, r.upperBound], c[1].ints, "\(code) prefixRange(\(c[0].string!))")
            }
            var sum = 0
            for i in 0..<W.size {
                sum = (sum + (W.find(W.display(i).uppercased()) + 1) * ((i % 97) + 1)) % 1_000_000_007
            }
            XCTAssertEqual(sum, g["findUpperChecksum"].int, "\(code): every word looked up in capitals")
        }
    }
}

final class DetectParityTests: XCTestCase {
    func testDetectLang() {
        let f = TestData.fixture("detect.json")
        let lex = TestData.lexicon(["en", "es"], users: f["users"])
        let both = lex.enabled()
        for c in f["cases"].array {
            let text = c[0].string!
            XCTAssertEqual(detectLang(text, both), c[1].string, "detectLang(\(text.debugDescription))")
            XCTAssertEqual(detectLang(text, [both[0]]), c[2].string)
        }
    }
}

/// Compares ranked results: same words in the same order, costs equal to within a hair. Two
/// results whose costs tie (within the hair) may come out in either order.
func assertSameRanking(_ got: [(String, Double, String?)], _ want: [(String, Double, String?)], _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) {
    var g = got
    // Let near-ties swap to match the expected order.
    for i in 0..<min(g.count, want.count) where g[i].0 != want[i].0 {
        if let j = g.indices.first(where: { $0 > i && g[$0].0 == want[i].0 }), close(g[j].1, g[i].1) {
            g.swapAt(i, j)
        }
    }
    let gotText = g.map { "\($0.0) \($0.1) \($0.2 ?? "-")" }
    let wantText = want.map { "\($0.0) \($0.1) \($0.2 ?? "-")" }
    guard g.count == want.count else {
        XCTFail("\(what): got \(gotText), want \(wantText)", file: file, line: line)
        return
    }
    for i in 0..<g.count {
        if g[i].0 != want[i].0 || g[i].2 != want[i].2 || !close(g[i].1, want[i].1) {
            XCTFail("\(what): result \(i) got \(gotText[i]), want \(wantText[i])\n got \(gotText)\nwant \(wantText)", file: file, line: line)
            return
        }
    }
}

final class DecoderParityTests: XCTestCase {
    func testDecode() {
        let f = TestData.fixture("decoder.json")
        let geo = geometry(f)
        let dec = SwipeDecoder()
        dec.setKeyCenters(geo.cx, geo.cy, geo.kw)
        var configs = [String: J]()
        for c in f["configs"].array { configs[c["name"].string!] = c }
        let fresh = TestData.fresh
        var n = 0
        for c in f["cases"].array {
            let cfg = configs[c["config"].string!]!
            let lex = TestData.lexicon(cfg["langs"].strings.compactMap { $0 }, users: cfg["learned"].bool ? f["users"] : fresh)
            let src = TestData.sources(lex, ctx: cfg["ctx"].string!, fixed: cfg["fixed"].bool)
            let xs = c["xs"].doubles
            let ys = c["ys"].doubles
            let res = dec.decode(xs, ys, xs.count, src, max: 8)
            let want = c["results"].array.map { ($0[0].string!, $0[1].double, $0[2].string) }
            assertSameRanking(res.map { ($0.word, $0.cost, $0.lang) }, want, "\(cfg["name"].string!) swipe of \(c["word"].string!)")
            n += 1
        }
        XCTAssertGreaterThan(n, 200)
    }
}

final class ProfileParityTests: XCTestCase {
    func testLearnAndFit() {
        let f = TestData.fixture("profile.json")
        let geo = geometry(f)
        let dec = SwipeDecoder()
        dec.setKeyCenters(geo.cx, geo.cy, geo.kw)
        let P = SwipeProfile()
        for s in f["steps"].array {
            let xs = s["xs"].doubles
            let ys = s["ys"].doubles
            let al = dec.align(s["word"].string!, xs, ys, xs.count)
            if s["aligned"].isNull {
                XCTAssertNil(al)
                continue
            }
            guard let a = al else {
                XCTFail("no alignment for \(s["word"].string!)")
                continue
            }
            XCTAssertEqual(a.nodes.map { Int($0) }, s["aligned"]["nodes"].ints)
            for (u, v) in zip(a.x, s["aligned"]["x"].doubles) { XCTAssertTrue(close(u, v), "x \(u) vs \(v)") }
            for (u, v) in zip(a.y, s["aligned"]["y"].doubles) { XCTAssertTrue(close(u, v), "y \(u) vs \(v)") }
            let notes = P.learn(a)
            XCTAssertEqual(notes.missed, s["notes"]["missed"].ints)
            XCTAssertTrue(close(notes.endAlong, s["notes"]["endAlong"].double))
            XCTAssertTrue(close(notes.startAlong, s["notes"]["startAlong"].double))
            XCTAssertEqual(P.ready, s["ready"].bool)
        }
        guard let p = P.params() else {
            XCTFail("profile should be ready")
            return
        }
        let w = f["params"]
        for (u, v) in zip(p.dx, w["dx"].doubles) { XCTAssertTrue(close(u, v), "dx \(u) vs \(v)") }
        for (u, v) in zip(p.dy, w["dy"].doubles) { XCTAssertTrue(close(u, v), "dy \(u) vs \(v)") }
        XCTAssertTrue(close(p.overall.0, w["overall"][0].double) && close(p.overall.1, w["overall"][1].double))
        for r in 0..<3 {
            XCTAssertTrue(close(p.bias[r].0, w["bias"][r][0].double), "bias \(r)")
            XCTAssertTrue(close(p.bias[r].1, w["bias"][r][1].double), "bias \(r)")
            XCTAssertTrue(close(p.reach[r], w["reach"][r].double), "reach \(r)")
        }
        let s = P.summary()
        let ws = f["summary"]
        XCTAssertEqual(s.total, ws["total"].int)
        XCTAssertEqual(s.keysSeen, ws["keysSeen"].int)
        XCTAssertTrue(close(s.progress, ws["progress"].double))
        XCTAssertEqual(s.missedKeys.map { $0.key }, ws["missedKeys"].array.map { $0[0].string! })
        for (k, v) in zip(s.missedKeys, ws["missedKeys"].array) { XCTAssertTrue(close(k.missRate, v[2].double)) }

        // Saving keeps 4 decimals, like the JavaScript; the saved copy must match exactly.
        let saved = P.saved()
        let want = f["saved"]
        XCTAssertEqual(saved.total, want["total"].double)
        for (name, mine) in [("sy", saved.sy), ("nk", saved.nk), ("syk", saved.syk), ("missk", saved.missk), ("nr", saved.nr),
                             ("su", saved.su), ("sry", saved.sry), ("m2", saved.m2), ("nkr", saved.nkr), ("suk", saved.suk)] {
            let theirs = want[name].doubles
            XCTAssertEqual(mine.count, theirs.count, name)
            for (u, v) in zip(mine, theirs) { XCTAssertTrue(close(u, v, 1e-12), "\(name) \(u) vs \(v)") }
        }
        // And a saved copy loads back to the same fit (to within the rounding).
        let Q = SwipeProfile()
        Q.load(saved)
        XCTAssertEqual(Q.total, P.total)
        XCTAssertNotNil(Q.params())

        // Decoding with the profile.
        dec.setProfile(p)
        let lex = TestData.lexicon(["en", "es"], users: f["users"])
        for c in f["decodes"].array {
            let xs = c["xs"].doubles
            let ys = c["ys"].doubles
            let res = dec.decode(xs, ys, xs.count, TestData.sources(lex, ctx: "en"), max: 8)
            let want = c["results"].array.map { ($0[0].string!, $0[1].double, $0[2].string) }
            assertSameRanking(res.map { ($0.word, $0.cost, $0.lang) }, want, "profiled swipe of \(c["word"].string!)")
        }
    }

    func testMalformedSavedProfileStartsOver() {
        let P = SwipeProfile()
        var s = P.saved()
        s.total = 30
        s.nk = [1, 2, 3]
        P.load(s)
        XCTAssertEqual(P.total, 0)
        P.load(nil)
        XCTAssertEqual(P.total, 0)
    }
}

final class SuggestParityTests: XCTestCase {
    func testSuggestions() {
        let f = TestData.fixture("suggest.json")
        let geo = geometry(f)
        let sug = TypingSuggester()
        sug.setKeyCenters(geo.cx, geo.cy, geo.kw)
        var configs = [String: J]()
        for c in f["configs"].array { configs[c["name"].string!] = c }
        let fresh = TestData.fresh
        for c in f["cases"].array {
            let cfg = configs[c["config"].string!]!
            let lex = TestData.lexicon(cfg["langs"].strings.compactMap { $0 }, users: cfg["learned"].bool ? f["users"] : fresh)
            let src = TestData.sources(lex, ctx: cfg["ctx"].string!)
            let typed = c["typed"].string!
            let res = sug.suggest(typed, src, max: 6)
            let want = c["results"].array
            let what = "\(cfg["name"].string!) suggest(\(typed))"
            XCTAssertEqual(res.count, want.count, "\(what): \(res.map { $0.word }) vs \(want.map { $0[0].string! })")
            for (r, w) in zip(res, want) {
                XCTAssertEqual(r.word, w[0].string!, what)
                XCTAssertTrue(close(r.score, w[1].double), "\(what) score of \(r.word): \(r.score) vs \(w[1].double)")
                XCTAssertEqual(r.kind.rawValue, w[2].int, what)
                XCTAssertTrue(close(r.cost, w[3].double), what)
                XCTAssertEqual(r.lang, w[4].string, what)
            }
        }
        for p in f["editCost"].array {
            XCTAssertTrue(close(sug.editCost(p[0].string!, p[1].string!, 99), p[2].double), "editCost \(p[0].string!) \(p[1].string!)")
        }
    }
}

final class UserWordsParityTests: XCTestCase {
    func testOperations() {
        let f = TestData.fixture("userwords.json")
        let U = UserWords(starters: STARTER_BLOCKS)
        let ops = f["ops"].array
        let trace = f["trace"].array
        XCTAssertEqual(ops.count, trace.count)
        for (op, t) in zip(ops, trace) {
            switch op[0].string! {
            case "use": U.recordUse(op[1].string!, amount: op[2].double, inBaseList: op[3].bool)
            case "reject": U.recordReject(op[1].string!)
            case "add": U.addManual(op[1].string!)
            case "block": U.block(op[1].string!)
            case "unblock": U.unblock(op[1].string!)
            case "setBase": U.setInBaseList(op[1].string!, op[2].bool)
            case "remove": U.remove(op[1].string!)
            default: XCTFail("unknown op")
            }
            let what = "after \(op.array.map { "\($0.raw ?? "nil")" })"
            XCTAssertEqual(U.version, t["version"].int, what)
            for b in t["bonus"].array {
                XCTAssertTrue(close(U.bonus(b[0].string!), b[1].double), "\(what): bonus(\(b[0].string!)) \(U.bonus(b[0].string!)) vs \(b[1].double)")
            }
            XCTAssertEqual(U.blockedWords(), t["blocked"].strings.compactMap { $0 }, what)
            XCTAssertEqual(U.activeAdded().map { $0.word }, t["active"].strings.compactMap { $0 }, what)
            XCTAssertEqual(U.count, t["count"].int, what)
        }
        checkSaved(U.saved(), f["saved"], "saved")
        checkSaved(U.saved(maxEntries: 3), f["savedCapped"], "saved, capped")
        checkAll(U.all(), f["all"], "all")
        for l in f["loads"].array {
            let V = UserWords(starters: STARTER_BLOCKS)
            V.load(l["input"].decode(UserWords.Saved.self))
            checkSaved(V.saved(), l["saved"], "load \(l["input"].raw ?? "nil")")
            checkAll(V.all(), l["all"], "load \(l["input"].raw ?? "nil")")
        }
    }

    private func checkSaved(_ s: UserWords.Saved, _ want: J, _ what: String) {
        let rows = want["learned"].array
        XCTAssertEqual(s.learned.count, rows.count, what)
        for (mine, theirs) in zip(s.learned, rows) {
            guard case .array(let r) = mine else {
                XCTFail(what)
                continue
            }
            XCTAssertEqual(r[0], .string(theirs[0].string!), what)
            XCTAssertEqual(r[1], .number(theirs[1].double), what)
            XCTAssertEqual(r[2], .number(theirs[2].double), what)
            XCTAssertEqual(r[3], .number(theirs[3].double), what)
        }
        XCTAssertEqual(s.blocked ?? [], want["blocked"].strings.compactMap { $0 }, what)
    }

    private func checkAll(_ all: [UserWords.Entry], _ want: J, _ what: String) {
        let rows = want.array
        XCTAssertEqual(all.count, rows.count, what)
        for (e, r) in zip(all, rows) {
            XCTAssertEqual(e.word, r[0].string!, what)
            XCTAssertTrue(close(e.uses, r[1].double), what)
            XCTAssertEqual(Double(e.rejects), r[2].double, what)
            XCTAssertEqual(e.added, r[3].bool, what)
        }
    }
}
