// Typing, swiping, suggestions and learning: the keyboard's typing logic, ported line for line
// from Ime in core.js (itself from the Android app's TrailIME). It talks to the text field
// through TextTarget and to the keys on screen through KeyboardSurface, so the same code runs
// in the keyboard, in the companion app's test harness, and in the tests.

import Foundation

public enum LayoutName: String {
    case letters, symbols, symbols2
}

/// A button of a prompt in the suggestion bar, and the slot tapping it reports.
public struct PromptButton: Equatable {
    public let label: String
    public let slot: Int

    public init(_ label: String, _ slot: Int) {
        self.label = label
        self.slot = slot
    }
}

/// What the typing logic asks of the keyboard on screen.
public protocol KeyboardSurface: AnyObject {
    func setLayout(_ name: LayoutName)
    func showEmoji(_ show: Bool)
    /// Empties the suggestion bar (and takes down any prompt in it).
    func clearStrip()
    func setShift(_ shifted: Bool, _ capsLock: Bool)
    /// Three suggestions, the `bold` one in the middle as a rule (-1: none), and `flag` the one
    /// shown in red as possibly misspelled (-1: none). Also takes down any prompt.
    func setSuggestions(_ a: String?, _ b: String?, _ c: String?, bold: Int, flag: Int)
    /// Your usual next words after a space (the middle one likeliest). The settings button stays
    /// reachable with these. Also takes down any prompt.
    func setNextWords(_ a: String?, _ b: String?, _ c: String?)
    /// A question in the bar with its buttons (nil takes it down).
    func setPrompt(_ text: String?, _ buttons: [PromptButton])
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
/// A prompt's buttons: Never (or Forget), Cancel, Less often.
public let PROMPT_YES = 10
public let PROMPT_NO = 11
public let PROMPT_LESS = 12
let WORD_PROMPT = [PromptButton("Less often", PROMPT_LESS), PromptButton("Never", PROMPT_YES), PromptButton("Cancel", PROMPT_NO)]
let PAIR_PROMPT = [PromptButton("Forget", PROMPT_YES), PromptButton("Cancel", PROMPT_NO)]
/// Where nothing is learned, "Less often" (a learned dislike) isn't offered.
let NEVER_PROMPT = [PromptButton("Never", PROMPT_YES), PromptButton("Cancel", PROMPT_NO)]

/// A word written only in capitals ("TM", "NASA"), not "I".
func isAllCaps(_ word: String) -> Bool {
    word.utf16.count > 1 && word == word.uppercased() && word != word.lowercased()
}

public struct TypingSettings: Codable, Equatable {
    public var swipe = true
    public var smartFix = true
    public var autocorrect = true
    public var doubleSpace = true
    public var learn = true
    /// Word pairs: learn which word you write after which, and use it.
    public var pairs = true
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
    /// Your usual next words, after a space.
    case next
    /// A word that may be misspelled (in red), with fixes, after a space.
    case flag
    /// What you typed before an automatic fix, offered after backspacing to the fixed word.
    case undo
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
    /// The prompt is about a word pair (forget it) rather than a word (less often or never).
    private var promptIsPair = false
    private var promptPrev: String?
    /// The word before the next-word suggestions.
    private var nextPrev: String?
    /// The red word: what you typed, the language then, and the word before it.
    private var flag: (literal: String, ctx: String?, prev: String?)?
    private var spaceAfterPick = false
    private var lastSpaceTime = -1e9
    private var revertFrom: String?
    private var revertTo: String?
    private var revertLang: String?
    /// The fix's language, the word before it (for word pairs), and whether what you typed
    /// started with a capital only because of sentence-start shift.
    private var revertFixLang: String?
    private var revertPrev: String?
    private var revertAutoCap = false
    /// The last tapped word committed.
    private var lastCommit: (literal: String, ctx: String?, prev: String?, changed: Bool, glued: Bool)?
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

