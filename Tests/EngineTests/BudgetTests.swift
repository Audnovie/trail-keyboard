// Speed and memory: a keyboard has to answer within a frame or two and stay well inside the
// memory iOS allows keyboards. These print what they measure, so CI logs show the numbers.

import XCTest
@testable import TrailEngine
#if canImport(Darwin)
import Darwin
#endif

/// The process's memory as iOS counts it against a keyboard (phys_footprint), in MB.
func footprintMB() -> Double {
    #if canImport(Darwin)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    #else
    return -1
    #endif
}

final class BudgetTests: XCTestCase {
    func testSpeedAndMemory() {
        let before = footprintMB()
        let f = TestData.fixture("decoder.json")
        let geo = geometry(f)
        let lex = TestData.lexicon(["en", "es"], users: f["users"])
        prepareShared(lex.enabled())
        let dec = SwipeDecoder()
        dec.setKeyCenters(geo.cx, geo.cy, geo.kw)
        let sug = TypingSuggester()
        sug.setKeyCenters(geo.cx, geo.cy, geo.kw)
        let src = TestData.sources(lex, ctx: "en")
        let cases = f["cases"].array.filter { $0["config"].string == "both-en" }

        // Warm up (first touches of the mapped word lists).
        for c in cases.prefix(3) {
            let xs = c["xs"].doubles
            _ = dec.decode(xs, c["ys"].doubles, xs.count, src, max: 8)
        }
        var worstSwipe = 0.0
        var totalSwipe = 0.0
        for c in cases {
            let xs = c["xs"].doubles
            let ys = c["ys"].doubles
            let t0 = Date()
            _ = dec.decode(xs, ys, xs.count, src, max: 8)
            let ms = Date().timeIntervalSince(t0) * 1000
            worstSwipe = max(worstSwipe, ms)
            totalSwipe += ms
        }
        var worstType = 0.0
        for typed in ["a", "s", "t", "th", "de", "qu", "helo", "thnaks", "definately", "co", "m"] {
            let t0 = Date()
            _ = sug.suggest(typed, src, max: 6)
            worstType = max(worstType, Date().timeIntervalSince(t0) * 1000)
        }
        let after = footprintMB()
        print(String(format: "BUDGET swipe: %.1f ms average, %.1f ms worst over %d swipes", totalSwipe / Double(cases.count), worstSwipe, cases.count))
        print(String(format: "BUDGET typing suggestions: %.1f ms worst", worstType))
        print(String(format: "BUDGET memory: %.1f MB before loading, %.1f MB after (phys_footprint of the test process)", before, after))
        // Generous limits: CI machines vary, and these are about catching a big regression.
        XCTAssertLessThan(worstSwipe, 250, "a swipe took too long to read")
        XCTAssertLessThan(worstType, 150, "suggestions took too long")
        if before > 0 && after > 0 {
            XCTAssertLessThan(after - before, 25, "the engine grew memory by more than 25 MB")
        }
    }

    /// Learned words beyond what the keyboard keeps still load and stay quick.
    func testManyLearnedWords() {
        let U = UserWords()
        let W = TestData.list("en")
        for i in 0..<4000 { U.recordUse(W.display((i * 13) % W.size), amount: Double(i % 7 + 1), inBaseList: true) }
        for i in 0..<300 { U.addManual("Zq" + String(repeating: "x", count: i % 20) + "word") }
        let lex = Lexicon()
        let L = lex.add("en")
        L.words = W
        L.enabled = true
        L.user.load(U.saved(maxEntries: 3000))
        XCTAssertEqual(L.user.count, 3000)
        let sug = TypingSuggester()
        let t0 = Date()
        _ = sug.suggest("th", [Source(words: W, user: L.user, bias: 0, lang: "en")], max: 6)
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "BUDGET suggestions with 3000 learned words: %.1f ms (includes building the lookup)", ms))
        XCTAssertLessThan(ms, 300)
    }
}
