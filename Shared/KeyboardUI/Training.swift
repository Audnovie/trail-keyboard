// Training rounds: swipe the word shown, 20 to a round. Each swipe teaches the swipe profile how
// you actually swipe (where you start and stop, which way your path drifts), and words you
// miss come back in later rounds. Ported from the Test tab of the web trial.

import UIKit
import TrailEngine

let ROUND_SIZE = 20

/// Per language: the words that matter most, tried early on.
let FIRST_WORDS: [String: [String]] = [
    "en": ["haha", "sense", "swipe", "clear", "spot", "summary"],
    "es": ["yo", "que", "jaja", "gracias", "mañana", "también"],
]

func rankOf(_ results: [SwipeResult]?, _ word: String?) -> Int {
    guard let results = results, let word = word else { return -1 }
    let w = word.lowercased()
    return results.firstIndex { $0.word.lowercased() == w } ?? -1
}

func ordinal(_ n: Int) -> String {
    let s: String
    if n % 100 >= 11 && n % 100 <= 13 { s = "th" } else {
        switch n % 10 {
        case 1: s = "st"
        case 2: s = "nd"
        case 3: s = "rd"
        default: s = "th"
        }
    }
    return "\(n)\(s)"
}

/// A word's keys in swipe order, repeats merged ("hello" -> h e l o), as 0-25.
func distinctKeys(_ word: String) -> [Int] {
    var out = [Int]()
    for b in keyOf(word).utf8 {
        let k = Int(b) - 97
        if out.last != k { out.append(k) }
    }
    return out
}

/// Plain words for a distance in key widths.
func amount(_ v: Double) -> String {
    let a = abs(v)
    if a < 0.2 { return "a little" }
    if a < 0.42 { return "about a third of a key" }
    if a < 0.62 { return "about half a key" }
    return "most of a key"
}

/// What the swipe profile has found, as short sentences.
func describeHabits(_ S: ProfileSummary) -> [String] {
    var out = [String]()
    guard S.ready, let end = S.end, let start = S.start, let overall = S.overall else { return out }
    if end.0 < -0.12 { out.append("You stop \(amount(end.0)) short of the last letter.") }
    else if end.0 > 0.12 { out.append("You go \(amount(end.0)) past the last letter.") }
    if start.0 > 0.15 { out.append("You start \(amount(start.0)) past the first letter, already heading for the next one.") }
    else if start.0 < -0.15 { out.append("You start \(amount(start.0)) before the first letter.") }
    let (ox, oy) = overall
    var dirs = [String]()
    if oy > 0.1 { dirs.append("low") } else if oy < -0.1 { dirs.append("high") }
    if ox > 0.1 { dirs.append("to the right") } else if ox < -0.1 { dirs.append("to the left") }
    if !dirs.isEmpty { out.append("Your path runs \(amount(max(abs(ox), abs(oy)))) \(dirs.joined(separator: " and ")).") }
    if !S.missedKeys.isEmpty { out.append("Letters you miss most: \(S.missedKeys.map { $0.key }.joined(separator: ", ")).") }
    if out.isEmpty { out.append("Nothing unusual so far: your swipes land close to the keys, start to finish.") }
    return out
}

final class Training {
    struct Last {
        let word: String
        let rank: Int
        let res: [SwipeResult]
        let profiled: Bool
        let rankOff: Int
        let offWord: String?
        let notes: SwipeNotes?
        let nodes: [Int32]?
    }

    private struct Done {
        let word: String
        let rank: Int
        let profile: SwipeProfile.Saved
        let round: TestStats.Round
    }

    private unowned let c: KeyboardController
    var lang = "en"
    private var queue = [String]()
    private var pos = 0
    private var history = [Done]()
    /// This sitting's results, per language.
    private var sessions = [String: (n: Int, top1: Int, top3: Int)]()
    /// Languages whose most important words were already offered this sitting.
    private var firstDone = Set<String>()
    private(set) var last: Last?
    var note: String?

    init(_ controller: KeyboardController) {
        c = controller
    }

    /// The language being tested (English when the chosen one is switched off).
    func language() -> Language {
        if let L = c.lex.get(lang), L.enabled, L.words != nil { return L }
        return c.lex.get("en")!
    }

    var sessionStats: (n: Int, top1: Int, top3: Int) { sessions[language().code] ?? (0, 0, 0) }

    private func usable(_ w: String) -> String? {
        let L = language()
        guard let W = L.words else { return nil }
        let id = W.find(w)
        if id < 0 || L.user.isBlocked(w) { return nil }
        let key = Array(W.key(id).utf8)
        var distinct = 1
        for i in 1..<max(1, key.count) where key[i] != key[i - 1] { distinct += 1 }
        if distinct < 2 { return nil }
        // Leave out words that share their letters with a commoner word ("esta" and "está"):
        // a swipe can't tell those apart, so a miss there says nothing about the swipe.
        for j in W.withKey(W.key(id)) where j != id && W.score(j) >= W.score(id) && !L.user.isBlocked(W.display(j)) {
            return nil
        }
        return W.display(id)
    }

