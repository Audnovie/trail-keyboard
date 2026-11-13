// Typing, swiping, suggestions and learning: the keyboard's typing logic, ported line for line
// from Ime in core.js (itself from the Android app's TrailIME). It talks to the text field
// through TextTarget and to the keys on screen through KeyboardSurface, so the same code runs
// in the keyboard, in the companion app's test harness, and in the tests.

import Foundation

public enum LayoutName: String {
    case letters, symbols, symbols2
}

/// What the typing logic asks of the keyboard on screen.
public protocol KeyboardSurface: AnyObject {
    func setLayout(_ name: LayoutName)
    func showEmoji(_ show: Bool)
    /// Empties the suggestion bar (and takes down any prompt in it).
    func clearStrip()
    func setShift(_ shifted: Bool, _ capsLock: Bool)
    /// Three suggestions, the `bold` one in the middle as a rule (also takes down any prompt).
    func setSuggestions(_ a: String?, _ b: String?, _ c: String?, bold: Int)
    func setPrompt(_ text: String?)
    var hasPrompt: Bool { get }
    func openSettings()
}

/// Key codes: a character's own code, or one of these.
public enum KeyCode {
    public static let shift = -1
    public static let delete = -2
    public static let symbols = -3
    public static let letters = -4
    public static let symbols2 = -5
    public static let enter = -6
    public static let emoji = -7
    public static let space = 32
}

/// Suggestion bar targets besides the three slots (0-2).
public let SLOT_GEAR = -1
public let PROMPT_YES = 10
public let PROMPT_NO = 11

public struct TypingSettings: Codable, Equatable {
    public var swipe = true
    public var smartFix = true
    public var autocorrect = false
    public var doubleSpace = true
    public var learn = true
    /// "auto" or a language code.
    public var typingLang = "auto"
    public var lastLang: String? = "en"

    public init() {}
}

/// You swapped a swiped word for another suggestion.
public struct Correction {
    public let picked: String
    public let pickedLang: String?
    public let guess: String
    public let guessLang: String?
    public let results: [SwipeResult]
}

private let SHIFT_OFF = 0
private let SHIFT_ON = 1
private let SHIFT_LOCK = 2

public enum StripKind {
    case none, typed, gesture
}

@inline(__always)
private func same(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}

private func lowerSame(_ a: String, _ b: String) -> Bool {
    same(a.lowercased(), b.lowercased())
}

public final class InputEngine {
    public let ic: TextTarget
    public weak var view: KeyboardSurface?
    public let lex: Lexicon
    private let now: () -> Double
    public let decoder = SwipeDecoder()
    public let suggester = TypingSuggester()
    public private(set) var settings = TypingSettings()
    /// The language you were last writing in, used until the words before the cursor say otherwise.
    public var lastLang = "en"
    /// The field takes suggestions (off in email and web address fields).
    public private(set) var canSuggest = true
    public private(set) var canSwipe = true
    public private(set) var canLearn = true
    /// The field wants capitals at the start of sentences.
    public private(set) var capsFlags = true
    /// The field wants everything in capitals.
    public private(set) var capChars = false
    /// The field may be learned from (not usernames, codes, addresses and the like).
    public private(set) var hostLearns = true
    private var shift = SHIFT_OFF
    private var autoShifted = false
    private var lastShiftTap = 0.0
    public private(set) var typed = ""
    private var typedFirstAutoCap = false
    public private(set) var gestureWord: String?
    private var gestureBase: String?
    private var gestureLang: String?
    /// The language you were writing in when you swiped it (where a rejection of it belongs).
    private var gestureCtx: String?
    private var gestureResults: [SwipeResult]?
    private var gestureCaps = 0
    private var gestureSpaceAdded = false
    private var afterGesture = false
    public private(set) var stripKind = StripKind.none
    public private(set) var stripText: [String?] = [nil, nil, nil]
    public private(set) var stripBase: [String?] = [nil, nil, nil]
    public private(set) var stripLang: [String?] = [nil, nil, nil]
    private var blockCandidate: String?
    private var blockLang: String?
    private var spaceAfterPick = false
    private var lastSpaceTime = -1e9
    private var revertFrom: String?
    private var revertTo: String?
    private var revertLang: String?
    private var deletedGestureWord: String?
    private var deletedGestureLang: String?
    private var deletedGestureTime = 0.0
    /// Called when you swap a swiped word for another suggestion.
    public var onCorrection: ((Correction) -> Void)?

