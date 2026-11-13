// The text field the typing logic works on. On the iPhone that's the app you're typing in,
// reached through the keyboard's text proxy (Keyboard/ProxyTarget.swift); in tests and the
// in-app practice harness it's Editor, a small model of a text field ported from core.js.

import Foundation

/// The few things the typing logic does to a text field. "Composing" text is the word in
/// progress: it's already in the field, and gets replaced as you type or pick a suggestion.
public protocol TextTarget: AnyObject {
    func beginBatchEdit()
    func endBatchEdit()
    /// Replaces the composing text (if any) with t, or inserts t at the cursor; ends composing.
    func commitText(_ t: String)
    /// Replaces the composing text (if any) with t, or inserts it, and keeps it composing.
    func setComposingText(_ t: String)
    /// Leaves the composing text in the field as it is.
    func finishComposingText()
    /// Deletes this many UTF-16 units before the cursor (always whole characters here).
    func deleteBefore(utf16 n: Int)
    /// Deletes the character before the cursor (an emoji or accented letter counts as one).
    func deleteLastCharacter()
    /// The last n UTF-16 units before the cursor.
    func textBefore(utf16 n: Int) -> String
    /// Up to `limit` UTF-16 units before the cursor, or before the composing text.
    func contextBefore(limit: Int, beforeComposing: Bool) -> String
    /// Whether the cursor is at the start of a sentence.
    func capsAtCursor() -> Bool
    /// Moves the cursor by whole characters.
    func moveCursor(_ chars: Int)
}

/// A model text field (Android InputConnection style), ported from Editor in core.js.
public final class Editor: TextTarget {
    /// The text as UTF-16 units, like a JavaScript string.
    public private(set) var units: [UInt16] = []
    public private(set) var sel = 0
    public private(set) var cs = -1
    public private(set) var ce = -1
    private var batch = 0
    public var onChange: (() -> Void)?

    public init(text: String = "") {
        units = Array(text.utf16)
        sel = units.count
    }

    public var text: String { String(decoding: units, as: UTF16.self) }

    private func changed() {
        if batch == 0 { onChange?() }
    }

    public func beginBatchEdit() { batch += 1 }

    public func endBatchEdit() {
        if batch > 0 { batch -= 1 }
        changed()
    }

    public func commitText(_ t: String) {
        let u = Array(t.utf16)
        if cs >= 0 {
            units.replaceSubrange(cs..<ce, with: u)
            sel = cs + u.count
        } else {
            units.insert(contentsOf: u, at: sel)
            sel += u.count
        }
        cs = -1
        ce = -1
        changed()
    }

    public func setComposingText(_ t: String) {
        let u = Array(t.utf16)
        let start = cs >= 0 ? cs : sel
        let end = cs >= 0 ? ce : sel
        units.replaceSubrange(start..<end, with: u)
        if u.isEmpty {
            cs = -1
            ce = -1
            sel = start
        } else {
            cs = start
            ce = start + u.count
            sel = ce
        }
        changed()
    }

    public func finishComposingText() {
        cs = -1
        ce = -1
        changed()
    }

    public func deleteSurroundingText(_ before: Int, _ after: Int) {
        let s = max(0, sel - before)
        let e = min(units.count, sel + after)
        if cs >= 0 && cs < e && ce > s {
            cs = -1
            ce = -1
        }
        units.removeSubrange(s..<e)
        if cs >= s {
            cs -= e - s
            ce -= e - s
        }
        sel = s
        changed()
    }

    public func getTextBeforeCursor(_ n: Int) -> String {
        String(decoding: units[max(0, sel - n)..<sel], as: UTF16.self)
    }

    public func deleteBefore(utf16 n: Int) { deleteSurroundingText(n, 0) }

    public func deleteLastCharacter() {
        let before = getTextBeforeCursor(24)
        if !before.isEmpty { deleteSurroundingText(before.utf16.count - lastCharacterStart(before), 0) }
    }

    public func textBefore(utf16 n: Int) -> String { getTextBeforeCursor(n) }

    public func contextBefore(limit: Int, beforeComposing: Bool) -> String {
        let end = beforeComposing && cs >= 0 ? cs : sel
        return String(decoding: units[max(0, end - limit)..<end], as: UTF16.self)
    }

    public func capsAtCursor() -> Bool { capsAtEnd(units: units, sel) }

    @inline(__always) private func isHigh(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }
    @inline(__always) private func isLow(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }

    /// Moves the cursor by whole characters (an emoji counts as one).
    public func moveCursor(_ chars: Int) {
        var s = sel
        let step = chars < 0 ? -1 : 1
        for _ in 0..<abs(chars) {
            if step < 0 && s > 0 {
                s -= 1
                if s > 0 && isLow(units[s]) && isHigh(units[s - 1]) { s -= 1 }
            } else if step > 0 && s < units.count {
                s += 1
                if s < units.count && isLow(units[s]) && isHigh(units[s - 1]) { s += 1 }
            }
        }
        sel = s
        changed()
    }

    public func setCursor(_ index: Int) {
        sel = max(0, min(units.count, index))
        changed()
    }

    public func clear() {
        units = []
        sel = 0
        cs = -1
        ce = -1
        changed()
    }
}