    /// Words for the next stretch: ones using the keys (and first and last letters) the swipe
    /// profile has seen least, words you use yourself, and words you missed lately.
    private func pickWords(_ count: Int) -> [String] {
        let L = language()
        guard let W = L.words else { return [] }
        let P = c.profile()
        var seen = (0..<26).map { k -> (all: Double, first: Double, last: Double) in P.seen(k) }
        var pool = [String: (bonus: Double, keys: [Int])]()
        var order = [String]()
        func add(_ w: String, _ bonus: Double) {
            guard let u = usable(w) else { return }
            if let old = pool[u] {
                if old.bonus < bonus { pool[u] = (bonus, old.keys) }
            } else {
                pool[u] = (bonus, distinctKeys(u))
                order.append(u)
            }
        }
        var own = 0
        for e in L.user.all() {
            if own >= 60 { break }
            if e.uses >= 2 && W.find(e.word) >= 0 {
                add(e.word, 1)
                own += 1
            }
        }
        for r in c.tests.recent where (r.l ?? "en") == L.code { add(r.w, 1.5) }
        let top = min(4000, W.size)
        for _ in 0..<500 { add(W.display(Int.random(in: 0..<top)), 0) }
        var recent = Set(queue[max(0, pos - 40)...].map { $0.lowercased() })
        var picked = [String]()
        func take(_ w: String, _ keys: [Int]) {
            picked.append(w)
            recent.insert(w.lowercased())
            pool.removeValue(forKey: w)
            for k in keys { seen[k].all += 1 }
            seen[keys[0]].first += 1
            seen[keys[keys.count - 1]].last += 1
        }
        if !firstDone.contains(L.code) && P.total < 100 {
            firstDone.insert(L.code)
            for w in (FIRST_WORDS[L.code] ?? []).shuffled() {
                if let u = usable(w), picked.count < count, !recent.contains(u.lowercased()) { take(u, distinctKeys(u)) }
            }
        }
        while picked.count < count {
            var best: String?
            var bestScore = -Double.infinity
            for w in order {
                guard let e = pool[w], !recent.contains(w.lowercased()) else { continue }
                let ks = e.keys
                var need = 0.0
                for k in ks { need += 1 / (1 + seen[k].all / 5) }
                let score = e.bonus + 2 * need / Double(ks.count) + 1 / (1 + seen[ks[0]].first / 3)
                    + 1 / (1 + seen[ks[ks.count - 1]].last / 3) + Double.random(in: 0..<0.4)
                if score > bestScore {
                    bestScore = score
                    best = w
                }
            }
            guard let b = best, let e = pool[b] else { break }
            take(b, e.keys)
        }
        return picked
    }

    func build() {
        queue = pickWords(ROUND_SIZE)
        pos = 0
    }

    /// Forgets this sitting: what Undo would restore, the last swipe, and the scores.
    func reset() {
        history = []
        last = nil
        sessions = [:]
        firstDone = []
        note = nil
    }

    /// Languages were switched on or off: if the one being trained went away, go back to English.
    func rebuild() {
        let code = language().code
        if code != lang {
            lang = code
            history = []
            last = nil
            build()
        }
    }

    func setLang(_ code: String) {
        if code == language().code { return }
        lang = code
        history = []
        last = nil
        c.view.trailView.clearFades()
        build()
    }

    func current() -> String {
        if pos >= queue.count { queue.append(contentsOf: pickWords(ROUND_SIZE)) }
        return pos < queue.count ? queue[pos] : "hello"
    }

    var roundDone: Bool { c.tests.round.n >= ROUND_SIZE }

    var canUndo: Bool { !history.isEmpty }

    func nextRound() {
        if c.tests.round.n >= ROUND_SIZE { c.tests.rounds += 1 }
        c.tests.round = TestStats.Round()
        history = []
        last = nil
        note = nil
        c.view.trailView.clearFades()
        c.changed()
    }

    func onTap() {
        note = roundDone ? "Tap Next round to keep going." : "Taps don’t count here. Swipe the word."
    }

