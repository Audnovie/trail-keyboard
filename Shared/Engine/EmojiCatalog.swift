// The emoji the panel offers, in Apple's categories and order, with English and Spanish names
// and keywords for searching. Read from Resources/Emoji/emoji.tsv (made by tools/build_emoji.py
// from emojibase-data, whose names and keywords come from Unicode CLDR).

import Foundation

public final class EmojiCatalog {
    public struct Item {
        public let emoji: String
        public let category: Int
        /// Lower case, no accents, words separated by single spaces, as UTF-8 bytes (plain ASCII
        /// in practice); each with a space in front, so " hea" finds words starting "hea".
        let english: [UInt8]
        let spanish: [UInt8]
        /// Both names and the keywords.
        let everything: [UInt8]
        /// Place among the most used emoji (lower is more used); others come after them.
        let popularity: Int
    }

    /// Apple's categories, in its order.
    public static let categories = ["Smileys & People", "Animals & Nature", "Food & Drink", "Activity",
                                    "Travel & Places", "Objects", "Symbols", "Flags"]

    public let items: [Item]
    /// For each category, the positions of its emoji in `items`.
    public let sections: [[Int]]

    /// - Parameter newest: the newest emoji version to offer (what this iPhone can draw).
    public init(text: String, newest: Double) {
        var items = [Item]()
        var sections = [[Int]](repeating: [], count: EmojiCatalog.categories.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 6, let cat = Int(f[1]), cat >= 0, cat < sections.count,
                  let version = Double(f[2]), version <= newest else { continue }
            sections[cat].append(items.count)
            let pop = f.count > 6 ? Int(f[6]) ?? Int.max : Int.max
            var en: [UInt8] = [EmojiCatalog.space]
            en.append(contentsOf: f[3].utf8)
            var es: [UInt8] = [EmojiCatalog.space]
            es.append(contentsOf: f[4].utf8)
            var everything = en
            everything.append(contentsOf: es)
            everything.append(EmojiCatalog.space)
            everything.append(contentsOf: f[5].utf8)
            items.append(Item(emoji: String(f[0]), category: cat, english: en, spanish: es,
                              everything: everything, popularity: pop))
        }
        self.items = items
        self.sections = sections
    }

    public convenience init?(path: String, newest: Double) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        self.init(text: text, newest: newest)
    }

    /// The newest emoji version an iPhone on this iOS draws (Apple adds each year's emoji in
    /// a spring update: iOS 15.4, 16.4, 17.4, 18.4, 26.4).
    public static func newestVersion(iOS v: OperatingSystemVersion) -> Double {
        func atLeast(_ major: Int, _ minor: Int) -> Bool {
            v.majorVersion > major || (v.majorVersion == major && v.minorVersion >= minor)
        }
        if atLeast(26, 4) { return 17 }
        if atLeast(18, 4) { return 16 }
        if atLeast(17, 4) { return 15.1 }
        if atLeast(16, 4) { return 15 }
        if atLeast(15, 4) { return 14 }
        return 13.1
    }

    /// What a search is compared with: lower case, no accents, words separated by spaces.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        var space = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                space = false
            } else if !space {
                out.append(" ")
                space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Emoji matching every word of the query (each as the start of a word in a name or
    /// keyword), best first: a name ending or starting with the last word typed ("heart" finds
    /// red heart before smiling face with heart-eyes), then names, then keywords; among equals,
    /// the most used emoji first, then the panel's order.
    public func search(_ query: String, limit: Int = 80) -> [String] {
        let words = EmojiCatalog.normalize(query).split(separator: " ")
        guard let lastWord = words.last else { return [] }
        // Compared as bytes: String.contains goes through Foundation and was most of the time.
        func spaced(_ w: Substring) -> [UInt8] {
            var b: [UInt8] = [EmojiCatalog.space]
            b.append(contentsOf: w.utf8)
            return b
        }
        let tokens = words.map(spaced)
        let last = spaced(lastWord)
        var ranked = [[Item]](repeating: [], count: 3)
        func all(_ text: [UInt8]) -> Bool {
            tokens.allSatisfy { EmojiCatalog.bytes(text, contain: $0) }
        }
        /// The name's first or last word is the last word typed.
        func headed(_ name: [UInt8]) -> Bool {
            let n = last.count
            guard name.count >= n else { return false }
            if name.starts(with: last) && (name.count == n || name[n] == EmojiCatalog.space) { return true }
            return name.suffix(n).elementsEqual(last)
        }
        for it in items {
            if all(it.english) {
                ranked[headed(it.english) ? 0 : 1].append(it)
            } else if all(it.spanish) {
                ranked[headed(it.spanish) ? 0 : 1].append(it)
            } else if all(it.everything) {
                ranked[2].append(it)
            }
        }
        // A stable sort keeps the panel's order among emoji equally (un)popular.
        let sorted = ranked.map { group in
            group.enumerated().sorted { ($0.element.popularity, $0.offset) < ($1.element.popularity, $1.offset) }.map { $0.element.emoji }
        }
        return Array(sorted.joined().prefix(limit))
    }

    static let space = UInt8(ascii: " ")

    /// Whether `hay` contains `needle`, byte for byte.
    static func bytes(_ hay: [UInt8], contain needle: [UInt8]) -> Bool {
        let n = needle.count
        let h = hay.count
        if n == 0 { return true }
        if n > h { return false }
        return hay.withUnsafeBufferPointer { (hp: UnsafeBufferPointer<UInt8>) -> Bool in
            needle.withUnsafeBufferPointer { (np: UnsafeBufferPointer<UInt8>) -> Bool in
                let first = np[0]
                var i = 0
                while i <= h - n {
                    if hp[i] == first {
                        var j = 1
                        while j < n && hp[i + j] == np[j] { j += 1 }
                        if j == n { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }
}
