// Text helpers shared by the engine. Ported from tools/reference/core.js; the JS works on
// UTF-16 code units, so these do too wherever the result could differ.

import Foundation

/// The letters a word is swiped or typed with: lowercase a-z, accents and apostrophes dropped
/// ("Don't" -> "dont", "mañana" -> "manana"). "" if the word has anything else in it.
public func keyOf(_ word: String) -> String {
    var out = [UInt8]()
    out.reserveCapacity(word.utf16.count)
    for unit in word.utf16 {
        var c = unit
        if c >= 65 && c <= 90 { c += 32 }
        if c >= 97 && c <= 122 {
            out.append(UInt8(c))
            continue
        }
        if c == 39 || c == 0x2019 { continue }
        if c < 128 { return "" }
        let folded = LetterFolding.shared.fold(unit)
        if folded == 0 { return "" }
        out.append(folded)
    }
    return String(decoding: out, as: UTF8.self)
}

/// é -> e, Ñ -> n: one accented letter to its plain a-z letter (0 if it isn't one). Cached.
final class LetterFolding {
    static let shared = LetterFolding()
    private var cache = [UInt16: UInt8]()
    private let lock = NSLock()

    func fold(_ unit: UInt16) -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        if let v = cache[unit] { return v }
        var result: UInt8 = 0
        if let scalar = Unicode.Scalar(unit) {
            let base = String(Character(scalar)).decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { !(0x300...0x36F).contains($0.value) }
            if base.count == 1, var b = base.first?.value {
                if b >= 65 && b <= 90 { b += 32 }
                if b >= 97 && b <= 122 { result = UInt8(b) }
            }
        }
        cache[unit] = result
        return result
    }
}

@inline(__always)
func isLetterScalar(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return false
    }
}

/// Unicode letter test on one UTF-16 unit (a lone surrogate isn't a letter), like /\p{L}/u in JS.
@inline(__always)
func isLetterUnit(_ u: UInt16) -> Bool {
    guard let s = Unicode.Scalar(u) else { return false }
    return isLetterScalar(s)
}

/// True if the string contains a letter (JS /\p{L}/u.test).
func containsLetter(_ s: String) -> Bool {
    for sc in s.unicodeScalars where isLetterScalar(sc) { return true }
    return false
}

/// Only plain words are learned: letters with an optional apostrophe inside, at most 30 long.
public func isLearnable(_ word: String?) -> Bool {
    guard let word = word else { return false }
    let units = Array(word.utf16)
    let n = units.count
    if n == 0 || n > 30 { return false }
    var letters = 0
    for (i, u) in units.enumerated() {
        if isLetterUnit(u) {
            letters += 1
        } else if u == 39 || u == 0x2019 {
            if i == 0 || i == n - 1 { return false }
        } else {
            return false
        }
    }
    return letters > 0
}

/// JS isUpper(s[0]): the first character changes when lowercased and not when uppercased.
func isUpperFirst(_ s: String) -> Bool {
    guard let u = s.utf16.first, let sc = Unicode.Scalar(u) else { return false }
    let ch = String(Character(sc))
    return ch != ch.lowercased() && ch == ch.uppercased()
}

/// 0 = as is, 1 = Capitalized, 2 = ALL CAPS.
public func capsOf(_ s: String) -> Int {
    if s.isEmpty || !isUpperFirst(s) { return 0 }
    if s.utf16.count >= 2 && s == s.uppercased() { return 2 }
    return 1
}

public func withCaps(_ word: String, _ caps: Int) -> String {
    if word.isEmpty { return word }
    if caps == 2 { return word.uppercased() }
    if caps == 1 {
        // JS word[0].toUpperCase(): the first UTF-16 unit (half an emoji stays as it is).
        var scalars = word.unicodeScalars
        let first = scalars.removeFirst()
        if first.value > 0xFFFF { return word }
        return String(first).uppercased() + String(scalars)
    }
    return word
}

/// The last `n` characters of a string.
@inline(__always)
func suffixChars(_ s: String, _ n: Int) -> String {
    if n <= 0 { return "" }
    return String(s.suffix(n))
}

