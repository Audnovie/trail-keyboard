// Word pairs (which word you write after which) against the JavaScript engine: recording,
// weakening and forgetting pairs, keeping only the most recent, saving and loading, finding the
// word before the cursor, and the lifts they give the swipe reader and the suggestions.

import XCTest
@testable import TrailEngine

final class PairsParityTests: XCTestCase {
    func testOperations() {
        let f = TestData.fixture("pairs.json")
        let U = UserWords(starters: STARTER_BLOCKS)
        let ops = f["ops"].array
        let trace = f["trace"].array
        XCTAssertEqual(ops.count, trace.count)
        let probes = ["you're", "i", "see", "x", "was"]
        for (op, t) in zip(ops, trace) {
            switch op[0].string! {
            case "pair": U.recordPair(op[1].string!, op[2].string!, amount: op[3].double)
            case "weaken": U.weakenPair(op[1].string!, op[2].string!)
            case "forget": U.forgetPair(op[1].string!, op[2].string!)
            case "clear": U.clearPairs()
            case "block": U.block(op[1].string!)
            case "remove": U.remove(op[1].string!)
            case "clearLearned": U.clearLearned()
            default: XCTFail("unknown op")
            }
            let what = "after \(op.array.map { "\($0.raw ?? "nil")" })"
            XCTAssertEqual(U.version, t["version"].int, what)
            XCTAssertEqual(U.pairCount, t["count"].int, what)
            for (i, w) in probes.enumerated() {
                let got = U.followers(w).map { "\($0.next) \($0.count)" }
                let want = t["followers"][i].array.map { "\($0[0].string!) \($0[1].double)" }
                XCTAssertEqual(got, want, "\(what): followers of \(w)")
            }
            XCTAssertEqual(U.allPairs().map { "\($0.prev) \($0.next) \($0.count)" },
                           t["all"].array.map { "\($0[0].string!) \($0[1].string!) \($0[2].double)" }, "\(what): all pairs")
        }
    }

    func testOnlyTheMostRecentAreKept() {
        let f = TestData.fixture("pairs.json")["evict"]
        let E = UserWords(starters: [])
        func letter(_ n: Int) -> String { String(UnicodeScalar(UInt8(97 + n % 26))) }
        func name(_ i: Int) -> String { "w" + letter(i) + letter(i / 26) + letter(i / 676) }
        for i in 0..<f["made"].int { E.recordPair(name(i), "next", amount: 1) }
        E.recordPair(name(7), "next", amount: 1)
        E.recordPair("one", "more", amount: 1)
        XCTAssertEqual(E.pairCount, f["count"].int)
        XCTAssertEqual(E.pairCount, MAX_PAIRS)
        let rows = pairRows(E.saved().pairs)
        let want = { (j: J) in j.array.map { "\($0[0].string!) \($0[1].string!) \($0[2].double)" } }
        XCTAssertEqual(Array(rows.prefix(3)), want(f["first"]))
        XCTAssertEqual(Array(rows.suffix(3)), want(f["last"]))
    }

    func testLoading() {
        for l in TestData.fixture("pairs.json")["loads"].array {
            let V = UserWords(starters: STARTER_BLOCKS)
            V.load(l["input"].decode(UserWords.Saved.self))
            let want = l["saved"]["pairs"].array.map { "\($0[0].string!) \($0[1].string!) \($0[2].double)" }
            XCTAssertEqual(pairRows(V.saved().pairs), want, "load \(l["input"].raw ?? "nil")")
            // And a saved copy loads back the same.
            let W = UserWords(starters: STARTER_BLOCKS)
            W.load(V.saved())
            XCTAssertEqual(pairRows(W.saved().pairs), want)
        }
    }

    func testWordBefore() {
        for c in TestData.fixture("pairs.json")["before"].array {
            let text = c[0].string!
            XCTAssertEqual(wordBefore(text, needSpace: c[1].bool), c[2].string, "wordBefore(\(text.debugDescription), \(c[1].bool))")
        }
    }

    func testLiftsInTheSwipeReaderAndSuggestions() {
        let f = TestData.fixture("pairs.json")
        let geo = geometry(f)
        let lex = TestData.lexicon(["en", "es"], users: f["users"])
        for p in f["pairsSetup"].array { lex.get("en")!.user.recordPair(p[0].string!, p[1].string!, amount: p[2].double) }
        let engine = InputEngine(target: Editor(), view: nil, lex: lex, now: { 0 })
        engine.onGeometry(geo.cx, geo.cy, geo.kw)
        engine.start(TypingSettings())
        let boost = engine.boostFor("are", "en")
        let want = f["boost"].array
        XCTAssertEqual(boost?.lang, "en")
        XCTAssertEqual(boost?.byWord.count, want.count)
        for w in want { XCTAssertTrue(close(boost?.byWord[w[0].string!] ?? -1, w[1].double), "lift for \(w[0].string!)") }
        XCTAssertNil(engine.boostFor("nothing", "en"))
        XCTAssertNil(engine.boostFor("are", "es"))
        XCTAssertNil(engine.boostFor(nil, "en"))
        for n in f["noBoost"].array { XCTAssertTrue(n.isNull) }

        let sources = TestData.sources(lex, ctx: "en")
        let dec = SwipeDecoder()
        dec.setKeyCenters(geo.cx, geo.cy, geo.kw)
        for c in f["decodes"].array {
            let xs = c["xs"].doubles
            let ys = c["ys"].doubles
            let word = c["word"].string!
            for (key, b) in [("plain", nil), ("boosted", boost)] as [(String, PairBoost?)] {
                let res = dec.decode(xs, ys, xs.count, sources, max: 8, boost: b)
                let exp = c[key].array
                XCTAssertEqual(res.map { $0.word }, exp.map { $0[0].string! }, "\(key) swipe of \(word)")
                for (r, e) in zip(res, exp) {
                    XCTAssertTrue(close(r.cost, e[1].double), "\(key) swipe of \(word): cost of \(r.word) \(r.cost) vs \(e[1].double)")
                    XCTAssertEqual(r.lang, e[2].string)
                }
            }
        }
        let sug = TypingSuggester()
        sug.setKeyCenters(geo.cx, geo.cy, geo.kw)
        for c in f["suggests"].array {
            let typed = c["typed"].string!
            // Plain, with the lifts, and with capitals-only words counted as slips.
            for (key, b, slips) in [("plain", nil, false), ("boosted", boost, false), ("slips", nil, true)] as [(String, PairBoost?, Bool)] {
                let res = sug.suggest(typed, sources, max: 8, boost: b, capsSlips: slips)
                let exp = c[key].array
                XCTAssertEqual(res.map { $0.word }, exp.map { $0[0].string! }, "\(key) suggest(\(typed))")
                for (r, e) in zip(res, exp) {
                    XCTAssertTrue(close(r.score, e[1].double), "\(key) suggest(\(typed)): score of \(r.word)")
                    XCTAssertEqual(r.kind.rawValue, e[2].int)
                    XCTAssertTrue(close(r.cost, e[3].double))
                    XCTAssertEqual(r.lang, e[4].string)
                }
            }
        }
    }
}
