// What the keyboard learns about you, per language: words you use (and how often), words you
// rejected, words you taught it, words it must never suggest, and word pairs (which word you
// write after which). Kept only on this iPhone, inside the keyboard, and shown in full in the
// keyboard's Learned words and Word pairs panels. Same rules as UserWords in core.js.

import Foundation

let USE_WEIGHT = 0.9
let REJECT_WEIGHT = 0.8
let MAX_REJECTS = 5
let NEW_WORD_ACTIVE_USES = 2.0
public let ADDED_WORD_ZIPF = 3.4
/// Blocked from the start in English (removable): the iPhone keyboard's favourite wrong guesses.
public let STARTER_BLOCKS = ["Java", "Cleo", "haba", "Hab's"]
/// Word pairs: a word you've written after the one before the cursor is lifted by
/// PAIR_WEIGHT * ln(1 + times), at most PAIR_MAX_BONUS (zipf units); this many pairs are kept.
let PAIR_WEIGHT = 0.7
let PAIR_MAX_BONUS = 2.0
public let MAX_PAIRS = 2000

/// A word as one side of a pair: lower case, straight apostrophes.
public func pairForm(_ word: String) -> String {
    word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
}

func pairBonusOf(_ count: Double) -> Double {
    min(PAIR_MAX_BONUS, PAIR_WEIGHT * log(1 + count))
}

/// The word right before the end of `text` (in pair form), or nil when there's none or something
/// other than spaces comes between (punctuation and new lines end a pair). Same as core.js.
/// - Parameter needSpace: the word must be followed by at least one space.
public func wordBefore(_ text: String, needSpace: Bool) -> String? {
    let u = Array(text.utf16)
    var end = u.count
    while end > 0 && u[end - 1] == 0x20 { end -= 1 }
    if needSpace && end == u.count { return nil }
    var start = end
    while start > 0 {
        let c = u[start - 1]
        if !isLetterUnit(c) && c != 0x27 && c != 0x2019 { break }
        start -= 1
    }
    // Letters stuck to a number ("5th") aren't a word.
    if start > 0 && u[start - 1] >= 0x30 && u[start - 1] <= 0x39 { return nil }
    while start < end && (u[start] == 0x27 || u[start] == 0x2019) { start += 1 }
    while end > start && (u[end - 1] == 0x27 || u[end - 1] == 0x2019) { end -= 1 }
    let w = String(decoding: u[start..<end], as: UTF16.self)
    return isLearnable(w) ? pairForm(w) : nil
}

public final class UserWords {
    public final class Entry {
        public internal(set) var word: String
        public internal(set) var uses: Double = 0
        public internal(set) var rejects: Int = 0
        public internal(set) var added = false

        init(_ word: String) { self.word = word }

        /// Words you taught it start being suggested after two uses.
        public var active: Bool { !added || uses >= NEW_WORD_ACTIVE_USES }
    }

    /// You wrote `next` right after `prev` (pair form) this many times.
    public final class Pair {
        public let prev: String
        public let next: String
        public internal(set) var count: Double

        init(prev: String, next: String, count: Double) {
            self.prev = prev
            self.next = next
            self.count = count
        }
    }

    public let starters: [String]
    private var entries = OrderedDict<String, Entry>()
    private var blocked = OrderedDict<String, String>()
    /// "prev next" -> pair, least recently used first.
    private var pairs = OrderedDict<String, Pair>()
    public private(set) var version = 0
    public var onChange: (() -> Void)?
    /// Per word list (by uid): the bonus and blocked lookups by word id, for this version.
    var indexCache = [Int: (version: Int, index: UserIndex)]()

    public init(starters: [String]? = nil) {
        self.starters = starters ?? STARTER_BLOCKS
        for w in self.starters { blocked[w.lowercased()] = w }
    }

    private func changed() {
        version += 1
        onChange?()
    }

    /// Personal adjustment in zipf units: up for words you use, down for ones you rejected.
    public func bonus(_ word: String) -> Double {
        guard let e = entries[word.lowercased()] else { return 0 }
        return USE_WEIGHT * log(1 + e.uses) - REJECT_WEIGHT * Double(min(e.rejects, MAX_REJECTS))
    }

    public func isBlocked(_ word: String) -> Bool { blocked.has(word.lowercased()) }

    public func get(_ word: String) -> Entry? { entries[word.lowercased()] }