    /// - Parameter now: milliseconds, steadily increasing.
    public init(target: TextTarget, view: KeyboardSurface?, lex: Lexicon, now: @escaping () -> Double) {
        ic = target
        self.view = view
        self.lex = lex
        self.now = now
    }

    public func onGeometry(_ cx: [Double], _ cy: [Double], _ kw: Double) {
        decoder.setKeyCenters(cx, cy, kw)
        suggester.setKeyCenters(cx, cy, kw)
    }

    /// Learning needs a word list (to tell built-in words from new ones).
    public func learning() -> Bool {
        canLearn && !lex.enabled().isEmpty
    }

    public func applySettings(_ s: TypingSettings) {
        settings = s
        if let l = s.lastLang, !l.isEmpty { lastLang = l }
        canSwipe = canSuggest && settings.swipe
        canLearn = canSuggest && settings.learn && hostLearns
    }

    /// What kind of field this is (the iPhone's text traits, see HostTraits).
    public func setField(suggest: Bool, sentenceCaps: Bool, allCaps: Bool, learn: Bool) {
        canSuggest = suggest
        capsFlags = sentenceCaps
        capChars = allCaps
        hostLearns = learn
        applySettings(settings)
    }

    /// Like onStartInputView for a text field: a fresh start.
    public func start(_ settings: TypingSettings) {
        if !typed.isEmpty || gestureWord != nil { ic.finishComposingText() }
        resetComposing()
        deletedGestureWord = nil
        blockCandidate = nil
        applySettings(settings)
        view?.setLayout(.letters)
        view?.showEmoji(false)
        view?.clearStrip()
        shift = SHIFT_OFF
        autoShifted = false
        updateShift()
    }

    private func resetComposing() {
        typed = ""
        gestureWord = nil
        gestureBase = nil
        gestureLang = nil
        gestureCtx = nil
        gestureResults = nil
        gestureSpaceAdded = false
        afterGesture = false
        spaceAfterPick = false
        revertFrom = nil
        revertTo = nil
        stripKind = .none
    }

    public func composing() -> Bool {
        !typed.isEmpty || gestureWord != nil
    }

    // ---- languages ----

    /// The language you're writing in right now.
    public func contextLang() -> String? {
        let langs = lex.enabled()
        if langs.isEmpty { return nil }
        let codes = langs.map { $0.code }
        let fixed = settings.typingLang
        if fixed != "auto" && codes.contains(fixed) { return fixed }
        if langs.count == 1 { return codes[0] }
        // The words before the one being tapped out (a swiped word counts: it's finished).
        let text = ic.contextBefore(limit: 400, beforeComposing: !typed.isEmpty)
        let found = detectLang(text, langs)
        if let f = found { lastLang = f }
        return found ?? (codes.contains(lastLang) ? lastLang : codes[0])
    }

    /// Where words come from: the context language at full weight, the others marked down.
    public func sources(_ ctx: String?) -> [Source] {
        let fixed = settings.typingLang != "auto"
        var out = [Source]()
        for L in lex.enabled() {
            if fixed && L.code != ctx { continue }
            guard let W = L.words else { continue }
            let S = Source(words: W, user: L.user, bias: L.code == ctx ? 0 : -LANG_PENALTY, lang: L.code)
            if L.code == ctx { out.insert(S, at: 0) } else { out.append(S) }
        }
        return out
    }

    private func inBase(_ word: String, _ code: String?) -> Bool {
        guard let L = lex.get(code), let W = L.words else { return false }
        return W.find(word) >= 0
    }

    private func recordUse(_ word: String, _ amount: Double, _ code: String?) {
        if let L = lex.get(code) { L.user.recordUse(word, amount: amount, inBaseList: inBase(word, code)) }
    }

    private func recordReject(_ word: String, _ code: String?) {
        lex.get(code)?.user.recordReject(word)
    }

    private func blockedIn(_ word: String, _ code: String?) -> Bool {
        lex.get(code)?.user.isBlocked(word) ?? false
    }

