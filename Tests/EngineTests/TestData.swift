// Loads the fixtures made by tools/fixtures/gen.js (the JavaScript engine's answers) and the
// word lists, from the repository (found from this file's path, which also works on the
// iOS Simulator since it shares the Mac's file system).

import Foundation
import XCTest
@testable import TrailEngine

enum TestData {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // EngineTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo

    static var lexiconDir: String { repoRoot.appendingPathComponent("Resources/Lexicon").path }

    static func fixture(_ name: String) -> J {
        let url = repoRoot.appendingPathComponent("Tests/EngineTests/Fixtures/\(name)")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            fatalError("can't read fixture \(url.path)")
        }
        return J(obj)
    }

    private static var loaded = [String: WordList]()
    private static let lock = NSLock()

    /// Each word list is mapped once per test run.
    static func list(_ code: String) -> WordList {
        lock.lock()
        defer { lock.unlock() }
        if let w = loaded[code] { return w }
        do {
            let w = try WordList(directory: lexiconDir, lang: code)
            loaded[code] = w
            return w
        } catch {
            fatalError("\(error)")
        }
    }

    /// A lexicon with English and Spanish loaded, `langs` switched on, and learned words from `users`.
    static func lexicon(_ langs: [String], users: J?) -> Lexicon {
        let lex = Lexicon()
        for code in ["en", "es"] {
            let L = lex.add(code)
            L.words = list(code)
            L.enabled = langs.contains(code)
            if let u = users?[code], !u.isNull { L.user.load(u.savedUserWords) }
        }
        return lex
    }

    /// Learned-word state with nothing learned yet (the starter blocks only).
    static let fresh: J = {
        let en: [String: Any] = ["learned": [Any](), "blocked": STARTER_BLOCKS]
        let es: [String: Any] = ["learned": [Any](), "blocked": ["haba", "java"]]
        let all: [String: Any] = ["en": en, "es": es]
        return J(all)
    }()

    /// Like Ime.sources in core.js for a given writing language.
    static func sources(_ lex: Lexicon, ctx: String, fixed: Bool = false) -> [Source] {
        var out = [Source]()
        for L in lex.enabled() {
            if fixed && L.code != ctx { continue }
            let S = Source(words: L.words!, user: L.user, bias: L.code == ctx ? 0 : -LANG_PENALTY, lang: L.code)
            if L.code == ctx { out.insert(S, at: 0) } else { out.append(S) }
        }
        return out
    }
}

/// A JSON value from JSONSerialization, with forgiving accessors.
struct J {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    subscript(_ key: String) -> J { J((raw as? [String: Any])?[key]) }
    subscript(_ i: Int) -> J {
        guard let a = raw as? [Any], i >= 0, i < a.count else { return J(nil) }
        return J(a[i])
    }

    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }
    var isNull: Bool { raw == nil || raw is NSNull }
    var string: String? { raw as? String }
    var double: Double { (raw as? NSNumber)?.doubleValue ?? .nan }
    var int: Int { (raw as? NSNumber)?.intValue ?? Int.min }
    var bool: Bool {
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }
    var doubles: [Double] { array.map { $0.double } }
    var ints: [Int] { array.map { $0.int } }
    var strings: [String?] { array.map { $0.string } }

    /// This value re-encoded and decoded as T (for the saved-data types).
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let r = raw, !(r is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    var savedUserWords: UserWords.Saved? { decode(UserWords.Saved.self) }
}

/// Doubles equal to within a hair (the two engines do the same arithmetic in the same order,
/// but the platforms' log() can differ in the last bit).
func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
    if a == b { return true }
    if a.isNaN || b.isNaN { return false }
    return abs(a - b) <= tol * max(1, abs(a), abs(b))
}

func geometry(_ f: J) -> (cx: [Double], cy: [Double], kw: Double) {
    (f["geometry"]["cx"].doubles, f["geometry"]["cy"].doubles, f["geometry"]["kw"].double)
}
