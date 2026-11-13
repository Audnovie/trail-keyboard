// Ties the keyboard together: the keys on screen (KeyboardView), the typing logic
// (InputEngine), the text field (a TextTarget), what's saved (StateStore), training rounds and
// the settings panels. The keyboard extension and the companion app's test harness both use it.

import UIKit
import TrailEngine

/// What kind of text field the keyboard is typing into.
struct FieldTraits: Equatable {
    var suggest = true
    var learn = true
    var sentenceCaps = true
    var wordCaps = false
    var allCaps = false
    var returnLabel: String?
    var dark = false
}

final class KeyboardController: KeyboardViewDelegate {
    enum Mode { case type, training }

    let view: KeyboardView
    let target: TextTarget
    let store: StateStore
    let lex = Lexicon()
    private(set) var engine: InputEngine!
    private(set) var settings = AppSettings()
    var tests = TestStats()
    private var profiles = [String: SwipeProfile]()
    private(set) var mode = Mode.type
    private(set) lazy var training = Training(self)
    private(set) var traits = FieldTraits()
    private let lexiconDir: String?
    /// Problems loading the word lists, for the settings page.
    private(set) var loadProblems = [String]()
    private var saveWork: DispatchWorkItem?
    private var changedSinceSave = false
    /// Called when the keyboard wants a different height.
    var onHeightChange: (() -> Void)?
    /// Called after anything that changes what the companion harness shows.
    var onUpdate: (() -> Void)?
    /// The settings panel, when open.
    private(set) var panel: PanelView?
    private var panelStack = [PanelPage]()
    /// A panel's one-line text box, while it's taking the keys.
    private var input: PanelInput?
    private var trainingHeader: TrainingHeaderView?
    private let clock: () -> Double
    /// A destructive button that was tapped once and needs a second tap.
    var pendingConfirm: String?
    /// What the Learned words page is filtered to, per language.
    var wordFilter = [String: String]()