    /// The language a typed word belongs to: yours if it knows the word, else one that does.
    private func langOfTyped(_ word: String, _ ctx: String?) -> String? {
        let srcs = sources(ctx)
        for S in srcs where S.words.find(word) >= 0 { return S.lang }
        for S in srcs where S.user.get(word) != nil { return S.lang }
        return ctx
    }

    /// The typing language or the languages switched on changed: redo the word being tapped out.
    public func refreshSuggestions() {
        if stripKind == .typed && !typed.isEmpty { showTypedSuggestions() }
    }

    // ---- keys ----

    public func onKey(_ code: Int) {
        dismissPrompt()
        if code == KeyCode.enter {
            handleEnter()
            return
        }
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        switch code {
        case KeyCode.shift:
            handleShift()
        case KeyCode.symbols:
            finalizeAll()
            view?.setLayout(.symbols)
        case KeyCode.symbols2:
            view?.setLayout(.symbols2)
        case KeyCode.letters:
            view?.setLayout(.letters)
            updateShift()
        case KeyCode.emoji:
            finalizeAll()
            view?.showEmoji(true)
        case KeyCode.space:
            handleSpace()
        default:
            if code > 0, let u = Unicode.Scalar(UInt16(truncatingIfNeeded: code)) { handleChar(String(Character(u))) }
        }
    }

    /// A character picked from a key's pop-up (an accent or a number), or held for.
    public func typeAlt(_ ch: String) {
        dismissPrompt()
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        handleChar(ch)
    }

    public func onDelete() {
        dismissPrompt()
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        deleteInner()
    }

    private func deleteInner() {
        if gestureWord != nil {
            // One backspace removes the whole swiped word (and the space added before it).
            ic.commitText("")
            if gestureSpaceAdded {
                let b = ic.textBefore(utf16: 1)
                if same(b, " ") { ic.deleteBefore(utf16: 1) }
            }
            deletedGestureWord = learning() ? gestureBase : nil
            deletedGestureLang = gestureCtx ?? gestureLang
            deletedGestureTime = now()
            resetComposing()
            view?.clearStrip()
            updateShift()
            return
        }
        if !typed.isEmpty {
            typed = String(decoding: typed.utf16.dropLast(), as: UTF16.self)
            if typed.isEmpty {
                ic.commitText("")
                stripKind = .none
                view?.clearStrip()
                updateShift()
            } else {
                ic.setComposingText(typed)
                showTypedSuggestions()
            }
            return
        }
        if let from = revertFrom, let to = revertTo {
            let b = ic.textBefore(utf16: from.utf16.count + 1)
            if same(b, from + " ") {
                // Undo the automatic fix: put back exactly what you typed.
                ic.deleteBefore(utf16: from.utf16.count + 1)
                ic.commitText(to)
                if learning() {
                    recordReject(from, revertLang)
                    if to.utf16.count >= 2 {
                        let lang = langOfTyped(to, contextLang())
                        recordUse(learnForm(to, false, lang), 1, lang)
                    }
                }
                revertFrom = nil
                revertTo = nil
                return
            }
            revertFrom = nil
            revertTo = nil
        }
        afterGesture = false
        spaceAfterPick = false
        ic.deleteLastCharacter()
        if stripKind != .none {
            stripKind = .none
            view?.clearStrip()
        }
        updateShift()
    }

    public func onSwipe(_ xs: [Double], _ ys: [Double], _ count: Int) {
        dismissPrompt()
        if !canSwipe || !decoder.ready { return }
        guard let ctx = contextLang() else { return }
        let res = decoder.decode(xs, ys, count, sources(ctx), max: 8)
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        swipeInner(res, ctx)
    }

