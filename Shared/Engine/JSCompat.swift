// Small pieces that keep the port behaving exactly like the JavaScript engine it came from:
// string order by UTF-16 code units, Math.round, and Map's insertion order.

import Foundation

/// JS `a < b` on strings: UTF-16 code unit order (Swift's own `<` uses Unicode rules).
@inline(__always)
func jsLess(_ a: String, _ b: String) -> Bool {
    var ia = a.utf16.makeIterator()
    var ib = b.utf16.makeIterator()
    while true {
        let x = ia.next()
        let y = ib.next()
        switch (x, y) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (u?, v?):
            if u != v { return u < v }
        }
    }
}

/// JS Math.round: halves go up (toward +infinity).
@inline(__always)
func jsRound(_ x: Double) -> Double {
    if !x.isFinite { return x }
    let r = x.rounded(.down)
    return x - r >= 0.5 ? r + 1 : r
}

/// A dictionary that remembers the order keys were first added, like a JS Map.
struct OrderedDict<Key: Hashable, Value> {
    private(set) var keys: [Key] = []
    private var index: [Key: Int] = [:]
    private var values: [Value] = []

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    subscript(key: Key) -> Value? {
        get {
            guard let i = index[key] else { return nil }
            return values[i]
        }
        set {
            if let v = newValue {
                if let i = index[key] {
                    values[i] = v
                } else {
                    index[key] = keys.count
                    keys.append(key)
                    values.append(v)
                }
            } else {
                _ = removeValue(forKey: key)
            }
        }
    }

    func has(_ key: Key) -> Bool { index[key] != nil }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let i = index.removeValue(forKey: key) else { return nil }
        let v = values[i]
        keys.remove(at: i)
        values.remove(at: i)
        for j in i..<keys.count { index[keys[j]] = j }
        return v
    }

    mutating func removeAll() {
        keys.removeAll()
        index.removeAll()
        values.removeAll()
    }

    /// Values in insertion order.
    var orderedValues: [Value] { values }

    /// (key, value) pairs in insertion order.
    var pairs: [(Key, Value)] { Array(zip(keys, values)) }
}
