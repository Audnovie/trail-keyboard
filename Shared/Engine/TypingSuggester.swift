// Suggestions while you tap out a word: the word itself, words it starts, and (when it isn't a
// word) close spellings, with a neighbouring key counting as half a mistake. Same as core.js.

import Foundation

public enum SuggestionKind: Int {
    case exact = 0
    case completion = 1
    case correction = 2
}

public struct Suggestion: Equatable {
    public let word: String
    public let score: Double
    public let kind: SuggestionKind
    public let cost: Double
    public let lang: String?
}

public final class TypingSuggester {
    private var keyDist = [Double](repeating: 0, count: 676)
    public private(set) var hasGeometry = false
    private var buf = [Double](repeating: 0, count: 32 * 32)

    public init() {}

    public func setKeyCenters(_ x: [Double], _ y: [Double], _ keyWidth: Double) {
        for a in 0..<26 {
            for b in 0..<26 {
                let dx = (x[a] - x[b]) / keyWidth
                let dy = (y[a] - y[b]) / keyWidth
                keyDist[a * 26 + b] = (dx * dx + dy * dy).squareRoot()
            }
        }
        hasGeometry = true
    }

    @inline(__always) private func subCost(_ a: UInt8, _ b: UInt8) -> Double {
        if a == b { return 0 }
        let ia = Int(a) - 97
        let ib = Int(b) - 97
        if !hasGeometry || ia < 0 || ia >= 26 || ib < 0 || ib >= 26 { return 1 }
        return keyDist[ia * 26 + ib] <= 1.25 ? 0.5 : 1
    }

    /// Weighted Damerau-Levenshtein distance; a neighbouring key costs half. Gives up above limit.
    func editCost(_ typed: [UInt8], _ cand: UnsafeBufferPointer<UInt8>, _ limit: Double) -> Double {
        let n = typed.count
        let m = cand.count
        let w = m + 1
        if buf.count < (n + 1) * w { buf = [Double](repeating: 0, count: (n + 1) * w * 2) }
        return buf.withUnsafeMutableBufferPointer { d -> Double in
            for i in 0...n { d[i * w] = Double(i) * 0.8 }
            for j in 0...m { d[j] = Double(j) * 0.8 }
            if n == 0 { return d[n * w + m] }
            for i in 1...n {
                var rowMin = Double.infinity
                let a = typed[i - 1]
                if m >= 1 {
                    for j in 1...m {
                        let b = cand[j - 1]
                        var v = Swift.min(d[(i - 1) * w + j - 1] + subCost(a, b),
                                          Swift.min(d[(i - 1) * w + j] + 0.8, d[i * w + j - 1] + 0.8))
                        if i > 1 && j > 1 && a == cand[j - 2] && typed[i - 2] == b {
                            v = Swift.min(v, d[(i - 2) * w + j - 2] + 0.7)
                        }
                        d[i * w + j] = v
                        if v < rowMin { rowMin = v }
                    }
                }
                if rowMin > limit { return .infinity }
            }
            return d[n * w + m]
        }
    }

    func editCost(_ typed: String, _ cand: String, _ limit: Double) -> Double {
        let c = Array(cand.utf8)
        return c.withUnsafeBufferPointer { editCost(Array(typed.utf8), $0, limit) }
    }

    private struct Best {
        var word: String
        var score: Double
        var kind: SuggestionKind
        var cost: Double
        var lang: String
    }

    /// Ranked suggestions for a word in progress, best first, never blocked words.
    public func suggest(_ typed: String, _ sources: [Source], max: Int) -> [Suggestion] {
        let key = keyOf(typed)
        if key.isEmpty { return [] }
        let keyBytes = Array(key.utf8)
        let P = primaryOf(sources)
        var best = OrderedDict<String, Best>()

        func add(_ word: String, _ score: Double, _ kind: SuggestionKind, _ cost: Double, _ lang: String) {
            let k = word.lowercased()
            if let old = best[k], !(old.score < score) { return }
            best[k] = Best(word: word, score: score, kind: kind, cost: cost, lang: lang)
        }

        var exact = false
        for S in sources {
            let W = S.words
            let user = S.user
            let bias = S.bias
            let foreign = isForeign(S, P)
            let index = SourceIndex(S, P)
            let shared: SharedMap? = foreign ? sharedWith(W, P!.words) : nil
            for id in W.withKey(key) {
                if let sh = shared, sh[id] { continue }
                exact = true
                if index.blocked(id) { continue }
                add(W.display(id), Double(W.score(id)) / 100 + bias + index.bonus(id) + 2, .exact, 0, S.lang)
            }
            let range = W.prefixRange(key)
            var scanned = 0
            var pos = range.lowerBound
            while pos < range.upperBound && scanned < 8000 {
                defer {
                    pos += 1
                    scanned += 1
                }
                let id = W.sortedId(pos)
                let kl = W.keyLength(id)
                if kl == keyBytes.count { continue }
                if let sh = shared, sh[id] { continue }
                if index.blocked(id) { continue }
                let extra = Double(kl - keyBytes.count)
                add(W.display(id), Double(W.score(id)) / 100 + bias + index.bonus(id) - 0.4 - 0.05 * extra, .completion, 0, S.lang)
            }
            for e in user.activeAdded() {
                if foreign && P!.words.find(e.word) >= 0 { continue }
                let k = keyOf(e.word)
                if k == key {
                    exact = true
                    if blockedIn(S, P, e.word) { continue }
                    add(e.word, ADDED_WORD_ZIPF + bias + bonusIn(S, P, e.word) + 2, .exact, 0, S.lang)
                } else if k.hasPrefix(key) {
                    if blockedIn(S, P, e.word) { continue }
                    add(e.word, ADDED_WORD_ZIPF + bias + bonusIn(S, P, e.word) - 0.4, .completion, 0, S.lang)
                }
            }
        }
        // Typo fixes, only when what you typed isn't a word in any of them.
        if !exact && keyBytes.count >= 2 {
            let limit = keyBytes.count <= 4 ? 1.0 : 2.0
            let first = Int(keyBytes[0]) - 97
            for S in sources {
                let W = S.words
                let bias = S.bias
                let index = SourceIndex(S, P)
                let shared: SharedMap? = isForeign(S, P) ? sharedWith(W, P!.words) : nil
                for f in 0..<26 {
                    if f != first && (!hasGeometry || keyDist[first * 26 + f] > 1.25) { continue }
                    for id32 in W.withFirst(f) {
                        let id = Int(id32)
                        if let sh = shared, sh[id] { continue }
                        let k = W.keyBytes(id)
                        if abs(k.count - keyBytes.count) > 2 { continue }
                        let cost = editCost(keyBytes, k, limit)
                        if cost > limit { continue }
                        if index.blocked(id) { continue }
                        add(W.display(id), Double(W.score(id)) / 100 + bias + index.bonus(id) - 1.5 * cost, .correction, cost, S.lang)
                    }
                }
            }
        }
        let values = best.orderedValues
        let order = values.indices.sorted { a, b in
            values[a].score > values[b].score || (values[a].score == values[b].score && a < b)
        }
        var out = [Suggestion]()
        for i in order.prefix(max) {
            let v = values[i]
            out.append(Suggestion(word: v.word, score: v.score, kind: v.kind, cost: v.cost, lang: v.lang))
        }
        return out
    }
}