    init(view: KeyboardView, target: TextTarget, store: StateStore, lexiconDir: String?,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }) {
        self.view = view
        self.target = target
        self.store = store
        self.lexiconDir = lexiconDir
        self.clock = clock
        for code in KeyboardLanguages.all {
            let L = lex.add(code)
            L.user.onChange = { [weak self] in self?.changed() }
        }
        engine = InputEngine(target: target, view: view, lex: lex, now: clock)
        engine.onCorrection = { [weak self] c in self?.onCorrection(c) }
        view.delegate = self
        applyState(store.load())
        loadWords()
        engine.start(settings.typing)
        applyLanguages()
    }

    // ---- state ----

    private func applyState(_ s: SavedState?) {
        let state = s ?? SavedState()
        for L in lex.langs {
            if let saved = state.langs[L.code] { L.user.load(saved) } else { L.user.load(nil) }
        }
        settings = s?.settings ?? AppSettings()
        tests = state.tests
        profiles = [:]
        for (key, saved) in state.profiles {
            let P = SwipeProfile()
            P.load(saved)
            if P.total > 0 { profiles[key] = P }
        }
    }

    /// Learned words kept in the saved copy, shared between the languages.
    static let savedWords = 6000

    func snapshot() -> SavedState {
        var s = SavedState()
        s.updatedAt = Date().timeIntervalSince1970 * 1000
        let cap = KeyboardController.savedWords / max(1, lex.langs.count)
        for L in lex.langs { s.langs[L.code] = L.user.saved(maxEntries: cap) }
        s.settings = settings
        s.tests = tests
        for (key, P) in profiles where P.total > 0 { s.profiles[key] = P.saved() }
        return s
    }

    /// Something worth saving changed: save soon (and refresh an open panel).
    func changed() {
        changedSinceSave = true
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        refreshPanelSoon()
        if mode == .training { renderTraining() }
        onUpdate?()
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard changedSinceSave else { return }
        changedSinceSave = false
        store.save(snapshot())
    }

    // ---- word lists and languages ----

    private func loadWords() {
        var added = false
        for L in lex.langs where L.words == nil && settings.languages.contains(L.code) {
            guard let dir = lexiconDir else {
                loadProblems.append("The word lists are missing from the keyboard.")
                break
            }
            do {
                L.words = try WordList(directory: dir, lang: L.code)
                added = true
            } catch {
                loadProblems.append("\(L.name) word list: \(error)")
            }
        }
        if added { prepareShared(lex.enabled()) }
    }

    func multilingual() -> Bool { lex.enabled().count > 1 }

    /// Switches languages on and off to match the settings.
    private func applyLanguages() {
        for L in lex.langs { L.enabled = settings.languages.contains(L.code) }
        if settings.typingLang != "auto" && !settings.languages.contains(settings.typingLang) { settings.typingLang = "auto" }
        engine.applySettings(settings.typing)
        view.swipeEnabled = mode == .training || settings.swipe
        view.spaceHold = multilingual()
        if !multilingual() { view.clearMenu() }
        updateLangLabel()
    }

    /// The language you're writing in, on the space bar and in the empty suggestion bar.
    func updateLangLabel() {
        guard mode == .type, input == nil else { return }
        if !multilingual() {
            view.setSpaceLabel("")
            view.setChip(nil)
            return
        }
        let code = engine.contextLang()
        let L = lex.get(code)
        view.setSpaceLabel(L?.name ?? "")
        view.setChip(L?.short)
        if let c = code, c != settings.lastLang {
            settings.lastLang = c
            changed()
        }
    }

    private func langItems() -> [(value: String, label: String)] {
        var items: [(value: String, label: String)] = [(value: "auto", label: "Auto")]
        for L in lex.enabled() { items.append((value: L.code, label: L.name)) }
        return items
    }

    private func openLangMenu() {
        guard multilingual(), mode == .type else { return }
        var items = [(label: String, on: Bool)]()
        for it in langItems() { items.append((label: it.label, on: it.value == settings.typingLang)) }
        view.setMenu("Language", items)
    }

    private func pickMenu(_ i: Int) {
        let items = langItems()
        view.clearMenu()
        if i >= 0 && i < items.count { setTypingLang(items[i].value) }
    }

    func setTypingLang(_ value: String) {
        settings.typingLang = value
        engine.applySettings(settings.typing)
        engine.refreshSuggestions()
        updateLangLabel()
        changed()
    }

    func setLanguageOn(_ code: String, _ on: Bool) {
        var want = settings.languages.filter { $0 != code }
        if on { want.append(code) }
        settings.languages = KeyboardLanguages.all.filter { $0 == "en" || want.contains($0) }
        loadWords()
        applyLanguages()
        engine.refreshSuggestions()
        training.rebuild()
        changed()
    }

    func setSetting(_ apply: (inout AppSettings) -> Void) {
        apply(&settings)
        engine.applySettings(settings.typing)
        view.swipeEnabled = mode == .training || settings.swipe
        applyProfile()
        changed()
    }

    // ---- swipe profiles (one per keyboard shape: upright and sideways differ) ----

    func profileKey() -> String {
        // Before the first layout there's no shape yet: use the usual upright one.
        if view.keyUnit <= 1 { return "14" }
        let ratio = Double(view.rowH / view.keyUnit)
        return String(Int(jsRoundUI(ratio * 10)))
    }

    func profile() -> SwipeProfile {
        let key = profileKey()
        if let P = profiles[key] { return P }
        let P = SwipeProfile()
        profiles[key] = P
        return P
    }

    func resetProfile() {
        profiles[profileKey()] = SwipeProfile()
        tests.rounds = 0
        tests.round = TestStats.Round()
        applyProfile()
        changed()
    }

    /// Gives the swipe reader your profile, when it's on and has enough to go on.
    func applyProfile() {
        guard view.keyUnit > 1 else { return }
        let P = profile()
        engine.decoder.setProfile(settings.useProfile && P.ready ? P.params() : nil)
    }

    // ---- the text field ----

    /// A new text field (or the keyboard just appeared).
    func fieldChanged(_ t: FieldTraits) {
        traits = t
        view.applyTheme(Theme.make(dark: t.dark))
        view.setReturnLabel(t.returnLabel)
        engine.setField(suggest: t.suggest, sentenceCaps: t.sentenceCaps || t.wordCaps, allCaps: t.allCaps, learn: t.learn)
        if mode == .type && input == nil {
            engine.start(settings.typing)
            view.swipeEnabled = settings.swipe
        }
        updateLangLabel()
    }

    /// The text or cursor moved without the keyboard (a tap in the text, or the app).
    func externalChange() {
        guard mode == .type, input == nil else { return }
        view.clearMenu()
        engine.onExternalChange()
        updateLangLabel()
        onUpdate?()
    }

    /// The keyboard is going away: keep the word in progress as it is (learning it) and save.
    func willHide() {
        if mode == .type && input == nil {
            target.beginBatchEdit()
            engine.finishAsIs()
            target.endBatchEdit()
        }
        saveNow()
    }

    private func onCorrection(_ c: Correction) {
        tests.fixes += 1
        tests.recent.insert(TestStats.Miss(w: c.picked, g: c.guess, r: rankOf(c.results, c.picked), m: "f", l: c.pickedLang), at: 0)
        if tests.recent.count > 40 { tests.recent.removeLast(tests.recent.count - 40) }
        changed()
    }

    // ---- height ----

    var headerHeight: CGFloat {
        if panel != nil { return Metrics.panelExtra }
        return mode == .training ? Metrics.trainingHeaderH : 0
    }

    // ---- KeyboardViewDelegate ----

    func kbKey(_ key: Key) {
        view.clearMenu()
        if let inp = input {
            if key.code == KeyCode.shift {
                inp.caps.toggle()
                view.setShift(inp.caps, false)
            } else if key.code == KeyCode.enter {
                finishInput(inp, commit: true)
                return
            } else {
                inp.key(key.code)
                if inp.caps {
                    inp.caps = false
                    view.setShift(false, false)
                }
            }
            renderInput()
            return
        }
        if mode == .training {
            training.onTap()
            renderTraining()
            return
        }
        engine.onKey(key.code)
        afterAction()
    }

    func kbLongPress(_ key: Key) {
        guard mode == .type, input == nil else { return }
        if key.code == KeyCode.space {
            openLangMenu()
        } else if let ch = key.alts?.first {
            engine.typeAlt(ch)
            afterAction()
        }
    }

    func kbAlt(_ ch: String) {
        view.clearMenu()
        if let inp = input {
            inp.type(ch)
            renderInput()
            return
        }
        guard mode == .type else { return }
        engine.typeAlt(ch)
        afterAction()
    }

    func kbDelete() {
        view.clearMenu()
        if let inp = input {
            inp.delete()
            renderInput()
            return
        }
        guard mode == .type else { return }
        engine.onDelete()
        afterAction()
    }

    func kbSwipe(_ xs: [Double], _ ys: [Double]) {
        view.clearMenu()
        if let inp = input {
            // A swipe in a panel's text box puts in the best guess.
            if let ctx = engine.contextLang() ?? lex.enabled().first?.code,
               let best = engine.decoder.decode(xs, ys, xs.count, engine.sources(ctx), max: 1).first {
                inp.set(best.word)
            }
            renderInput()
            return
        }
        if mode == .training {
            training.onSwipe(xs, ys)
            renderTraining()
            return
        }
        view.trailView.fade(zip(xs, ys).map { CGPoint(x: $0, y: $1) }, color: view.theme.accent, alpha: 0.7, duration: 0.2)
        engine.onSwipe(xs, ys, xs.count)
        afterAction()
    }

    func kbCursorMove(_ steps: Int) {
        view.clearMenu()
        guard mode == .type, input == nil else { return }
        engine.onCursorMove(steps)
        afterAction()
    }

    func kbStripTap(_ slot: Int) {
        if let inp = input {
            if slot == PROMPT_YES { finishInput(inp, commit: true) } else if slot == PROMPT_NO { finishInput(inp, commit: false) }
            return
        }
        if slot == MENU_CLOSE {
            view.clearMenu()
        } else if slot >= MENU_BASE {
            pickMenu(slot - MENU_BASE)
        } else if slot == LANG_CHIP {
            openLangMenu()
        } else if mode == .type {
            engine.onStripTap(slot)
            afterAction()
        }
    }

    func kbStripLongPress(_ slot: Int) {
        guard mode == .type, input == nil else { return }
        engine.onStripLongPress(slot)
    }

    func kbGeometry(_ cx: [Double], _ cy: [Double], _ kw: Double) {
        engine.onGeometry(cx, cy, kw)
        applyProfile()
        if mode == .training { renderTraining() }
    }

    func kbEmoji(_ text: String) {
        engine.onEmoji(text)
        afterAction()
    }

    func kbEmojiBack() {
        engine.onEmojiBack()
        afterAction()
    }

    func kbEmojiDelete() {
        engine.onDelete()
        afterAction()
    }

    func kbEmojiSpace() {
        engine.onKey(KeyCode.space)
        afterAction()
    }

    func kbOpenSettings() {
        openPanel(.home)
    }

    private func afterAction() {
        updateLangLabel()
        onUpdate?()
    }

    // ---- training ----

    func startTraining() {
        closePanel()
        target.beginBatchEdit()
        engine.dismissPrompt()
        engine.finalizeAll()
        target.endBatchEdit()
        mode = .training
        view.showEmoji(false)
        view.setLayout(.letters)
        view.setShift(false, false)
        view.swipeEnabled = true
        view.holdsEnabled = false
        view.setSpaceLabel("")
        view.setChip(nil)
        view.clearMenu()
        training.rebuild()
        let h = TrainingHeaderView()
        h.onSkip = { [weak self] in
            self?.training.skip()
            self?.renderTraining()
        }
        h.onUndo = { [weak self] in self?.training.undo() }
        h.onDone = { [weak self] in self?.stopTraining() }
        h.onNext = { [weak self] in self?.training.nextRound() }
        h.onLang = { [weak self] code in
            self?.training.setLang(code)
            self?.renderTraining()
        }
        trainingHeader = h
        view.header = h
        view.setHeaderHeight(Metrics.trainingHeaderH)
        onHeightChange?()
        renderTraining()
    }

    func stopTraining() {
        guard mode == .training else { return }
        mode = .type
        view.trailView.clearFades()
        view.header = nil
        trainingHeader = nil
        view.setHeaderHeight(0)
        view.holdsEnabled = true
        view.swipeEnabled = settings.swipe
        view.clearStrip()
        engine.updateShift()
        updateLangLabel()
        onHeightChange?()
        saveNow()
    }

    func renderTraining() {
        guard mode == .training, let h = trainingHeader else { return }
        let T = tests
        let R = T.round
        let done = R.n >= ROUND_SIZE
        view.setStripMessage(done ? "Round done" : (training.note ?? "Swipe the word shown above"))
        let P = profile()
        let S = P.summary()
        var profileLine: String
        if !S.ready {
            profileLine = "Swipe profile: \(S.total) of \(PROFILE_MIN_SWIPES) swipes to start"
        } else if !settings.useProfile {
            profileLine = "Swipe profile off · learned from \(S.total) swipes"
        } else {
            profileLine = "Swipe profile on · learned from \(S.total) swipes"
        }
        var langs = [(String, String)]()
        if multilingual() { for L in lex.enabled() { langs.append((L.code, L.short)) } }
        if done {
            var lines = [String]()
            if R.ab >= 5 { lines.append("With your swipe profile \(R.on) of \(R.ab) were right first time; without it, \(R.off) would have been.") }
            lines.append(contentsOf: S.ready ? Array(describeHabits(S).prefix(2)) : ["It starts adjusting to how you swipe after \(PROFILE_MIN_SWIPES) test swipes."])
            h.showDone(title: "Round \(T.rounds + 1) done", score: "\(R.top1) of \(R.n) right first time",
                       detail: lines.joined(separator: " "), profile: profileLine, progress: S.progress, theme: view.theme)
            return
        }
        var result: (text: String, good: Bool)?
        if let L = training.last {
            if L.rank == 0 {
                result = ("✓ “\(L.word)” right first time", true)
            } else {
                let got = L.res.first.map { "came out as “\($0.word)”" } ?? "wasn’t recognised"
                let place = L.rank > 0 ? ", yours was \(ordinal(L.rank + 1))" : (L.res.isEmpty ? "" : ", yours wasn’t in the top 8")
                result = ("✗ “\(L.word)” \(got)\(place)", false)
            }
        }
        let habit = training.habitText()
        h.showWord(counter: "Round \(T.rounds + 1) · word \(R.n + 1) of \(ROUND_SIZE)", word: training.current(),
                   result: result, habit: habit.isEmpty ? nil : habit, profile: profileLine, progress: S.progress,
                   canUndo: training.canUndo, langs: langs, lang: training.language().code, theme: view.theme)
    }

    // ---- panels ----

    func openPanel(_ page: PanelPage) {
        if panel == nil {
            target.beginBatchEdit()
            engine.dismissPrompt()
            engine.finalizeAll()
            target.endBatchEdit()
            let p = PanelView()
            p.onBack = { [weak self] in self?.panelBack() }
            panel = p
            view.addSubview(p)
            view.setHeaderHeight(Metrics.panelExtra)
            onHeightChange?()
        }
        panelStack.append(page)
        renderPanel()
    }

    func closePanel() {
        guard let p = panel else { return }
        p.removeFromSuperview()
        panel = nil
        panelStack = []
        view.setHeaderHeight(mode == .training ? Metrics.trainingHeaderH : 0)
        onHeightChange?()
        updateLangLabel()
        saveNow()
    }

    private func panelBack() {
        _ = panelStack.popLast()
        if panelStack.isEmpty { closePanel() } else { renderPanel() }
    }

    private var panelRefreshPending = false

    private func refreshPanelSoon() {
        guard panel != nil, !panelRefreshPending else { return }
        panelRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.panelRefreshPending = false
            self?.renderPanel()
        }
    }

    func renderPanel() {
        guard let p = panel, let page = panelStack.last else { return }
        p.frame = view.bounds
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.show(PanelPages.build(page, self), canGoBack: panelStack.count > 1, theme: view.theme)
    }

    /// Opens a one-line text box that takes the keys (to add, block or find a word).
    func beginInput(_ inp: PanelInput) {
        input = inp
        panel?.isHidden = true
        view.setHeaderHeight(0)
        onHeightChange?()
        view.setLayout(.letters)
        view.setShift(false, false)
        view.holdsEnabled = true
        renderInput()
    }

    private func renderInput() {
        guard let inp = input else { return }
        view.inputBar = (inp.label, inp.text)
        view.stripView.accessibilityValue = inp.label + " " + inp.text
    }

    private func finishInput(_ inp: PanelInput, commit: Bool) {
        input = nil
        view.inputBar = nil
        view.clearStrip()
        if commit { inp.commit(inp.text) }
        panel?.isHidden = false
        view.setHeaderHeight(panel != nil ? Metrics.panelExtra : 0)
        onHeightChange?()
        renderPanel()
    }

    // ---- what the settings show ----

    func eraseEverything() {
        for L in lex.langs {
            L.user.load(nil)
        }
        tests = TestStats()
        profiles = [:]
        settings = AppSettings()
        applyLanguages()
        applyProfile()
        store.eraseAll()
        changedSinceSave = false
        training.build()
        pendingConfirm = nil
        renderPanel()
    }
}

/// JS Math.round for the profile key.
func jsRoundUI(_ x: Double) -> Double {
    let r = x.rounded(.down)
    return x - r >= 0.5 ? r + 1 : r
}

/// A panel's one-line text box: what it's for, what's typed so far, and what to do with it.
final class PanelInput {
    let label: String
    private(set) var text = ""
    let commit: (String) -> Void
    /// The next letter in capitals (shift).
    var caps = false

    init(label: String, commit: @escaping (String) -> Void) {
        self.label = label
        self.commit = commit
    }

    func key(_ code: Int) {
        if code == KeyCode.space || code == KeyCode.enter || code <= 0 { return }
        if let u = Unicode.Scalar(UInt16(truncatingIfNeeded: code)) { type(String(Character(u))) }
    }

    func type(_ s: String) {
        if text.count < 30 { text += caps ? s.uppercased() : s }
    }

    func delete() {
        if !text.isEmpty { text.removeLast() }
    }

    func set(_ s: String) { text = s }
}