/// JS /\s/ on one UTF-16 unit.
@inline(__always)
func jsIsSpaceUnit(_ u: UInt16) -> Bool {
    switch u {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

@inline(__always)
private func category(_ u: UInt16) -> Unicode.GeneralCategory? {
    Unicode.Scalar(u)?.properties.generalCategory
}

/// JS /[\p{L}\p{N}]/u on one UTF-16 unit.
func isLetterOrNumberUnit(_ u: UInt16) -> Bool {
    switch category(u) {
    case .uppercaseLetter?, .lowercaseLetter?, .titlecaseLetter?, .modifierLetter?, .otherLetter?,
         .decimalNumber?, .letterNumber?, .otherNumber?:
        return true
    default:
        return false
    }
}

@inline(__always) private func isHighUnit(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }
@inline(__always) private func isLowUnit(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }

/// Characters as the cursor moves over them (a surrogate pair counts as one).
func charCount(_ s: ArraySlice<UInt16>) -> Int {
    var n = 0
    var prev: UInt16 = 0
    var first = true
    for c in s {
        if !(!first && isLowUnit(c) && isHighUnit(prev)) { n += 1 }
        prev = c
        first = false
    }
    return n
}

/// The UTF-16 length of the first `chars` characters of line (all of it if it's shorter).
func unitsFor(_ line: ArraySlice<UInt16>, _ chars: Int) -> Int {
    let u = Array(line)
    var i = 0
    var n = 0
    while n < chars && i < u.count {
        i += 1
        if i < u.count && isLowUnit(u[i]) && isHighUnit(u[i - 1]) { i += 1 }
        n += 1
    }
    return i
}

/// Characters that letters right after belong to an address or code rather than a sentence
/// ("gmail.com", "@sam", "/path", "http:", "snake_case", "#tag"); digits count too ("5th").
let glueUnits: Set<UInt16> = Set(".@/:_\\#=&~".utf16)

/// Whether letters starting at `at` in u are stuck to what comes before them (see glueUnits); an
/// ellipsis ("well...i") doesn't count. Same as core.js.
func gluedAt(_ u: [UInt16], _ at: Int) -> Bool {
    if at <= 0 { return false }
    let c = u[at - 1]
    if c >= 0x30 && c <= 0x39 { return true }
    if !glueUnits.contains(c) { return false }
    return !(c == 0x2E && at >= 2 && u[at - 2] == 0x2E)
}

/// The UTF-16 offset of each character position in u (surrogate pairs as one character), ending
/// with u's length.
func charOffsets(_ u: [UInt16]) -> [Int] {
    var out = [0]
    var i = 0
    while i < u.count {
        i += 1
        if i < u.count && isLowUnit(u[i]) && isHighUnit(u[i - 1]) { i += 1 }
        out.append(i)
    }
    return out
}

/// The lines on screen in `text` for the space-bar trackpad, as (start, end) character positions
/// (end is the last position on the line). A keyboard can't see where an app wraps a paragraph,
/// so one longer than `width` characters is taken to wrap every `width`; line breaks count as
/// they are (a \r\n as one). Same as core.js.
public func padLines(_ text: String, width: Int) -> [(Int, Int)] {
    let w = max(8, width)
    let u = Array(text.utf16)
    var lines = [(Int, Int)]()
    var pos = 0
    var paraStart = 0
    while true {
        let lineBreak = u[paraStart...].firstIndex(of: 0x0A)
        let paraEnd = lineBreak ?? u.count
        let n = charCount(u[paraStart..<paraEnd])
        let len = paraEnd > paraStart && u[paraEnd - 1] == 0x0D ? n - 1 : n
        if len <= w {
            lines.append((pos, pos + len))
        } else {
            var s = 0
            while true {
                if s + w < len {
                    lines.append((pos + s, pos + s + w - 1))
                } else {
                    lines.append((pos + s, pos + len))
                    break
                }
                s += w
            }
        }
        pos += n + 1
        guard let br = lineBreak else { break }
        paraStart = br + 1
    }
    return lines
}

/// Which of `lines` (from padLines) the character position `index` is on.
public func padLineOf(_ lines: [(Int, Int)], _ index: Int) -> Int {
    var i = 0
    while i + 1 < lines.count && lines[i + 1].0 <= index { i += 1 }
    return i
}

/// For each character position in `text` (0 to its length), whether a cursor can stop there: not
/// inside what shows as one character, such as ❤️, 👍🏽, a flag or 👩‍💻, which are made of several
/// (an iPhone moves the cursor over them whole).
public func graphemeEdges(_ text: String) -> [Bool] {
    var edges = [Bool](repeating: false, count: text.unicodeScalars.count + 1)
    edges[0] = true
    var pos = 0
    for ch in text {
        pos += ch.unicodeScalars.count
        edges[pos] = true
    }
    return edges
}

/// Android's sentence-start rule (TextUtils.getCapsMode), also skipping Spanish ¿ and ¡, on
/// the text before the cursor. Works on UTF-16 units like the JavaScript version.
public func capsAtEnd(of before: String) -> Bool {
    capsAtEnd(units: Array(before.utf16), before.utf16.count)
}

func capsAtEnd(units cs: [UInt16], _ end: Int) -> Bool {
    let quote: UInt16 = 0x22, apos: UInt16 = 0x27, iq: UInt16 = 0xBF, ie: UInt16 = 0xA1
    var i = end
    while i > 0 {
        let c = cs[i - 1]
        if c != quote && c != apos && c != iq && c != ie && category(c) != .openPunctuation { break }
        i -= 1
    }
    var j = i
    while j > 0 && (cs[j - 1] == 0x20 || cs[j - 1] == 0x09) { j -= 1 }
    if j == 0 || cs[j - 1] == 0x0A { return true }
    if i == j { return false }
    while j > 0 {
        let c = cs[j - 1]
        if c != quote && c != apos && category(c) != .closePunctuation { break }
        j -= 1
    }
    if j > 0 {
        let c = cs[j - 1]
        if c == 0x2E || c == 0x3F || c == 0x21 { // . ? !
            if c == 0x2E {
                var k = j - 2
                while k >= 0 {
                    let d = cs[k]
                    if d == 0x2E { return false }
                    if !isLetterUnit(d) { break }
                    k -= 1
                }
            }
            return true
        }
    }
    return false
}

/// Whether a space should go before a swiped word that follows this text (one character).
func needsSpaceBefore(_ s: String) -> Bool {
    guard let u = s.utf16.first else { return false }
    if jsIsSpaceUnit(u) { return false }
    return !"([{\"'“‘/-@#\n¿¡".utf16.contains(u)
}

/// Where the last visible character starts, in UTF-16 units (an emoji or accented letter is one).
func lastCharacterStart(_ s: String) -> Int {
    guard let last = s.last else { return 0 }
    return s.utf16.count - String(last).utf16.count
}
