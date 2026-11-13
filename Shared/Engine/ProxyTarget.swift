// The app you're typing in, as the typing logic sees it. iOS only lets a keyboard insert text
// and delete backwards at the cursor, and shows it some of the text around the cursor. The
// word in progress is ordinary text in the field; replacing it means deleting what this
// keyboard put there (and only that) and typing the new word.
//
// The rule that matters most: never delete or replace anything on the strength of an old
// picture of the text. Apps can change the text themselves (Undo, a Send button that clears
// the box, a one-line field that swallows Return, a tap elsewhere that iOS doesn't pass on),
// and some show the keyboard its own edits a moment late. So the keyboard keeps its own
// picture of the text, and before acting on each key it compares that picture with what the
// app shows. If they differ, other than by the app being a moment behind, it takes the app's
// text as it is and the typing logic starts afresh before the key is handled: the key then
// does what it would do at that spot (a backspace deletes one character, a letter starts a
// new word), and nothing the keyboard thought it had typed is deleted or replaced.
//
// What can't be told apart: an app that's slow to show the keyboard's own last edit, and the
// app putting the text back exactly as it was before that edit (an Undo) within the same
// 0.35 s. A key pressed in that moment acts on the keyboard's picture; after it, the next key
// finds the change (or iOS's notice does, with a second look 0.4 s later). In an app that never
// shows its text, a tap within 0.35 s of the keyboard's last edit is likewise missed.

import Foundation

/// What iOS gives a keyboard of the text field it types into (UITextDocumentProxy, in short).
public protocol TextDocument: AnyObject {
    /// Some of the text before the cursor (nil when the app shows none).
    var textBeforeCursor: String? { get }
    /// Some of the text after the cursor.
    var textAfterCursor: String? { get }
    /// Whether the field has any text at all: tells an empty field from one whose text the app
    /// doesn't show.
    var hasText: Bool { get }
    func insertText(_ text: String)
    /// Deletes one character (an emoji or accented letter counts as one).
    func deleteBackward()
    /// Moves the cursor by this many UTF-16 units.
    func adjustTextPosition(byCharacterOffset offset: Int)
}

public final class ProxyTarget: TextTarget {
    /// How far behind the keyboard's own edits an app may show the text, in seconds.
    public static let lagWindow = 0.35
    /// How many of its own recent edits the keyboard remembers the starting points of.
    static let recentLimit = 40

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
    /// Where the keyboard's own recent edits started from (just the ends next to the cursor)
    /// and when each was made: an app that's behind shows one of these.
    private var recent = [(before: String, after: String, time: Double)]()
    private var recheckPending = false
    private var batchDepth = 0
    /// When this keyboard last changed the text.
    private var lastEdit = -1e9
    /// Whether this field has shown the keyboard any text. If it has, seeing nothing means an
    /// empty line; if not, the app is one that doesn't show its text.
    private var seenText = false
    /// Called when the app turns out to have changed the text: the typing logic must start
    /// afresh (this has to be set). When a key finds it out, it's called before the key is
    /// handled.
    public var onExternalChange: (() -> Void)?
    /// Capitals at the start of every word, not just sentences.
    public var wordCaps = false

    /// - Parameter now: seconds, steadily increasing.
    public init(proxy: @escaping () -> TextDocument, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        proxyGetter = proxy
        self.now = now
    }

