// What the keyboard learns about you, per language: words you use (and how often), words you
// rejected, words you taught it, and words it must never suggest. Kept only on this iPhone,
// inside the keyboard, and shown in full in the keyboard's Learned words panel.
// Same rules as UserWords in core.js.

import Foundation

let USE_WEIGHT = 0.9
let REJECT_WEIGHT = 0.8
let MAX_REJECTS = 5
let NEW_WORD_ACTIVE_USES = 2.0
public let ADDED_WORD_ZIPF = 3.4
/// Blocked from the start in English (removable): the iPhone keyboard's favourite wrong guesses.
public let STARTER_BLOCKS = ["Java", "Cleo", "haba", "Hab's"]

public final class UserWords {
    public final class Entry {
        public let word: String
        public internal(set) var uses: Double = 0
        public internal(set) var rejects: Int = 0
        public internal(set) var added = false

        init(_ word: String) { self.word = word }

        /// Words you taught it start being suggested after two uses.
        public var active: Bool { !added || uses >= NEW_WORD_ACTIVE_USES }
    }

    public let starters: [String]
    private var entries = OrderedDict<String, Entry>()
    private var blocked = OrderedDict<String, String>()
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

    public func recordUse(_ word: String, amount: Double, inBaseList: Bool) {
        if !isLearnable(word) || isBlocked(word) { return }
        let k = word.lowercased()
        let e: Entry
        if let old = entries[k] {
            e = old
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

    public func remove(_ word: String) {
        if entries.removeValue(forKey: word.lowercased()) != nil { changed() }
    }

    public func clearLearned() {
        if !entries.isEmpty {
            entries.removeAll()
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

    // ---- saving ----

    /// The saved form: learned rows of [word, uses, rejects, added (0/1)] and the blocked words.
    /// Reading is forgiving like the JavaScript version: bad rows are skipped, not fatal.
    public struct Saved: Codable, Equatable {
        public var learned: [JSONValue]
        /// nil when the copy had no blocked list (the starter blocks apply then).
        public var blocked: [String]?

        public init(learned: [JSONValue], blocked: [String]?) {
            self.learned = learned
            self.blocked = blocked
        }

        enum CodingKeys: String, CodingKey { case learned, blocked }

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
        }
    }

    public func saved(maxEntries: Int? = nil) -> Saved {
        var list = all()
        if let m = maxEntries, m > 0, list.count > m { list = Array(list.prefix(m)) }
        return Saved(
            learned: list.map {
                .array([.string($0.word), .number(jsRound($0.uses * 10) / 10), .number(Double($0.rejects)), .number($0.added ? 1 : 0)])
            },
            blocked: blockedWords())
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
