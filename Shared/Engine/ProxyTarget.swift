// The app you're typing in, as the typing logic sees it. iOS only lets a keyboard insert text
// and delete backwards at the cursor, and shows it some of the text around the cursor. The
// word in progress is ordinary text in the field; replacing it means deleting what this
// keyboard put there (and only that) and typing the new word.
//
// The rule that matters most: never delete anything unless the word in progress is still
// where the keyboard left it. Apps can change the text themselves (Undo, a Send button that
// clears the box, a one-line field that swallows Return), and some show the keyboard its own
// edits a moment late, so the keyboard keeps its own picture of the text and checks it.

import Foundation

/// What iOS gives a keyboard of the text field it types into (UITextDocumentProxy, in short).
public protocol TextDocument: AnyObject {
    /// Some of the text before the cursor (nil when the app shows none).
    var textBeforeCursor: String? { get }
    /// Some of the text after the cursor.
    var textAfterCursor: String? { get }
    func insertText(_ text: String)
    /// Deletes one character (an emoji or accented letter counts as one).
    func deleteBackward()
    /// Moves the cursor by this many UTF-16 units.
    func adjustTextPosition(byCharacterOffset offset: Int)
}

public final class ProxyTarget: TextTarget {
    /// How long an app may take to show the keyboard its own last edit, in seconds.
    public static let lagWindow = 0.35
    /// After this long without an edit, the app's text is taken as settled, in seconds.
    public static let settleTime = 1.0

    private let proxyGetter: () -> TextDocument
    private var proxy: TextDocument { proxyGetter() }
    private let now: () -> Double
    /// The word in progress, as it stands just before the cursor.
    public private(set) var composing: String?
    /// The text before the cursor as far as the keyboard knows: what the app showed it, plus
    /// its own changes since.
    private var model = ""
    /// The text after the cursor, likewise.
    private var after = ""
    /// The states this keyboard's own last few edits passed through.
    private var recent = [(before: String, after: String)]()
    /// When this keyboard last changed the text.
    private var lastEdit = -1e9
    private var recheckPending = false
    private var batchDepth = 0
    /// Set when the text turned out not to be as the keyboard left it: the rest of that key's
    /// edits are dropped, and the typing logic starts afresh straight after.
    private var halted = false
    /// Called when the app turns out to have changed the text after all (seen on a second look,
    /// or before an edit): the typing logic should start afresh.
    public var onExternalChange: (() -> Void)?
    /// Capitals at the start of every word, not just sentences.
    public var wordCaps = false

    /// - Parameter now: seconds, steadily increasing.
    public init(proxy: @escaping () -> TextDocument, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        proxyGetter = proxy
        self.now = now
    }

    /// Takes the app's view of the text as the starting point.
    public func sync() {
        model = proxy.textBeforeCursor ?? ""
        after = proxy.textAfterCursor ?? ""
        recent = []
    }

    // ---- comparing the app's text with the keyboard's picture of it ----

