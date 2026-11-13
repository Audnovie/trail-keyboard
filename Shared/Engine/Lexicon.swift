// The languages the keyboard knows, and how their words are weighed against each other while
// you write in one of them. Same rules as core.js (Lexicon, sources, detectLang).

import Foundation

public struct LangInfo {
    public let code: String
    public let name: String
    public let short: String
    public let starters: [String]
}

public let LANG_INFO: [String: LangInfo] = [
    "en": LangInfo(code: "en", name: "English", short: "EN", starters: STARTER_BLOCKS),
    "es": LangInfo(code: "es", name: "Español", short: "ES", starters: ["haba", "java"]),
]

/// While you write in one language, words from the others count as this much rarer, in zipf
/// units (1 = ten times rarer). They can still win when your swipe clearly fits them.
public let LANG_PENALTY = 1.5

/// One language: its word list (once loaded) and what it has learned.
public final class Language {
    public let code: String
    public let name: String
    public let short: String
    public var words: WordList?
    public let user: UserWords
    public var enabled = false

    init(code: String) {
        let info = LANG_INFO[code] ?? LangInfo(code: code, name: code, short: code.uppercased(), starters: [])
        self.code = code
        name = info.name
        short = info.short
        user = UserWords(starters: info.starters)
    }
}

public final class Lexicon {
    public private(set) var langs: [Language] = []

    public init() {}

    @discardableResult
    public func add(_ code: String) -> Language {
        let L = Language(code: code)
        langs.append(L)
        return L
    }

    public func get(_ code: String?) -> Language? {
        guard let code = code else { return nil }
        return langs.first { $0.code == code }
    }

    /// Languages that are switched on and whose word list is loaded.
    public func enabled() -> [Language] {
        langs.filter { $0.enabled && $0.words != nil }
    }
}

/// Where words come from for one swipe or one word typed: a language's list and learned words,
/// with `bias` added to every word's frequency (0 for the language you're writing in).
public final class Source {
    public let words: WordList
    public let user: UserWords
    public let bias: Double
    public let lang: String

    public init(words: WordList, user: UserWords, bias: Double, lang: String) {
        self.words = words
        self.user = user
        self.bias = bias
        self.lang = lang
    }
}

/// The source for the language you're writing in, or nil.
func primaryOf(_ sources: [Source]) -> Source? {
    guard let P = sources.first else { return nil }
    return P.bias < 0 ? nil : P
}

/// A source for a language you're not writing in right now.
@inline(__always)
func isForeign(_ S: Source, _ P: Source?) -> Bool {
    guard let P = P else { return false }
    return S !== P && S.bias < 0
}

/// What you've done with a word, in zipf units, for one source. For a language you're not
/// writing in only the minuses count, from that language or the one you are writing in:
/// using "yo" a lot in Spanish shouldn't make it come up while you write English.
func bonusIn(_ S: Source, _ P: Source?, _ word: String) -> Double {
    guard let P = P, isForeign(S, P) else { return S.user.bonus(word) }
    var b = min(0, S.user.bonus(word))
    b += min(0, P.user.bonus(word))
    return b
}

/// Blocked in the word's own language, or (for another language's word) in the one you're writing in.
func blockedIn(_ S: Source, _ P: Source?, _ word: String) -> Bool {
    if S.user.isBlocked(word) { return true }
    guard let P = P else { return false }
    return isForeign(S, P) && P.user.isBlocked(word)
}

/// The same two questions for a word of S's list by id, answered from per-list indexes so the
/// swipe reader doesn't build a string for each of thousands of candidates.
final class SourceIndex {
    let S: Source
    let P: Source?
    let foreign: Bool
    private let own: UserIndex
    private let primary: UserIndex?

    init(_ S: Source, _ P: Source?) {
        self.S = S
        self.P = P
        foreign = isForeign(S, P)
        own = UserIndex.of(S.words, S.user)
        primary = foreign && P != nil ? UserIndex.of(S.words, P!.user) : nil
    }

    @inline(__always) func bonus(_ id: Int) -> Double {
        if !foreign { return own.bonus[Int32(id)] ?? 0 }
        var b = min(0, own.bonus[Int32(id)] ?? 0)
        b += min(0, primary?.bonus[Int32(id)] ?? 0)
        return b
    }