    private func recordUse(_ word: String, _ amount: Double, _ code: String?, keepForm: Bool = false) {
        if let L = lex.get(code) { L.user.recordUse(word, amount: amount, inBaseList: inBase(word, code), keepForm: keepForm) }
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

    // ---- word pairs ----

    /// The word before the one being composed (tapped or swiped), with a space between.
    private func prevBeforeComposing() -> String? {
        wordBefore(ic.contextBefore(limit: 60, beforeComposing: true), needSpace: true)
    }

    /// The word before the cursor, with a space after it.
    private func prevAtCursor() -> String? {
        wordBefore(ic.contextBefore(limit: 60, beforeComposing: false), needSpace: true)
    }

    /// The word a swipe follows: what's before the cursor, composing or not (a space goes between).
    private func prevForSwipe() -> String? {
        wordBefore(ic.contextBefore(limit: 60, beforeComposing: false), needSpace: false)
    }

    /// What the word before says about the next one, in the language you're writing in (or nil).
    public func boostFor(_ prev: String?, _ ctx: String?) -> PairBoost? {
        guard settings.pairs, let prev = prev, !prev.isEmpty, let ctx = ctx, let L = lex.get(ctx), L.words != nil else { return nil }
        var byWord = [String: Double]()
        for p in L.user.followers(prev) where !L.user.isBlocked(p.next) {
            byWord[pairForm(p.next)] = pairBonusOf(p.count)
        }
        return byWord.isEmpty ? nil : PairBoost(lang: ctx, byWord: byWord)
    }

    private func learnPair(_ prev: String?, _ word: String?, _ amount: Double, _ code: String?) {
        guard let prev = prev, let word = word, !prev.isEmpty, !word.isEmpty, settings.pairs, learning() else { return }
        lex.get(code)?.user.recordPair(prev, word, amount: amount)
    }

    private func weakenPair(_ prev: String?, _ word: String?, _ code: String?) {
        guard let prev = prev, let word = word, !prev.isEmpty, !word.isEmpty, settings.pairs, learning() else { return }
        lex.get(code)?.user.weakenPair(prev, word)
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
        // (Not in an app that doesn't show its text: the keyboard couldn't tell what it'd replace.)
        if let from = revertFrom, revertTo != nil, ic.showsText {
            let b = ic.textBefore(utf16: from.utf16.count + 1)
            if same(b, from + " ") {
                // Back to the fixed word: the space goes as usual, and what you typed is offered.
                ic.deleteBefore(utf16: 1)
                afterGesture = false
                spaceAfterPick = false
                showUndo()
                updateShift()
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
        // The batch starts first: the text before the cursor decides the language.
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        guard let ctx = contextLang() else { return }
        let res = decoder.decode(xs, ys, count, sources(ctx), max: 8, boost: boostFor(prevForSwipe(), ctx))
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
        // Nothing tied to the old spot carries over: no double-space period, no "deleted a
        // swipe, then swiped again". (iPhone only: the JavaScript version has no such call.)
        lastSpaceTime = -1e9
        deletedGestureWord = nil
        if composing() {
            ic.finishComposingText()
            resetComposing()
            view?.clearStrip()
        } else {
            forgetSpot()
        }
        updateShift()
    }

    /// Nothing tied to the old spot carries over (a prompt that's up stays until answered).
    private func forgetSpot() {
        afterGesture = false
        spaceAfterPick = false
        revertFrom = nil
        revertTo = nil
        flag = nil
        if stripKind != .none {
            stripKind = .none
            if !(view?.hasPrompt ?? false) { view?.clearStrip() }
        }
    }

    public func onStripTap(_ slot: Int) {
        if slot == SLOT_GEAR {
            view?.openSettings()
            return
        }
        if slot == PROMPT_YES || slot == PROMPT_NO || slot == PROMPT_LESS {
            answerPrompt(slot)
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
                let prev = prevBeforeComposing()
                ic.setComposingText(chosen)
                ic.finishComposingText()
                if let cb = onCorrection, let b = base, let g = gestureBase {
                    cb(Correction(picked: b, pickedLang: lang, guess: g, guessLang: gestureLang, results: gestureResults ?? []))
                }
                if learning() {
                    if let b = base { recordUse(b, 2, lang) }
                    // Rejected while writing in gestureCtx: that's where it should come up less.
                    if let g = gestureBase { recordReject(g, gestureCtx ?? gestureLang) }
                    // After this word, the one you picked is likelier and the guess less likely.
                    learnPair(prev, base, 2, lang)
                    weakenPair(prev, gestureBase, gestureCtx ?? gestureLang)
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
            let prev = prevBeforeComposing()
            ic.setComposingText(chosen)
            ic.finishComposingText()
            if learning() {
                if same(chosen, literal) && slot == 0 {
                    // The word as you typed it, picked over the fix: kept as typed, and like an
                    // undo, it isn't fixed again.
                    if literal.utf16.count >= 2 {
                        let form = typedForm(literal, typedFirstAutoCap)
                        recordUse(form, 2, lang, keepForm: true)
                        learnPair(prev, form, 1, lang)
                    }
                } else if same(chosen, literal) {
                    if literal.utf16.count >= 2 || inBase(literal, lang) {
                        recordUse(learnForm(literal, typedFirstAutoCap, lang), 1, lang)
                        learnPair(prev, nextForm(literal, typedFirstAutoCap, lang), 1, lang)
                    }
                } else if let b = base {
                    recordUse(b, 2, lang)
                    learnPair(prev, b, 2, lang)
                }
            }
            typed = ""
            ic.commitText(" ")
            spaceAfterPick = true
            stripKind = .none
            view?.clearStrip()
            updateShift()
            showNextWords()
            return
        }
        if stripKind == .next {
            // One of your usual next words: typed with a space after (which ends any undo offer).
            let prev = nextPrev
            revertFrom = nil
            revertTo = nil
            ic.commitText(chosen + " ")
            if learning(), let b = base {
                recordUse(b, 1, lang)
                learnPair(prev, b, 1, lang)
            }
            deletedGestureWord = nil
            afterGesture = false
            spaceAfterPick = true
            stripKind = .none
            view?.clearStrip()
            updateShift()
            showNextWords()
            return
        }
        if stripKind == .flag, let f = flag {
            flag = nil
            stripKind = .none
            view?.clearStrip()
            let litLang = langOfTyped(f.literal, f.ctx)
            if slot == 0 {
                // You meant it: it counts as a word from now on.
                if learning() { recordUse(learnForm(f.literal, false, litLang), 1, litLang) }
                showNextWords()
                return
            }
            if !same(ic.textBefore(utf16: f.literal.utf16.count + 1), f.literal + " ") { return }
            ic.deleteBefore(utf16: f.literal.utf16.count + 1)
            ic.commitText(chosen + " ")
            if learning() {
                // Take back what typing it taught, and learn the fix.
                let form = learnForm(f.literal, false, litLang)
                if let L = lex.get(litLang), let e = L.user.get(form), e.added, e.uses <= 1 { L.user.remove(form) }
                weakenPair(f.prev, form, litLang)
                if let b = base {
                    recordUse(b, 2, lang)
                    learnPair(f.prev, b, 2, lang)
                }
            }
            deletedGestureWord = nil
            afterGesture = false
            spaceAfterPick = true
            updateShift()
            showNextWords()
            return
        }
        if stripKind == .undo, let from = revertFrom, let to = revertTo {
            revertFrom = nil
            revertTo = nil
            stripKind = .none
            view?.clearStrip()
            if !same(ic.textBefore(utf16: from.utf16.count), from) { return }
            if slot == 0 {
                // Put back exactly what you typed. One undo is enough: it isn't fixed again.
                ic.deleteBefore(utf16: from.utf16.count)
                ic.commitText(to + " ")
                if learning() {
                    recordReject(from, revertLang)
                    weakenPair(revertPrev, from, revertFixLang)
                    if to.utf16.count >= 2 {
                        // Kept as you typed it ("ios" stays "ios", not the list's "iOS").
                        let tl = langOfTyped(to, contextLang())
                        let form = typedForm(to, revertAutoCap)
                        recordUse(form, 2, tl, keepForm: true)
                        learnPair(revertPrev, form, 1, tl)
                    }
                }
            } else {
                ic.commitText(" ")
            }
            afterGesture = false
            spaceAfterPick = true
            updateShift()
            showNextWords()
        }
    }

    public func onStripLongPress(_ slot: Int) {
        if slot < 0 || slot > 2 { return }
        guard let candidate = stripBase[slot] else { return }
        if stripKind == .next {
            guard let prev = nextPrev else { return }
            promptIsPair = true
            promptPrev = prev
            blockCandidate = candidate
            blockLang = stripLang[slot]
            view?.setPrompt("“" + candidate + "” after “" + prev + "”", PAIR_PROMPT)
            return
        }
        promptIsPair = false
        blockCandidate = candidate
        // In the language you're writing in: a Spanish word that turned up in English stays as it
        // is for Spanish.
        blockLang = (stripKind == .gesture ? gestureCtx : nil) ?? contextLang() ?? stripLang[slot]
        let L = lex.get(blockLang)
        let place = lex.enabled().count > 1 && L != nil ? " in " + L!.name : ""
        view?.setPrompt("“" + candidate + "”" + place, learning() ? WORD_PROMPT : NEVER_PROMPT)
    }

    /// - Parameter choice: PROMPT_LESS, PROMPT_YES (never, or forget a pair) or PROMPT_NO.
    private func answerPrompt(_ choice: Int) {
        ic.beginBatchEdit()
        defer { ic.endBatchEdit() }
        let word = blockCandidate
        let code = blockLang
        blockCandidate = nil
        view?.setPrompt(nil, [])
        if promptIsPair {
            if choice == PROMPT_YES, let w = word, let prev = promptPrev {
                lex.get(code)?.user.forgetPair(prev, w)
            }
            if stripKind == .next {
                showNextWords()
            } else {
                stripKind = .none
                view?.clearStrip()
            }
            return
        }
        if choice == PROMPT_LESS, let w = word, learning() {
            // As if you'd corrected it twice; picking it yourself later brings it back.
            recordReject(w, code)
            recordReject(w, code)
        }
        if choice == PROMPT_YES, let w = word {
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
        if stripKind == .gesture {
            showGestureStrip()
        } else if stripKind == .typed {
            showTypedSuggestions()
        } else if stripKind == .flag, let f = flag, showFlag(f.literal, f.ctx, f.prev) {
            // Back to the red word (its fixes worked out again).
        } else {
            stripKind = .none
            flag = nil
            view?.clearStrip()
        }
    }

    public func dismissPrompt() {
        if blockCandidate != nil {
            blockCandidate = nil
            view?.setPrompt(nil, [])
        }
    }

    public var hasBlockPrompt: Bool { blockCandidate != nil }

    public func onEmoji(_ text: String) {
        ic.beginBatchEdit()
        finalizeAll()
        ic.commitText(text)
        ic.endBatchEdit()
        revertFrom = nil
        revertTo = nil
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
            showNextWords()
            return
        }
        if !typed.isEmpty {
            commitTyped()
            ic.commitText(" ")
            lastSpaceTime = t
            updateShift()
            if let c = lastCommit, !c.changed, !c.glued, showFlag(c.literal, c.ctx, c.prev) { return }
            showNextWords()
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
                if stripKind != .none {
                    stripKind = .none
                    view?.clearStrip()
                }
                updateShift()
                return
            }
        }
        ic.commitText(" ")
        lastSpaceTime = t
        afterGesture = false
        updateShift()
        showNextWords()
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
            let prev = prevBeforeComposing()
            let glued = gluedToNumber()
            typed = ""
            ic.finishComposingText()
            if learning() && !glued {
                let lang = langOfTyped(literal, ctx)
                let base = learnForm(literal, typedFirstAutoCap, lang)
                if isLearnable(base) && (base.utf16.count >= 2 || inBase(base, lang)) {
                    recordUse(base, 1, lang)
                    learnPair(prev, nextForm(literal, typedFirstAutoCap, lang), 1, lang)
                }
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
        let prev = prevBeforeComposing()
        ic.finishComposingText()
        if learning(), let base = gestureBase {
            recordUse(base, 1, gestureLang)
            learnPair(prev, base, 1, gestureLang)
            if let dw = deletedGestureWord, now() - deletedGestureTime < 20000, !lowerSame(dw, base) {
                // You deleted a swiped word and swiped again: the first guess was wrong.
                recordReject(dw, deletedGestureLang)
                weakenPair(prev, dw, deletedGestureLang)
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
        let prev = prevBeforeComposing()
        let glued = gluedToNumber()
        typed = ""
        let fix = decideTypedCommit(literal, ctx, prev: prev)
        let commit = fix.text
        if !same(commit, literal) {
            ic.setComposingText(commit)
            revertFrom = commit
            revertTo = literal
            revertLang = ctx
            revertFixLang = fix.lang
            revertPrev = prev
            revertAutoCap = typedFirstAutoCap
        } else {
            revertFrom = nil
            revertTo = nil
        }
        ic.finishComposingText()
        if learning() && !glued {
            let unchanged = same(commit, literal)
            let lang = unchanged ? langOfTyped(literal, ctx) : fix.lang
            let base = unchanged ? learnForm(literal, typedFirstAutoCap, lang) : baseFormOf(commit, lang)
            if isLearnable(base) && (base.utf16.count >= 2 || inBase(base, lang)) {
                recordUse(base, 1, lang)
                learnPair(prev, unchanged ? nextForm(literal, typedFirstAutoCap, lang) : base, 1, lang)
            }
        }
        lastCommit = (literal, ctx, prev, !same(commit, literal), glued)
        deletedGestureWord = nil
        stripKind = .none
        view?.clearStrip()
    }

    /// What pressing space turns the tapped word into (lang nil if unchanged).
    /// - Parameter prev: the word before it (for word pairs), if known.
    public func decideTypedCommit(_ literal: String, _ ctx: String?, prev: String? = nil) -> (text: String, lang: String?) {
        let plain = (text: literal, lang: String?.none)
        guard canSuggest, let ctx = ctx, !literal.isEmpty else { return plain }
        // Letters stuck to a number ("5th", "1st") are left as typed.
        if gluedToNumber() { return plain }
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
            // "i" -> "I", "toronto" -> "Toronto", "méxico" -> "México"; not two-letter words ("ur",
            // "ni" stay), nor a word you've put back in lower case.
            if same(literal, literal.lowercased()) && !keptLower(literal, srcs) {
                let P = primaryOf(srcs)
                for S in srcs {
                    let id = S.words.find(literal)
                    if id < 0 { continue }
                    let d = S.words.display(id)
                    if same(d, "I") { return (d, S.lang) }
                    if literal.utf16.count > 2 && !same(d, literal) && !same(d, d.uppercased()) && !Lexicon_blockedIn(S, P, d) { return (d, S.lang) }
                    break
                }
            }
        }
        // Not in fields where the app turned autocorrection off or the keyboard doesn't learn
        // (user names, addresses and the like; see setField). The JavaScript engine has no such
        // fields, so this is the one place the two differ.
        if settings.autocorrect && hostLearns && literal.utf16.count >= 2 && !srcs.contains(where: { isActiveAddedIn(literal, $0) }) {
            let listed = srcs.filter { $0.words.find(literal) >= 0 }
            let slip = !listed.isEmpty && isAbbreviationSlip(literal, listed, srcs)
            if listed.isEmpty || slip {
                let boost = prev != nil && !prev!.isEmpty ? boostFor(prev, ctx) : nil
                let fix = slip
                    ? slipFix(suggester.suggest(literal, srcs, max: 8, boost: boost, capsSlips: true), listed, literal)
                    : typoFix(suggester.suggest(literal, srcs, max: 8, boost: boost), literal)
                if let f = fix { return (withCaps(f.word, caps), f.lang) }
            }
        }
        return plain
    }

    /// The fix for a word that isn't one, or nil: the likeliest close fix, if it's clearly the
    /// likeliest, and not past a longer word starting with what you typed. Only to a lower-case
    /// word ("tmr" isn't "TM", "ahve" isn't "Ave"). How close depends on the length: three
    /// letters, one neighbouring key or two letters swapped, to a common word that beats the next
    /// fix by 1; four or five, one change; longer, up to two neighbouring keys; and those beat the
    /// next by 0.5. Words of two letters aren't fixed ("ig", "ur").
    private func typoFix(_ list: [Suggestion], _ literal: String) -> Suggestion? {
        let n = keyOf(literal).utf16.count
        let maxCost = n == 3 ? 0.7 : n <= 5 ? 0.8 : 1.0
        var near = [Suggestion]()
        for s in list {
            if s.kind == .completion { break }
            if s.kind == .exact {
                // Same letters, other accents or apostrophes ("cafe": café).
                if near.isEmpty { return s }
                break
            }
            if n < 3 || s.cost > maxCost || !same(s.word, s.word.lowercased()) { continue }
            near.append(s)
        }
        guard let best = near.first else { return nil }
        if near.count > 1 && best.score - near[1].score < (n == 3 ? 1 : 0.5) { return nil }
        if n == 3 && best.score + 1.5 * best.cost < 5 { return nil }
        return best
    }

    /// You put this lower-case word back after it was capitalized ("ios").
    private func keptLower(_ literal: String, _ srcs: [Source]) -> Bool {
        srcs.contains { S in
            guard let e = S.user.get(literal) else { return false }
            return same(e.word, literal) && e.uses > 0
        }
    }

    /// The word being typed comes right after a digit ("5th").
    private func gluedToNumber() -> Bool {
        let u = Array(ic.contextBefore(limit: 1, beforeComposing: true).utf16)
        return u.count == 1 && u[0] >= 0x30 && u[0] <= 0x39
    }

    /// A lower-case word the lists have only in capitals ("amd": AMD) that you haven't used.
    private func isAbbreviationSlip(_ literal: String, _ listed: [Source], _ srcs: [Source]) -> Bool {
        if literal.utf16.count > 4 || !same(literal, literal.lowercased()) { return false }
        for S in srcs {
            if let e = S.user.get(literal), e.uses > 0 { return false }
        }
        let key = keyOf(literal)
        for S in listed {
            for id in S.words.withKey(key) {
                let d = S.words.display(id)
                if same(d.lowercased(), literal) && !same(d, d.uppercased()) { return false }
            }
        }
        return true
    }

    /// "amd" -> "and": one neighbouring key off a word at least 100 times as common, and clearly
    /// the likeliest such word; nil if there's none.
    private func slipFix(_ list: [Suggestion], _ listed: [Source], _ literal: String) -> Suggestion? {
        // Two-letter words ("og", "ur") are left alone, like other short-word slips.
        if keyOf(literal).utf16.count < 3 { return nil }
        var own = -99.0
        for S in listed {
            let id = S.words.find(literal)
            if id >= 0 { own = max(own, Double(S.words.score(id)) / 100 + S.bias) }
        }
        let near = list.filter { $0.kind == .correction && $0.cost <= 0.5 && same($0.word, $0.word.lowercased()) }
        guard let first = near.first else { return nil }
        let z0 = first.score + 1.5 * first.cost
        if z0 - own < 2 || z0 < 5 { return nil }
        if near.count > 1 && z0 - (near[1].score + 1.5 * near[1].cost) < 1 { return nil }
        return first
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
        view?.setSuggestions(stripText[0], stripText[1], stripText[2], bold: 1, flag: -1)
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
        let prev = prevBeforeComposing()
        let fix = decideTypedCommit(literal, ctx, prev: prev)
        let onSpace = fix.text
        let list = suggester.suggest(literal, sources(ctx), max: 8, boost: boostFor(prev, ctx))
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
            view?.setSuggestions("“" + literal + "”", onSpace, stripText[2], bold: 1, flag: -1)
            return
        }
        let a0 = alts.count > 0 ? alts[0] : nil
        let a1 = alts.count > 1 ? alts[1] : nil
        setSlot(0, a0?.word, a0.map { withCaps($0.word, caps) }, a0?.lang)
        setSlot(1, literal, literal, literalLang)
        setSlot(2, a1?.word, a1.map { withCaps($0.word, caps) }, a1?.lang)
        view?.setSuggestions(stripText[0], stripText[1], stripText[2], bold: 1, flag: -1)
    }

    /// Your usual next words after the word before the cursor (or an empty bar).
    private func showNextWords() {
        let prev = canSuggest && settings.pairs ? prevAtCursor() : nil
        let ctx = prev == nil ? nil : contextLang()
        var words = [String]()
        if let p = prev, let L = lex.get(ctx), L.words != nil {
            for f in L.user.followers(p) where !L.user.isBlocked(f.next) {
                words.append(f.next)
                if words.count == 3 { break }
            }
        }
        if words.isEmpty {
            if stripKind != .none {
                stripKind = .none
                view?.clearStrip()
            }
            return
        }
        let caps = capChars || shift == SHIFT_LOCK ? 2 : shift == SHIFT_ON ? 1 : 0
        stripKind = .next
        nextPrev = prev
        // The likeliest in the middle, like the other suggestions.
        let order: [String?] = [words.count > 1 ? words[1] : nil, words[0], words.count > 2 ? words[2] : nil]
        for i in 0..<3 { setSlot(i, order[i], order[i].map { withCaps($0, caps) }, ctx) }
        view?.setNextWords(stripText[0], stripText[1], stripText[2])
    }

    /// After a space: a tapped word that isn't one (not in a list, not yours) is shown in red with
    /// the closest fixes. False (nothing shown) when it's a word or nothing is close.
    private func showFlag(_ literal: String, _ ctx: String?, _ prev: String?) -> Bool {
        // Like the automatic fixes, only in fields where the keyboard learns; and not in an app that
        // doesn't show its text (the keyboard couldn't tell what a fix would replace).
        guard canSuggest, hostLearns, ic.showsText, let ctx = ctx, literal.utf16.count >= 2, isLearnable(literal), capsOf(literal) != 2 else { return false }
        let srcs = sources(ctx)
        for S in srcs {
            if S.words.find(literal) >= 0 { return false }
            if let e = S.user.get(literal), e.uses >= NEW_WORD_ACTIVE_USES { return false }
        }
        let found = suggester.suggest(literal, srcs, max: 8, boost: boostFor(prev, ctx)).filter { !isAllCaps($0.word) }
        // Fixes one mistake away first, then the rest, each in the suggester's order.
        let fixes = found.filter { $0.kind == .correction && $0.cost <= 1.0 } + found.filter { $0.kind == .correction && $0.cost > 1.0 }
        guard let f1 = fixes.first else { return false }
        let caps = capsOf(literal)
        stripKind = .flag
        flag = (literal, ctx, prev)
        setSlot(0, nil, literal, nil)
        setSlot(1, f1.word, withCaps(f1.word, caps), f1.lang)
        let f2 = fixes.count > 1 ? fixes[1] : nil
        setSlot(2, f2?.word, f2.map { withCaps($0.word, caps) }, f2?.lang)
        view?.setSuggestions(stripText[0], stripText[1], stripText[2], bold: -1, flag: 0)
        return true
    }

    /// Backspaced to an automatically fixed word: what you typed, and the fix.
    private func showUndo() {
        guard let from = revertFrom, let to = revertTo else { return }
        stripKind = .undo
        setSlot(0, nil, to, revertLang)
        setSlot(1, nil, from, revertLang)
        setSlot(2, nil, nil, nil)
        view?.setSuggestions("“" + to + "”", from, nil, bold: 1, flag: -1)
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

    /// A word exactly as typed, less a capital that only came from sentence-start shift.
    private func typedForm(_ literal: String, _ firstFromAutoCap: Bool) -> String {
        if firstFromAutoCap && literal.utf16.count > 1 && !same(literal, literal.uppercased()) {
            let u = Array(literal.utf16)
            let first = String(decoding: u[0..<1], as: UTF16.self).lowercased()
            return first + String(decoding: u[1...], as: UTF16.self)
        }
        return literal
    }

    /// A typed word as the second word of a pair (what the next-word bar offers): the list's
    /// spelling, except capitals the list has that you didn't type ("ur", not "Ur"; "og", not "OG").
    private func nextForm(_ literal: String, _ firstFromAutoCap: Bool, _ code: String?) -> String {
        let typed = typedForm(literal, firstFromAutoCap)
        let listed = learnForm(literal, firstFromAutoCap, code)
        return same(typed, typed.lowercased()) && !same(listed, listed.lowercased()) ? typed : listed
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
