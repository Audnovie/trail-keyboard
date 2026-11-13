// The app you're typing in, as the typing logic sees it. iOS only lets a keyboard insert text
// and delete backwards at the cursor, and shows it some of the text around the cursor. The
// word in progress is ordinary text in the field; replacing it means deleting what this
// keyboard put there (and only that) and typing the new word.

import UIKit
import TrailEngine

final class ProxyTarget: TextTarget {
    private let proxyGetter: () -> UITextDocumentProxy
    private var proxy: UITextDocumentProxy { proxyGetter() }
    /// The word in progress, as it stands just before the cursor.
    private(set) var composing: String?
    /// The text before the cursor as far as the keyboard knows: what the app showed it, plus
    /// its own changes since (apps don't always update what they show straight away).
    private var model = ""
    /// The text after the cursor when last checked.
    private var after: String?
    /// The last few states this keyboard's own edits passed through (some apps report the text
    /// a moment late, mid-edit; that's not someone else changing it).
    private var recentTails = [String]()
    /// Capitals at the start of every word, not just sentences.
    var wordCaps = false

    init(proxy: @escaping () -> UITextDocumentProxy) {
        proxyGetter = proxy
    }

    /// Takes the app's view of the text as the starting point.
    func sync() {
        model = proxy.documentContextBeforeInput ?? ""
        after = proxy.documentContextAfterInput ?? ""
        recentTails = []
    }

    /// Whether the text or cursor changed other than by this keyboard (then it re-syncs).
    /// Moving the cursor changes the text after it, so that's checked strictly; the text before
    /// it may lag behind this keyboard's own edits in some apps.
    func checkExternal() -> Bool {
        let now = proxy.documentContextBeforeInput ?? ""
        let a = proxy.documentContextAfterInput ?? ""
        let t = ProxyTarget.tail(now)
        let changed = a != (after ?? "") || (t != ProxyTarget.tail(model) && !recentTails.contains(t))
        if changed {
            model = now
            after = a
            recentTails = []
        }
        return changed
    }

    private func noteState() {
        recentTails.append(ProxyTarget.tail(model))
        if recentTails.count > 6 { recentTails.removeFirst(recentTails.count - 6) }
    }

    /// The last 24 characters, with curly quotes made straight (apps with smart punctuation
    /// turn the keyboard's ' into ’, which isn't a change of place).
    private static func tail(_ s: String) -> String {
        String(s.suffix(24)).replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
    }

    private func trimModel() {
        if model.utf16.count > 2000 { model = String(model.suffix(1000)) }
    }

    // ---- TextTarget ----

    func beginBatchEdit() {}

    func endBatchEdit() {}

    func commitText(_ t: String) {
        if composing != nil {
            replaceComposing(with: t)
        } else if !t.isEmpty {
            insert(t)
        }
        composing = nil
    }

    func setComposingText(_ t: String) {
        replaceComposing(with: t)
        composing = t.isEmpty ? nil : t
    }

    func finishComposingText() {
        composing = nil
    }

    private func insert(_ t: String) {
        noteState()
        proxy.insertText(t)
        model += t
        trimModel()
    }

    private func deleteBackward(_ count: Int) {
        for _ in 0..<count {
            noteState()
            proxy.deleteBackward()
            if !model.isEmpty { model.removeLast() }
        }
    }

    /// Swaps the word in progress for t, keeping whatever they start with in common.
    private func replaceComposing(with t: String) {
        let old = Array(composing ?? "")
        let new = Array(t)
        var p = 0
        while p < old.count && p < new.count && old[p] == new[p] { p += 1 }
        deleteBackward(old.count - p)
        if p < new.count { insert(String(new[p...])) }
    }

    func deleteBefore(utf16 n: Int) {
        // Count whole characters: the app deletes one character (an emoji, an accented letter) at a time.
        var units = 0
        var chars = 0
        for c in model.reversed() {
            if units >= n { break }
            units += String(c).utf16.count
            chars += 1
        }
        if units < n { chars += n - units }
        deleteBackward(chars)
    }

    func deleteLastCharacter() {
        deleteBackward(1)
    }

    func textBefore(utf16 n: Int) -> String {
        let u = model.utf16
        let start = u.index(u.endIndex, offsetBy: -min(n, u.count))
        return String(decoding: u[start...], as: UTF16.self)
    }

    func contextBefore(limit: Int, beforeComposing: Bool) -> String {
        var s = model
        if beforeComposing, let c = composing, s.hasSuffix(c) { s = String(s.dropLast(c.count)) }
        let u = s.utf16
        let start = u.index(u.endIndex, offsetBy: -min(limit, u.count))
        return String(decoding: u[start...], as: UTF16.self)
    }

    func capsAtCursor() -> Bool {
        if wordCaps {
            guard let last = model.last else { return true }
            return last.isWhitespace || last == "(" || last == "\""
        }
        return capsAtEnd(of: String(model.suffix(200)))
    }

    func moveCursor(_ chars: Int) {
        var offset = 0
        if chars < 0 {
            var n = 0
            for c in model.reversed() {
                if n >= -chars { break }
                offset -= String(c).utf16.count
                n += 1
            }
        } else {
            var n = 0
            for c in (proxy.documentContextAfterInput ?? "") {
                if n >= chars { break }
                offset += String(c).utf16.count
                n += 1
            }
        }
        if offset != 0 { proxy.adjustTextPosition(byCharacterOffset: offset) }
        sync()
    }
}