    @inline(__always) func blocked(_ id: Int) -> Bool {
        if own.blocked.contains(Int32(id)) { return true }
        return foreign && (primary?.blocked.contains(Int32(id)) ?? false)
    }
}

/// For one word list and one language's learned words: the bonus and blocked state of each
/// list word that has one (looked up by spelling ignoring case, as UserWords does).
final class UserIndex {
    let bonus: [Int32: Double]
    let blocked: Set<Int32>

    private init(_ W: WordList, _ U: UserWords) {
        var b = [Int32: Double]()
        for e in U.entriesInOrder {
            let lower = e.word.lowercased()
            let value = U.bonus(e.word)
            for id in UserIndex.ids(W, lower) { b[Int32(id)] = value }
        }
        var s = Set<Int32>()
        for w in U.blockedWords() {
            for id in UserIndex.ids(W, w.lowercased()) { s.insert(Int32(id)) }
        }
        bonus = b
        blocked = s
    }

    /// Ids of list words whose spelling, ignoring case, is `lower`.
    private static func ids(_ W: WordList, _ lower: String) -> [Int] {
        let key = keyOf(lower)
        if key.isEmpty { return [] }
        return W.withKey(key).filter { W.display($0).lowercased() == lower }
    }

    static func of(_ W: WordList, _ U: UserWords) -> UserIndex {
        if let hit = U.indexCache[W.uid], hit.version == U.version { return hit.index }
        let made = UserIndex(W, U)
        U.indexCache[W.uid] = (U.version, made)
        return made
    }
}

/// Which words of list W the language you're writing in (list P) also has, spelled the same.
/// While you write P's language those count as P's words, at P's frequency, so W's copy is
/// left out: "yo" stays rare in English even though it's common in Spanish.
func sharedWith(_ W: WordList, _ P: WordList) -> SharedMap {
    W.shared(with: P)
}

/// Works out the shared words for every pair of these languages now, rather than on the first swipe.
public func prepareShared(_ langs: [Language]) {
    for A in langs {
        for B in langs where A !== B {
            if let a = A.words, let b = B.words { _ = sharedWith(b, a) }
        }
    }
}

/// How strongly a word says "this language": its zipf frequency there, or low if unknown.
func wordEvidence(_ L: Language, _ w: String) -> Double {
    guard let W = L.words else { return 1.0 }
    let id = W.find(w)
    if id >= 0 { return Double(W.score(id)) / 100 }
    if let e = L.user.get(w), e.uses > 0 { return ADDED_WORD_ZIPF }
    let key = keyOf(w)
    if !key.isEmpty {
        var best = 0.0
        for j in W.withKey(key) { best = max(best, Double(W.score(j)) / 100) }
        if best > 0 { return best - 0.5 } // typed without its accents
    }
    return 1.0
}

/// Words in a line: runs of letters and apostrophes (JS /[\p{L}'’]+/gu).
func wordTokens(_ line: String) -> [String] {
    var out = [String]()
    var cur = String.UnicodeScalarView()
    for s in line.unicodeScalars {
        if isLetterScalar(s) || s == "'" || s == "\u{2019}" {
            cur.append(s)
        } else if !cur.isEmpty {
            out.append(String(cur))
            cur = String.UnicodeScalarView()
        }
    }
    if !cur.isEmpty { out.append(String(cur)) }
    return out
}

/// The language of the last few words before the cursor (in the current line), or nil when
/// they don't clearly favour one. Recent words count most.
public func detectLang(_ text: String, _ langs: [Language]) -> String? {
    if langs.count < 2 { return langs.first?.code }
    // The current line (JS lastIndexOf('\n'), which also splits "\r\n").
    var line = text
    if let nl = text.utf16.lastIndex(of: 10) {
        line = String(decoding: text.utf16[text.utf16.index(after: nl)...], as: UTF16.self)
    }
    let tokens = wordTokens(line)
    if tokens.isEmpty { return nil }
    let recent = tokens.suffix(8)
    var scores = [Double](repeating: 0, count: langs.count)
    var weight = 1.0
    for t in recent.reversed() {
        for i in 0..<langs.count { scores[i] += weight * wordEvidence(langs[i], t) }
        weight *= 0.85
    }
    var best = 0
    for i in 1..<langs.count where scores[i] > scores[best] { best = i }
    var second = -Double.infinity
    for i in 0..<langs.count where i != best { second = max(second, scores[i]) }
    return scores[best] - second >= 1.0 ? langs[best].code : nil
}