    /// Curly quotes made straight: apps with smart punctuation turn the keyboard's ' into ’,
    /// which isn't a change of place.
    static func norm(_ s: Substring) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "’", "‘": out.append("'")
            case "“", "”": out.append("\"")
            default: out.append(c)
            }
        }
        return out
    }

    /// Whether what the app shows before the cursor fits the keyboard's picture. Apps may show
    /// only the last part (the current paragraph or sentence), so only the overlap counts.
    static func beforeAgrees(_ app: String, _ mine: String) -> Bool {
        let a = norm(app.suffix(24))
        let m = norm(mine.suffix(24))
        if a.isEmpty { return m.isEmpty || m.last == "\n" }
        let n = min(a.count, m.count)
        if n == 0 { return false }
        return a.suffix(n) == m.suffix(n)
    }

    /// The same for the text after the cursor (the app may show only the first part).
    static func afterAgrees(_ app: String, _ mine: String) -> Bool {
        let a = norm(app.prefix(24))
        let m = norm(mine.prefix(24))
        if a.isEmpty { return m.isEmpty || m.first == "\n" }
        let n = min(a.count, m.count)
        if n == 0 { return false }
        return a.prefix(n) == m.prefix(n)
    }

    /// Whether the text or cursor changed other than by this keyboard (then it re-syncs).
    /// Right after an edit, a state the keyboard's own edits just passed through is taken as
    /// the app being slow, and looked at again shortly.
    public func checkExternal() -> Bool {
        let b = proxy.textBeforeCursor ?? ""
        let a = proxy.textAfterCursor ?? ""
        if ProxyTarget.beforeAgrees(b, model) && ProxyTarget.afterAgrees(a, after) { return false }
        if now() - lastEdit < ProxyTarget.lagWindow
            && recent.contains(where: { ProxyTarget.beforeAgrees(b, $0.before) && ProxyTarget.afterAgrees(a, $0.after) }) {
            scheduleRecheck()
            return false
        }
        model = b
        after = a
        recent = []
        return true
    }

    private func scheduleRecheck() {
        if recheckPending { return }
        recheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ProxyTarget.lagWindow + 0.05) { [weak self] in
            guard let self = self else { return }
            self.recheckPending = false
            if self.checkExternal() { self.onExternalChange?() }
        }
    }

    /// Before deleting: whether the text around the cursor is still as the keyboard left it.
    /// While the app may still be catching up with the last edit, or where it shows nothing,
    /// the keyboard's own picture is trusted.
    private func stillInPlace() -> Bool {
        if now() - lastEdit < ProxyTarget.settleTime { return true }
        if let b = proxy.textBeforeCursor, !b.isEmpty, !ProxyTarget.beforeAgrees(b, model) { return false }
        if let a = proxy.textAfterCursor, !a.isEmpty, !ProxyTarget.afterAgrees(a, after) { return false }
        return true
    }

    private func noteState() {
        recent.append((model, after))
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        lastEdit = now()
    }

    private func trimModel() {
        if model.utf16.count > 2000 { model = String(model.suffix(1000)) }
        if after.utf16.count > 2000 { after = String(after.prefix(1000)) }
    }

    // ---- TextTarget ----

    public func beginBatchEdit() {
        batchDepth += 1
    }

    public func endBatchEdit() {
        batchDepth = max(0, batchDepth - 1)
        if batchDepth == 0 { halted = false }
    }

    public func commitText(_ t: String) {
        if composing != nil {
            _ = replaceComposing(with: t)
        } else if !t.isEmpty {
            insert(t)
        }
        composing = nil
    }

    public func setComposingText(_ t: String) {
        if replaceComposing(with: t) {
            composing = t.isEmpty ? nil : t
        } else {
            composing = nil
        }
    }

    public func finishComposingText() {
        composing = nil
    }

    /// The text isn't as the keyboard left it: take the app's text as it is, make no more changes
    /// for this key, and have the typing logic start afresh once it's done with the key.
    private func lostTrack() {
        sync()
        composing = nil
        if batchDepth > 0 { halted = true }
        DispatchQueue.main.async { [weak self] in self?.onExternalChange?() }
    }

    private func insert(_ t: String) {
        if halted { return }
        noteState()
        proxy.insertText(t)
        model += t
        trimModel()
        // A one-line field takes Return as "go" and adds no new line: look again shortly.
        if t.contains("\n") { scheduleRecheck() }
    }

    private func deleteBackward(_ count: Int) {
        if halted || count <= 0 { return }
        if !stillInPlace() {
            lostTrack()
            return
        }
        for _ in 0..<count {
            noteState()
            proxy.deleteBackward()
            if !model.isEmpty { model.removeLast() }
        }
    }

    /// Swaps the word in progress for t, keeping what they start with in common. If the word
    /// isn't where the keyboard left it any more, nothing is deleted: only further letters
    /// typed onto it are added, and it returns false.
    private func replaceComposing(with t: String) -> Bool {
        if halted { return false }
        let old = Array(composing ?? "")
        let new = Array(t)
        var p = 0
        while p < old.count && p < new.count && old[p] == new[p] { p += 1 }
        if !old.isEmpty && !stillInPlace() {
            let typedOn = p == old.count && p < new.count ? String(new[p...]) : nil
            lostTrack()
            if let s = typedOn {
                halted = false
                insert(s)
                if batchDepth > 0 { halted = true }
            }
            return false
        }
        deleteBackward(old.count - p)
        if p < new.count { insert(String(new[p...])) }
        return true
    }

    public func deleteBefore(utf16 n: Int) {
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

    public func deleteLastCharacter() {
        deleteBackward(1)
    }

    public func textBefore(utf16 n: Int) -> String {
        let u = model.utf16
        let start = u.index(u.endIndex, offsetBy: -min(n, u.count))
        return String(decoding: u[start...], as: UTF16.self)
    }

    public func contextBefore(limit: Int, beforeComposing: Bool) -> String {
        var s = model
        if beforeComposing, let c = composing, s.hasSuffix(c) { s = String(s.dropLast(c.count)) }
        let u = s.utf16
        let start = u.index(u.endIndex, offsetBy: -min(limit, u.count))
        return String(decoding: u[start...], as: UTF16.self)
    }

    public func capsAtCursor() -> Bool {
        if wordCaps {
            guard let last = model.last else { return true }
            return last.isWhitespace || last == "(" || last == "\""
        }
        return capsAtEnd(of: String(model.suffix(200)))
    }

    /// Moves the cursor by whole characters, and moves them across in the keyboard's picture
    /// of the text too (the app may show the move a moment late).
    public func moveCursor(_ chars: Int) {
        if after.isEmpty { after = proxy.textAfterCursor ?? "" }
        noteState()
        var offset = 0
        if chars < 0 {
            var moved = ""
            var n = 0
            while n < -chars, let c = model.last {
                model.removeLast()
                moved = String(c) + moved
                offset -= String(c).utf16.count
                n += 1
            }
            after = moved + after
        } else {
            var rest = Substring(after)
            var moved = ""
            var n = 0
            while n < chars, let c = rest.first {
                rest = rest.dropFirst()
                moved.append(c)
                offset += String(c).utf16.count
                n += 1
            }
            after = String(rest)
            model += moved
        }
        trimModel()
        if offset != 0 { proxy.adjustTextPosition(byCharacterOffset: offset) }
    }
}