    /// Takes the app's view of the text as the starting point (no word in progress).
    /// - Parameter newField: the keyboard has just come up, or moved to another text field.
    public func sync(newField: Bool = false) {
        model = proxy.textBeforeCursor ?? ""
        after = proxy.textAfterCursor ?? ""
        recent = []
        composing = nil
        if newField { seenText = false }
        if !model.isEmpty || !after.isEmpty { seenText = true }
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

    enum Fit { case same, behind, unknown, changed }

    /// How what the app shows fits the keyboard's picture: the same, a moment behind the
    /// keyboard's own last edits, impossible to tell (an app that never shows its text), or
    /// changed.
    func fit() -> Fit {
        let b = proxy.textBeforeCursor ?? ""
        let a = proxy.textAfterCursor ?? ""
        let matches: (String, String) -> Bool
        if b.isEmpty && a.isEmpty && !proxy.hasText {
            // An empty field.
            matches = { mb, ma in mb.isEmpty && ma.isEmpty }
        } else if b.isEmpty && a.isEmpty && !seenText {
            // An app that hasn't shown this field's text: nothing to compare.
            return .unknown
        } else {
            // (Seeing nothing in a field that has shown text means an empty line.)
            if !b.isEmpty || !a.isEmpty { seenText = true }
            matches = { mb, ma in ProxyTarget.beforeAgrees(b, mb) && ProxyTarget.afterAgrees(a, ma) }
        }
        if matches(model, after) { return .same }
        let t = now()
        if recent.contains(where: { t - $0.time < ProxyTarget.lagWindow && matches($0.before, $0.after) }) {
            return .behind
        }
        return .changed
    }

    /// Whether the text or cursor changed other than by this keyboard (then it re-syncs, and
    /// the word in progress is dropped). An app that's a moment behind is looked at again shortly.
    /// - Parameter notified: iOS said the text or selection changed (rather than the keyboard
    ///   looking again by itself).
    public func checkExternal(notified: Bool = true) -> Bool {
        switch fit() {
        case .same:
            return false
        case .unknown:
            // An app that doesn't show its text: iOS saying something changed is believed,
            // unless it comes right after the keyboard's own edit.
            if notified && now() - lastEdit >= ProxyTarget.lagWindow {
                // The word in progress is dropped; the old picture stays as the best guess
                // of what's before the cursor (spaces and capitals for the next word).
                composing = nil
                recent = []
                return true
            }
            return false
        case .behind:
            scheduleRecheck()
            return false
        case .changed:
            sync()
            return true
        }
    }

    private func scheduleRecheck() {
        if recheckPending { return }
        recheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ProxyTarget.lagWindow + 0.05) { [weak self] in
            guard let self = self else { return }
            self.recheckPending = false
            if self.checkExternal(notified: false) { self.onExternalChange?() }
        }
    }

    private func noteState() {
        lastEdit = now()
        recent.append((String(model.suffix(32)), String(after.prefix(32)), lastEdit))
        if recent.count > ProxyTarget.recentLimit { recent.removeFirst(recent.count - ProxyTarget.recentLimit) }
    }

    private func trimModel() {
        if model.utf16.count > 2000 { model = String(model.suffix(1000)) }
        if after.utf16.count > 2000 { after = String(after.prefix(1000)) }
    }

    // ---- TextTarget ----

    /// A key's edits come as one batch. Before the first, the app's text is compared with the
    /// keyboard's picture; if the app changed it, the typing logic starts afresh first.
    public func beginBatchEdit() {
        batchDepth += 1
        if batchDepth == 1 && fit() == .changed {
            sync()
            onExternalChange?()
        }
    }

    public func endBatchEdit() {
        batchDepth = max(0, batchDepth - 1)
    }

    /// An edit made outside a batch is checked the same way.
    private func edit(_ body: () -> Void) {
        beginBatchEdit()
        defer { endBatchEdit() }
        body()
    }

    public func commitText(_ t: String) {
        edit {
            if composing != nil {
                replaceComposing(with: t)
            } else if !t.isEmpty {
                insert(t)
            }
            composing = nil
        }
    }

    public func setComposingText(_ t: String) {
        edit {
            replaceComposing(with: t)
            composing = t.isEmpty ? nil : t
        }
    }

    public func finishComposingText() {
        composing = nil
    }

    private func insert(_ t: String) {
        noteState()
        proxy.insertText(t)
        model += t
        trimModel()
        // A one-line field takes Return as "go" and adds no new line: look again shortly.
        if t.contains("\n") { scheduleRecheck() }
    }

    private func deleteBackward(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            noteState()
            proxy.deleteBackward()
            if !model.isEmpty { model.removeLast() }
        }
    }

    /// Swaps the word in progress for t, keeping what they start with in common.
    private func replaceComposing(with t: String) {
        let old = Array(composing ?? "")
        let new = Array(t)
        var p = 0
        while p < old.count && p < new.count && old[p] == new[p] { p += 1 }
        deleteBackward(old.count - p)
        if p < new.count { insert(String(new[p...])) }
    }

    public func deleteBefore(utf16 n: Int) {
        edit {
            // Count whole characters: the app deletes one character (an emoji, an accented
            // letter) at a time.
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
    }

    public func deleteLastCharacter() {
        edit { deleteBackward(1) }
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
        edit {
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
}