    private func swipeInner(_ res: [SwipeResult], _ ctx: String) {
        if gestureWord != nil { finalizeGesture() }
        if !typed.isEmpty { commitTyped() }
        if res.isEmpty { return }
        gestureCaps = shift == SHIFT_LOCK || capChars ? 2 : shift == SHIFT_ON ? 1 : 0
        let base = res[0].word
        gestureBase = base
        gestureLang = res[0].lang ?? ctx
        gestureCtx = ctx
        gestureResults = res
        var shown = withCaps(base, gestureCaps)
        let before = ic.textBefore(utf16: 1)
        gestureSpaceAdded = false
        if before.utf16.count == 1 && needsSpaceBefore(before) {
            ic.commitText(" ")
            gestureSpaceAdded = true
            // "Done." + swipe: the space just added starts a new sentence.
            if gestureCaps == 0 && capsFlags && ic.capsAtCursor() {
                gestureCaps = 1
                shown = withCaps(base, gestureCaps)
            }
        }
        ic.setComposingText(shown)
        gestureWord = shown
        afterGesture = false
        spaceAfterPick = false
        revertFrom = nil
        if shift == SHIFT_ON && !capChars {
            shift = SHIFT_OFF
            autoShifted = false
            refreshShift()
        }
        showGestureStrip()
    }

    /// Space-bar drag: moves the cursor.
    public func onCursorMove(_ chars: Int) {
        dismissPrompt()
        ic.beginBatchEdit()
        finalizeAll()
        ic.endBatchEdit()
        // The cursor is going somewhere new: forget anything tied to the old spot.
        afterGesture = false
        spaceAfterPick = false
        revertFrom = nil
        revertTo = nil
        ic.moveCursor(chars)
        updateShift()
    }

    /// You tapped somewhere in the text (the model field used in tests).
    public func onCursorPlaced(_ index: Int, editor: Editor) {
        if composing() {
            if index == editor.ce { return }
            // Leave the half-done word exactly as it is.
            ic.finishComposingText()
            resetComposing()
            view?.clearStrip()
        } else {
            forgetSpot()
        }
        editor.setCursor(index)
        updateShift()
    }

    /// The text or cursor changed outside the keyboard (you tapped elsewhere, or the app
    /// changed the text): the word in progress stays as it is, and nothing tied to the old
    /// spot carries over.
    public func onExternalChange() {
        if composing() {
            ic.finishComposingText()
            resetComposing()
            view?.clearStrip()
        } else {
            forgetSpot()
        }
        updateShift()
    }

    private func forgetSpot() {
        afterGesture = false
        spaceAfterPick = false
        revertFrom = nil
        if !(view?.hasPrompt ?? false) && stripKind != .none {
            stripKind = .none
            view?.clearStrip()
        }
    }

    public func onStripTap(_ slot: Int) {
        if slot == SLOT_GEAR {
            view?.openSettings()
            return
        }
        if slot == PROMPT_YES || slot == PROMPT_NO {
            answerPrompt(slot == PROMPT_YES)
            return
        }
        if slot < 0 || slot > 2 || stripText[slot] == nil { return }
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        pickInner(slot)
    }

    private func pickInner(_ slot: Int) {
        guard let chosen = stripText[slot] else { return }
        let base = stripBase[slot]
        let lang = stripLang[slot]
        if stripKind == .gesture, let gw = gestureWord {
            if same(chosen, gw) {
                finalizeGesture()
            } else {
                ic.setComposingText(chosen)
                ic.finishComposingText()
                if let cb = onCorrection, let b = base, let g = gestureBase {
                    cb(Correction(picked: b, pickedLang: lang, guess: g, guessLang: gestureLang, results: gestureResults ?? []))
                }
                if learning() {
                    if let b = base { recordUse(b, 2, lang) }
                    // Rejected while writing in gestureCtx: that's where it should come up less.
                    if let g = gestureBase { recordReject(g, gestureCtx ?? gestureLang) }
                }
                gestureWord = nil
                gestureBase = nil
                gestureLang = nil
                gestureCtx = nil
                gestureResults = nil
                deletedGestureWord = nil
                afterGesture = true
            }
            stripKind = .none
            view?.clearStrip()
            return
        }
        if stripKind == .typed && !typed.isEmpty {
            let literal = typed
            ic.setComposingText(chosen)
            ic.finishComposingText()
            if learning() {
                if same(chosen, literal) {
                    if literal.utf16.count >= 2 || inBase(literal, lang) {
                        recordUse(learnForm(literal, typedFirstAutoCap, lang), 1, lang)
                    }
                } else if let b = base {
                    recordUse(b, 2, lang)
                }
            }
            typed = ""
            ic.commitText(" ")
            spaceAfterPick = true
            stripKind = .none
            view?.clearStrip()
            updateShift()
        }
    }

