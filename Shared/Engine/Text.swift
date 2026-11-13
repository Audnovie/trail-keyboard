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