    /// - Parameter keepForm: keep this spelling (you put it back after a fix: "ios", not "iOS").
    public func recordUse(_ word: String, amount: Double, inBaseList: Bool, keepForm: Bool = false) {
        if !isLearnable(word) || isBlocked(word) { return }
        let k = word.lowercased()
        let e: Entry
        if let old = entries[k] {
            e = old
            if keepForm { e.word = word }
        } else {
            e = Entry(word)
            e.added = !inBaseList
            entries[k] = e
        }
        e.uses = min(e.uses + amount, 100000)
        if e.rejects > 0 && amount >= 2 { e.rejects -= 1 }
        changed()
    }

    public func recordReject(_ word: String) {
        if !isLearnable(word) { return }
        let k = word.lowercased()
        let e: Entry
        if let old = entries[k] {
            e = old
        } else {
            e = Entry(word)
            entries[k] = e
        }
        if e.rejects < MAX_REJECTS { e.rejects += 1 }
        e.uses = max(0, e.uses - 1)
        changed()
    }

    @discardableResult
    public func addManual(_ raw: String) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isLearnable(word) { return false }
        let k = word.lowercased()
        blocked.removeValue(forKey: k)
        let e: Entry
        if let old = entries[k] {
            e = old
        } else {
            e = Entry(word)
            e.added = true
            entries[k] = e
        }
        e.uses = max(e.uses, NEW_WORD_ACTIVE_USES)
        e.rejects = 0
        changed()
        return true
    }

    public func setInBaseList(_ word: String, _ inBase: Bool) {
        if let e = entries[word.lowercased()], e.added == inBase {
            e.added = !inBase
            changed()
        }
    }

    /// Forgets the word, and the word pairs it's in.
    public func remove(_ word: String) {
        let gone = entries.removeValue(forKey: word.lowercased()) != nil
        let f = pairForm(word)
        let pairsGone = pairs.removeAll { _, p in p.prev == f || pairForm(p.next) == f }
        if gone || pairsGone { changed() }
    }

    /// Forgets every learned word, and the word pairs with them.
    public func clearLearned() {
        if !entries.isEmpty || !pairs.isEmpty {
            entries.removeAll()
            pairs.removeAll()
            changed()
        }
    }

    public func block(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty { return }
        blocked[word.lowercased()] = word
        entries.removeValue(forKey: word.lowercased())
        changed()
    }

    public func unblock(_ word: String) {
        if blocked.removeValue(forKey: word.lowercased()) != nil { changed() }
    }

    public func blockedWords() -> [String] {
        blocked.pairs.sorted { jsLess($0.0, $1.0) }.map { $0.1 }
    }

    /// Everything learned, most used first.
    public func all() -> [Entry] {
        entries.orderedValues.sorted { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            return jsLess(a.word.lowercased(), b.word.lowercased())
        }
    }

    /// Words you taught it that are ready to be suggested, in the order they were learned.
    public func activeAdded() -> [Entry] {
        entries.orderedValues.filter { $0.added && $0.active && !keyOf($0.word).isEmpty }
    }

    /// Every entry in the order it was first learned.
    public var entriesInOrder: [Entry] { entries.orderedValues }

    public var count: Int { entries.count }

    // ---- word pairs: which word you write after which ----

    private static func pairKey(_ prev: String, _ next: String) -> String { pairForm(prev) + " " + pairForm(next) }

    /// You wrote `next` right after `prev` (amount 2 when you picked it over a wrong guess).
    public func recordPair(_ prev: String, _ next: String, amount: Double) {
        if !isLearnable(prev) || !isLearnable(next) || isBlocked(next) { return }
        let k = UserWords.pairKey(prev, next)
        let p = pairs.removeValue(forKey: k) ?? Pair(prev: pairForm(prev), next: next, count: 0)
        p.count = min(p.count + amount, 100000)
        pairs[k] = p
        while pairs.count > MAX_PAIRS, let oldest = pairs.keys.first { pairs.removeValue(forKey: oldest) }
        changed()
    }

    /// `next` after `prev` was a wrong guess: count it once less (gone at nothing).
    public func weakenPair(_ prev: String, _ next: String) {
        let k = UserWords.pairKey(prev, next)
        guard let p = pairs[k] else { return }
        p.count -= 1
        if p.count <= 0 { pairs.removeValue(forKey: k) }
        changed()
    }

    public func forgetPair(_ prev: String, _ next: String) {
        if pairs.removeValue(forKey: UserWords.pairKey(prev, next)) != nil { changed() }
    }

    public func clearPairs() {
        if !pairs.isEmpty {
            pairs.removeAll()
            changed()
        }
    }

    /// Words you've written after `prev`, most often first (then most recently).
    public func followers(_ prev: String) -> [Pair] {
        let a = pairForm(prev)
        var list = [(p: Pair, i: Int)]()
        for (i, p) in pairs.orderedValues.enumerated() where p.prev == a { list.append((p, i)) }
        list.sort { x, y in x.p.count != y.p.count ? x.p.count > y.p.count : x.i > y.i }
        return list.map { $0.p }
    }

    /// Every pair, most used first (then alphabetically).
    public func allPairs() -> [Pair] {
        pairs.orderedValues.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return jsLess(a.prev + " " + pairForm(a.next), b.prev + " " + pairForm(b.next))
        }
    }

    public var pairCount: Int { pairs.count }

    // ---- saving ----

    /// The saved form: learned rows of [word, uses, rejects, added (0/1)], the blocked words, and
    /// word pairs as [prev, next, times] rows, least recently used first. Reading is forgiving like
    /// the JavaScript version: bad rows are skipped, not fatal.
    public struct Saved: Codable, Equatable {
        public var learned: [JSONValue]
        /// nil when the copy had no blocked list (the starter blocks apply then).
        public var blocked: [String]?
        public var pairs: [JSONValue]

        public init(learned: [JSONValue], blocked: [String]?, pairs: [JSONValue] = []) {
            self.learned = learned
            self.blocked = blocked
            self.pairs = pairs
        }

        enum CodingKeys: String, CodingKey { case learned, blocked, pairs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if case .array(let rows)? = try? c.decode(JSONValue.self, forKey: .learned) {
                learned = rows
            } else {
                learned = []
            }
            if case .array(let items)? = try? c.decode(JSONValue.self, forKey: .blocked) {
                blocked = items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            } else {
                blocked = nil
            }
            if case .array(let rows)? = try? c.decode(JSONValue.self, forKey: .pairs) {
                pairs = rows
            } else {
                pairs = []
            }
        }
    }

    public func saved(maxEntries: Int? = nil) -> Saved {
        var list = all()
        if let m = maxEntries, m > 0, list.count > m { list = Array(list.prefix(m)) }
        return Saved(
            learned: list.map {
                .array([.string($0.word), .number(jsRound($0.uses * 10) / 10), .number(Double($0.rejects)), .number($0.added ? 1 : 0)])
            },
            blocked: blockedWords(),
            pairs: pairs.orderedValues.map { .array([.string($0.prev), .string($0.next), .number(jsRound($0.count * 10) / 10)]) })
    }

    /// Replaces everything with a saved copy. A copy with no blocked list gets the starter blocks.
    public func load(_ data: Saved?) {
        entries.removeAll()
        blocked.removeAll()
        for item in data?.learned ?? [] {
            guard case .array(let row) = item, row.count >= 1, case .string(let word) = row[0], isLearnable(word) else { continue }
            let e = Entry(word)
            e.uses = row.count > 1 ? row[1].jsNumberOrZero : 0
            let r = row.count > 2 ? row[2].jsNumberOrZero : 0
            e.rejects = Int(max(0, min(Double(MAX_REJECTS), r)))
            e.added = row.count > 3 ? (row[3] == .number(1) || row[3] == .bool(true)) : false
            entries[word.lowercased()] = e
        }
        if let list = data?.blocked {
            for w in list {
                let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { blocked[t.lowercased()] = t }
            }
        } else {
            for w in starters { blocked[w.lowercased()] = w }
        }
        pairs.removeAll()
        for item in data?.pairs ?? [] {
            guard case .array(let row) = item, row.count >= 2, case .string(let a) = row[0], case .string(let b) = row[1],
                  isLearnable(a), isLearnable(b) else { continue }
            let count = min(row.count > 2 ? row[2].jsNumberOrZero : 0, 100000)
            if !(count > 0) { continue }
            let k = UserWords.pairKey(a, b)
            pairs.removeValue(forKey: k)
            pairs[k] = Pair(prev: pairForm(a), next: b, count: count)
        }
        while pairs.count > MAX_PAIRS, let oldest = pairs.keys.first { pairs.removeValue(forKey: oldest) }
        version += 1
    }
}

/// Any JSON value, for reading saved data forgivingly.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// JS `Number(v) || 0`.
    var jsNumberOrZero: Double {
        let n: Double
        switch self {
        case .number(let x): n = x
        case .bool(let b): n = b ? 1 : 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            n = t.isEmpty ? 0 : (Double(t) ?? .nan)
        case .null: n = 0
        case .array, .object: n = .nan
        }
        return n.isNaN ? 0 : n
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