    public func onStripLongPress(_ slot: Int) {
        if slot < 0 || slot > 2 { return }
        guard let candidate = stripBase[slot] else { return }
        blockCandidate = candidate
        // Blocked in the language you're writing in: blocking a Spanish word that turned up in
        // English leaves it alone for Spanish.
        blockLang = (stripKind == .gesture ? gestureCtx : nil) ?? contextLang() ?? stripLang[slot]
        let L = lex.get(blockLang)
        let place = lex.enabled().count > 1 && L != nil ? " in " + L!.name : ""
        view?.setPrompt("Never suggest “" + candidate + "”" + place + "?")
    }

    private func answerPrompt(_ yes: Bool) {
        let word = blockCandidate
        let code = blockLang
        blockCandidate = nil
        view?.setPrompt(nil)
        if yes, let w = word {
            lex.get(code)?.user.block(w)
            if stripKind == .gesture && gestureWord != nil, let results = gestureResults {
                let gone = { (w: String, lang: String?) -> Bool in self.blockedIn(w, lang) || self.blockedIn(w, code) }
                let kept = results.filter { !gone($0.word, $0.lang) }
                gestureResults = kept
                if let gb = gestureBase, gone(gb, gestureLang) {
                    if kept.isEmpty {
                        ic.commitText("")
                        resetComposing()
                        view?.clearStrip()
                        return
                    }
                    gestureBase = kept[0].word
                    gestureLang = kept[0].lang
                    let shown = withCaps(kept[0].word, gestureCaps)
                    gestureWord = shown
                    ic.setComposingText(shown)
                }
                showGestureStrip()
                return
            }
        }
        if stripKind == .gesture { showGestureStrip() }
        else if stripKind == .typed { showTypedSuggestions() }
        else { view?.clearStrip() }
    }

    public func dismissPrompt() {
        if blockCandidate != nil {
            blockCandidate = nil
            view?.setPrompt(nil)
        }
    }

    public var hasBlockPrompt: Bool { blockCandidate != nil }

    public func onEmoji(_ text: String) {
        ic.beginBatchEdit()
        finalizeAll()
        ic.commitText(text)
        ic.endBatchEdit()
        afterGesture = false
        spaceAfterPick = false
        updateShift()
    }

    public func onEmojiBack() {
        view?.showEmoji(false)
        updateShift()
    }

    // ---- typing ----

    private func handleShift() {
        if let base = gestureBase, gestureWord != nil {
            // Shift right after a swipe cycles the word: lowercase, Capitalized, ALL CAPS.
            gestureCaps = (gestureCaps + 1) % 3
            let shown = withCaps(base, gestureCaps)
            ic.setComposingText(shown)
            gestureWord = shown
            showGestureStrip()
            return
        }
        let t = now()
        if shift == SHIFT_LOCK {
            shift = SHIFT_OFF
        } else if lastShiftTap > 0 && t - lastShiftTap < 350 {
            shift = SHIFT_LOCK
        } else if shift == SHIFT_ON {
            shift = SHIFT_OFF
        } else {
            shift = SHIFT_ON
        }
        autoShifted = false
        lastShiftTap = shift == SHIFT_LOCK ? 0 : t
        refreshShift()
    }

    private func refreshShift() {
        view?.setShift(shift != SHIFT_OFF, shift == SHIFT_LOCK)
    }

    /// Shift on at the start of a sentence.
    public func updateShift() {
        if shift == SHIFT_LOCK || (shift == SHIFT_ON && !autoShifted) {
            refreshShift()
            return
        }
        var auto = false
        if capChars { auto = true }
        else if capsFlags && typed.isEmpty && gestureWord == nil { auto = ic.capsAtCursor() }
        shift = auto ? SHIFT_ON : SHIFT_OFF
        autoShifted = auto
        refreshShift()
    }

    public var shiftState: (shifted: Bool, locked: Bool) { (shift != SHIFT_OFF, shift == SHIFT_LOCK) }

