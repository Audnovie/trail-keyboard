// The emoji the panel offers, in Apple's categories and order, with English and Spanish names
// and keywords for searching. Read from Resources/Emoji/emoji.tsv (made by tools/build_emoji.py
// from emojibase-data, whose names and keywords come from Unicode CLDR).

import Foundation

public final class EmojiCatalog {
    public struct Item {
        public let emoji: String
        public let category: Int
        /// Lower case, no accents, words separated by single spaces.
        let english: String
        let spanish: String
        let keywords: String
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
            items.append(Item(emoji: String(f[0]), category: cat, english: String(f[3]), spanish: String(f[4]),
                              keywords: String(f[5]), popularity: pop))
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
        let q = EmojiCatalog.normalize(query)
        let tokens = q.split(separator: " ").map { " " + $0 }
        guard let last = q.split(separator: " ").last.map(String.init) else { return [] }
        var ranked = [[Item]](repeating: [], count: 3)
        func all(_ words: String) -> Bool {
            let padded = " " + words
            return tokens.allSatisfy { padded.contains($0) }
        }
        func headed(_ name: String) -> Bool {
            let w = name.split(separator: " ")
            return w.first.map(String.init) == last || w.last.map(String.init) == last
        }
        for it in items {
            if all(it.english) {
                ranked[headed(it.english) ? 0 : 1].append(it)
            } else if all(it.spanish) {
                ranked[headed(it.spanish) ? 0 : 1].append(it)
            } else if all(it.english + " " + it.spanish + " " + it.keywords) {
                ranked[2].append(it)
            }
        }
        // A stable sort keeps the panel's order among emoji equally (un)popular.
        let sorted = ranked.map { group in
            group.enumerated().sorted { ($0.element.popularity, $0.offset) < ($1.element.popularity, $1.offset) }.map { $0.element.emoji }
        }
        return Array(sorted.joined().prefix(limit))
    }
}