    func onSwipe(_ xs: [Double], _ ys: [Double]) {
        let dec = c.engine.decoder
        guard dec.ready else { return }
        if roundDone {
            note = "Tap Next round to keep going."
            return
        }
        note = nil
        let target = current()
        let lang = language().code
        let sources = c.engine.sources(lang)
        let P = c.profile()
        let profiled = c.settings.useProfile && P.ready
        let res = dec.decode(xs, ys, xs.count, sources, max: 8)
        var resOff: [SwipeResult]?
        if profiled {
            // What it would have been without your profile, for a fair comparison.
            dec.setProfile(nil)
            resOff = dec.decode(xs, ys, xs.count, sources, max: 8)
            c.applyProfile()
        }
        let rank = rankOf(res, target)
        let rankOff = resOff.map { rankOf($0, target) } ?? rank
        var s = sessions[lang] ?? (0, 0, 0)
        s.n += 1
        c.tests.n += 1
        if rank == 0 {
            s.top1 += 1
            c.tests.top1 += 1
        }
        if rank >= 0 && rank < 3 {
            s.top3 += 1
            c.tests.top3 += 1
        }
        sessions[lang] = s
        if rank != 0 {
            c.tests.recent.insert(TestStats.Miss(w: target, g: res.first?.word ?? "", r: rank, m: "t", l: lang), at: 0)
            if c.tests.recent.count > 40 { c.tests.recent.removeLast(c.tests.recent.count - 40) }
        }
        // Learn how you swipe from it (only after reading it, so the comparison above is fair).
        let before = Done(word: target, rank: rank, profile: P.saved(), round: c.tests.round)
        let al = dec.align(target, xs, ys, xs.count)
        let notes = al.map { P.learn($0) }
        c.tests.round.n += 1
        if rank == 0 { c.tests.round.top1 += 1 }
        if profiled {
            P.ab.n += 1
            c.tests.round.ab += 1
            if rank == 0 {
                P.ab.on += 1
                c.tests.round.on += 1
            }
            if rankOff == 0 {
                P.ab.off += 1
                c.tests.round.off += 1
            }
        }
        c.applyProfile()
        history.append(before)
        if history.count > 50 { history.removeFirst() }
        last = Last(word: target, rank: rank, res: Array(res.prefix(3)), profiled: profiled, rankOff: rankOff,
                    offWord: resOff?.first?.word, notes: notes, nodes: al?.nodes)
        showTrails(xs, ys, target)
        pos += 1
        c.changed()
    }

    private func showTrails(_ xs: [Double], _ ys: [Double], _ target: String) {
        let t = c.view.trailView
        let th = c.view.theme
        t.fade(zip(xs, ys).map { CGPoint(x: $0, y: $1) }, color: th.accent, alpha: 0.55, hold: 1.0, duration: 0.45)
        let ideal = distinctKeys(target).compactMap { c.view.center(of: $0) }
        t.fade(ideal, color: th.ghost, width: 4, alpha: 0.9, hold: 1.0, duration: 0.45, dash: [1, 9])
        for k in flagged() {
            if let p = c.view.center(of: k) { t.ring(p, radius: c.view.keyUnit * 0.42, color: th.bad, hold: 1.0, duration: 0.45) }
        }
    }

    /// Keys of the last swipe's letters that it missed or stopped short of.
    func flagged() -> [Int] {
        guard let L = last, let notes = L.notes, let nodes = L.nodes else { return [] }
        let t = nodes.count
        var out = notes.missed.map { Int(nodes[$0]) }
        if notes.endAlong < -0.35 && !notes.missed.contains(t - 1) { out.append(Int(nodes[t - 1])) }
        return out
    }

    /// One line about the last swipe: what your profile changed, and where the path strayed.
    func habitText() -> String {
        guard let L = last else { return "" }
        var parts = [String]()
        if L.profiled && L.rank == 0 && L.rankOff != 0 {
            parts.append("Your swipe profile got this one right" + (L.offWord.map { " (without it: “\($0)”)." } ?? "."))
        } else if L.profiled && L.rank != 0 && L.rankOff == 0 {
            parts.append("Without your swipe profile this would have been right.")
        }
        if let notes = L.notes, let nodes = L.nodes {
            let t = nodes.count
            func name(_ i: Int) -> String { "“" + String(UnicodeScalar(UInt8(97 + Int(nodes[i])))) + "”" }
            var bits = [String]()
            let mid = notes.missed.filter { $0 > 0 && $0 < t - 1 }
            if !mid.isEmpty { bits.append("missed " + mid.map(name).joined(separator: " and ")) }
            if notes.endAlong < -0.35 { bits.append("stopped short of " + name(t - 1)) }
            else if notes.endAlong > 0.5 { bits.append("went past " + name(t - 1)) }
            else if notes.missed.contains(t - 1) { bits.append("ended off " + name(t - 1)) }
            if notes.missed.contains(0) { bits.append("started off " + name(0)) }
            if !bits.isEmpty { parts.append("Your path " + bits.joined(separator: ", ") + ".") }
        }
        return parts.joined(separator: " ")
    }

    func skip() {
        if roundDone { return }
        pos += 1
        last = nil
        note = nil
    }

    func undo() {
        guard let h = history.popLast() else { return }
        let code = language().code
        var s = sessions[code] ?? (0, 0, 0)
        s.n = max(0, s.n - 1)
        c.tests.n = max(0, c.tests.n - 1)
        if h.rank == 0 {
            s.top1 = max(0, s.top1 - 1)
            c.tests.top1 = max(0, c.tests.top1 - 1)
        }
        if h.rank >= 0 && h.rank < 3 {
            s.top3 = max(0, s.top3 - 1)
            c.tests.top3 = max(0, c.tests.top3 - 1)
        }
        sessions[code] = s
        if h.rank != 0, let i = c.tests.recent.firstIndex(where: { $0.m == "t" && $0.w == h.word && $0.r == h.rank }) {
            c.tests.recent.remove(at: i)
        }
        // Forget it in the swipe profile and the round too.
        c.profile().load(h.profile)
        c.tests.round = h.round
        c.applyProfile()
        queue.insert(h.word, at: min(pos, queue.count))
        last = nil
        c.view.trailView.clearFades()
        note = "Removed. Try it again."
        c.changed()
    }
}