    private func handleChar(_ c: String) {
        revertFrom = nil
        lastShiftTap = 0
        if containsLetter(c) {
            if gestureWord != nil {
                finalizeGesture()
                ic.commitText(" ")
            } else if afterGesture {
                ic.commitText(" ")
            }
            afterGesture = false
            spaceAfterPick = false
            let out = shift != SHIFT_OFF ? c.uppercased() : c
            if canSuggest {
                if typed.isEmpty { typedFirstAutoCap = shift == SHIFT_ON && autoShifted }
                typed += out
                ic.setComposingText(typed)
                showTypedSuggestions()
            } else {
                ic.commitText(out)
            }
            if shift == SHIFT_ON && !capChars {
                shift = SHIFT_OFF
                autoShifted = false
                refreshShift()
            }
            return
        }
        if (same(c, "'") || same(c, "’")) && !typed.isEmpty && canSuggest {
            typed += c
            ic.setComposingText(typed)
            showTypedSuggestions()
            return
        }
        // Punctuation, digits and symbols end the current word.
        finalizeAll()
        let attaches = c.utf16.count == 1 && ".,!?;:)]}".utf16.contains(c.utf16.first!)
        if spaceAfterPick && attaches {
            let b = ic.textBefore(utf16: 1)
            if same(b, " ") {
                ic.deleteBefore(utf16: 1)
                let sentence = ".,!?;:".utf16.contains(c.utf16.first!)
                ic.commitText(sentence ? c + " " : c)
                spaceAfterPick = sentence
                afterGesture = false
                updateShift()
                return
            }
        }
        ic.commitText(c)
        spaceAfterPick = false
        afterGesture = false
        updateShift()
    }

    private func handleSpace() {
        let t = now()
        revertFrom = nil
        if gestureWord != nil {
            finalizeGesture()
            ic.commitText(" ")
            afterGesture = false
            lastSpaceTime = t
            updateShift()
            return
        }
        if !typed.isEmpty {
            commitTyped()
            ic.commitText(" ")
            lastSpaceTime = t
            updateShift()
            return
        }
        if spaceAfterPick {
            // The space after a picked suggestion is already there.
            spaceAfterPick = false
            lastSpaceTime = t
            return
        }
        if settings.doubleSpace && canSuggest && t - lastSpaceTime < 600 {
            let b = Array(ic.textBefore(utf16: 2).utf16)
            if b.count == 2 && b[1] == 0x20 && isLetterOrNumberUnit(b[0]) {
                ic.deleteBefore(utf16: 1)
                ic.commitText(". ")
                lastSpaceTime = -1e9
                afterGesture = false
                updateShift()
                return
            }
        }
        ic.commitText(" ")
        lastSpaceTime = t
        afterGesture = false
        updateShift()
    }

    private func handleEnter() {
        ic.beginBatchEdit()
        finalizeAll()
        afterGesture = false
        spaceAfterPick = false
        ic.commitText("\n")
        ic.endBatchEdit()
        updateShift()
    }

    /// Commits whatever word is in progress (with learning), leaving the text as shown.
    public func finalizeAll() {
        if gestureWord != nil { finalizeGesture() }
        if !typed.isEmpty { commitTyped() }
        if stripKind != .none {
            stripKind = .none
            view?.clearStrip()
        }
    }

    /// The keyboard is closing: keep the word in progress exactly as shown, learning it.
    public func finishAsIs() {
        dismissPrompt()
        if gestureWord != nil { finalizeGesture() }
        if !typed.isEmpty {
            let literal = typed
            let ctx = contextLang()
            typed = ""
            ic.finishComposingText()
            if learning() {
                let lang = langOfTyped(literal, ctx)
                let base = learnForm(literal, typedFirstAutoCap, lang)
                if isLearnable(base) && (base.utf16.count >= 2 || inBase(base, lang)) { recordUse(base, 1, lang) }
            }
            revertFrom = nil
            revertTo = nil
        }
        afterGesture = false
        spaceAfterPick = false
        stripKind = .none
        view?.clearStrip()
    }

    private func finalizeGesture() {
        ic.finishComposingText()
        if learning(), let base = gestureBase {
            recordUse(base, 1, gestureLang)
            if let dw = deletedGestureWord, now() - deletedGestureTime < 20000, !lowerSame(dw, base) {
                // You deleted a swiped word and swiped again: the first guess was wrong.
                recordReject(dw, deletedGestureLang)
            }
        }
        deletedGestureWord = nil
        gestureWord = nil
        gestureBase = nil
        gestureLang = nil
        gestureCtx = nil
        gestureResults = nil
        gestureSpaceAdded = false
        afterGesture = true
        stripKind = .none
        view?.clearStrip()
    }

    /// Commits the tapped word, applying apostrophe, accent and capital fixes (and typo fixes if on).
    private func commitTyped() {
        let literal = typed
        let ctx = contextLang()
        typed = ""
        let fix = decideTypedCommit(literal, ctx)
        let commit = fix.text
        if !same(commit, literal) {
            ic.setComposingText(commit)
            revertFrom = commit
            revertTo = literal
            revertLang = ctx
        } else {
            revertFrom = nil
            revertTo = nil
        }
        ic.finishComposingText()
        if learning() {
            let unchanged = same(commit, literal)
            let lang = unchanged ? langOfTyped(literal, ctx) : fix.lang
            let base = unchanged ? learnForm(literal, typedFirstAutoCap, lang) : baseFormOf(commit, lang)
            if isLearnable(base) && (base.utf16.count >= 2 || inBase(base, lang)) { recordUse(base, 1, lang) }
        }
        deletedGestureWord = nil
        stripKind = .none
        view?.clearStrip()
    }

    /// What pressing space turns the tapped word into (lang nil if unchanged).
    public func decideTypedCommit(_ literal: String, _ ctx: String?) -> (text: String, lang: String?) {
        let plain = (text: literal, lang: String?.none)
        guard canSuggest, let ctx = ctx, !literal.isEmpty else { return plain }
        let srcs = sources(ctx)
        let caps = capsOf(literal)
        if settings.smartFix {
            let key = keyOf(literal)
            // Typed with plain letters only: "dont" -> "don't", "tambien" -> "también",
            // "im" -> "I'm" (but "its", "ill", "como" stay, since they're words too).
            if !key.isEmpty && same(literal.lowercased(), key) {
                let P = primaryOf(srcs)
                var literalScore = -99.0
                for S in srcs {
                    let id = S.words.find(literal)
                    if id >= 0 {
                        literalScore = max(literalScore, Double(S.words.score(id)) / 100 + S.bias + bonusIn(S, P, literal))
                    } else if isActiveAddedIn(literal, S) {
                        literalScore = 99
                    }
                }
                var best: (word: String, lang: String)?
                var bestScore = -99.0
                for S in srcs {
                    let shared: SharedMap? = isForeign(S, P) ? sharedWith(S.words, P!.words) : nil
                    for id in S.words.withKey(key) {
                        if let sh = shared, sh[id] { continue }
                        let d = S.words.display(id)
                        if lowerSame(d, literal) || Lexicon_blockedIn(S, P, d) { continue }
                        let s = Double(S.words.score(id)) / 100 + S.bias + bonusIn(S, P, d)
                        if s > bestScore {
                            bestScore = s
                            best = (d, S.lang)
                        }
                    }
                }
                if let b = best, bestScore - literalScore >= 1.5 { return (withCaps(b.word, caps), b.lang) }
            }
            // "i" -> "I", "toronto" -> "Toronto", "méxico" -> "México"
            if same(literal, literal.lowercased()) {
                let P = primaryOf(srcs)
                for S in srcs {
                    let id = S.words.find(literal)
                    if id < 0 { continue }
                    let d = S.words.display(id)
                    if !same(d, literal) && !same(d, d.uppercased()) && !Lexicon_blockedIn(S, P, d) { return (d, S.lang) }
                    if same(d, "I") { return (d, S.lang) }
                    break
                }
            }
        }
        if settings.autocorrect && literal.utf16.count >= 2 && !srcs.contains(where: { $0.words.find(literal) >= 0 }) &&
            !srcs.contains(where: { isActiveAddedIn(literal, $0) }) {
            let s = suggester.suggest(literal, srcs, max: 3)
            if let top = s.first {
                if (top.kind == .correction && top.cost <= 1.0) || top.kind == .exact {
                    return (withCaps(top.word, caps), top.lang)
                }
            }
        }
        return plain
    }

    // ---- suggestion strip ----

    private func showGestureStrip() {
        guard let results = gestureResults, !results.isEmpty, let b0 = gestureBase else {
            view?.clearStrip()
            return
        }
        stripKind = .gesture
        var r1: SwipeResult?
        var r2: SwipeResult?
        for r in results {
            if lowerSame(r.word, b0) { continue }
            if r1 == nil {
                r1 = r
            } else if r2 == nil && !lowerSame(r.word, r1!.word) {
                r2 = r
                break
            }
        }
        setSlot(0, r1?.word, r1.map { withCaps($0.word, gestureCaps) }, r1?.lang)
        setSlot(1, b0, gestureWord, gestureLang)
        setSlot(2, r2?.word, r2.map { withCaps($0.word, gestureCaps) }, r2?.lang)
        view?.setSuggestions(stripText[0], stripText[1], stripText[2], bold: 1)
    }

    private func showTypedSuggestions() {
        if !canSuggest || typed.isEmpty {
            stripKind = .none
            view?.clearStrip()
            return
        }
        guard let ctx = contextLang() else {
            view?.clearStrip()
            return
        }
        stripKind = .typed
        let literal = typed
        let caps = capsOf(literal)
        let fix = decideTypedCommit(literal, ctx)
        let onSpace = fix.text
        let list = suggester.suggest(literal, sources(ctx), max: 6)
        var alts = [Suggestion]()
        for s in list {
            if lowerSame(s.word, literal) || lowerSame(s.word, onSpace) { continue }
            alts.append(s)
        }
        let literalLang = langOfTyped(literal, ctx)
        if !same(onSpace, literal) {
            setSlot(0, literal, literal, literalLang)
            setSlot(1, baseFormOf(onSpace, fix.lang), onSpace, fix.lang)
            let a = alts.first
            setSlot(2, a?.word, a.map { withCaps($0.word, caps) }, a?.lang)
            view?.setSuggestions("“" + literal + "”", onSpace, stripText[2], bold: 1)
            return
        }
        let a0 = alts.count > 0 ? alts[0] : nil
        let a1 = alts.count > 1 ? alts[1] : nil
        setSlot(0, a0?.word, a0.map { withCaps($0.word, caps) }, a0?.lang)
        setSlot(1, literal, literal, literalLang)
        setSlot(2, a1?.word, a1.map { withCaps($0.word, caps) }, a1?.lang)
        view?.setSuggestions(stripText[0], stripText[1], stripText[2], bold: 1)
    }

    private func setSlot(_ i: Int, _ base: String?, _ text: String?, _ lang: String?) {
        stripBase[i] = base
        stripText[i] = text
        stripLang[i] = lang
    }

    // ---- helpers ----

    private func isActiveAddedIn(_ word: String, _ S: Source) -> Bool {
        guard let e = S.user.get(word) else { return false }
        return e.added && e.active
    }

    /// The dictionary's own spelling ("hello" for "Hello" at a sentence start).
    private func baseFormOf(_ word: String, _ code: String?) -> String {
        let L = lex.get(code)
        if let W = L?.words {
            let id = W.find(word)
            if id >= 0 { return W.display(id) }
        }
        return L?.user.get(word)?.word ?? word
    }

    /// How to store a typed word: drop a capital that only came from sentence-start shift.
    private func learnForm(_ literal: String, _ firstFromAutoCap: Bool, _ code: String?) -> String {
        let L = lex.get(code)
        if let W = L?.words {
            let id = W.find(literal)
            if id >= 0 { return W.display(id) }
        }
        if let e = L?.user.get(literal) { return e.word }
        if firstFromAutoCap && literal.utf16.count > 1 && !same(literal, literal.uppercased()) {
            let u = Array(literal.utf16)
            let first = String(decoding: u[0..<1], as: UTF16.self).lowercased()
            return first + String(decoding: u[1...], as: UTF16.self)
        }
        return literal
    }
}

/// blockedIn from Lexicon.swift (named apart from InputEngine's own two-argument one).
@inline(__always)
func Lexicon_blockedIn(_ S: Source, _ P: Source?, _ word: String) -> Bool {
    blockedIn(S, P, word)
}
