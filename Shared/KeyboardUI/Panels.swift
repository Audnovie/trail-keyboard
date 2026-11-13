// The keyboard's own settings pages, shown inside the keyboard (the companion app can't see the
// keyboard's storage, so everything the keyboard keeps is shown and deleted here).

import UIKit
import TrailEngine

enum PanelPage: Equatable {
    case home
    case words(String)
    case blocked(String)
    case results
    case privacy
}

enum PanelRow {
    enum Style { case normal, accent, destructive }

    case toggle(id: String, title: String, detail: String?, on: Bool, set: (Bool) -> Void)
    case choice(id: String, title: String, options: [(value: String, label: String)], selected: String, pick: (String) -> Void)
    case action(id: String, title: String, style: Style, run: () -> Void)
    case link(id: String, title: String, value: String?, open: () -> Void)
    case text(id: String?, String)
    case word(id: String, title: String, detail: String?, button: String?, run: (() -> Void)?)
}

struct PanelSection {
    var title: String?
    var rows: [PanelRow]
}

struct PanelContent {
    var title: String
    var sections: [PanelSection]
}

/// The process's memory as iOS counts it against a keyboard (phys_footprint), in MB.
func memoryInUseMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

private func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

private func formatCount(_ uses: Double) -> String {
    abs(uses - uses.rounded()) < 0.05 ? String(Int(uses.rounded())) : String(format: "%.1f", uses)
}

enum PanelPages {
    static func build(_ page: PanelPage, _ c: KeyboardController) -> PanelContent {
        switch page {
        case .home: return home(c)
        case .words(let code): return words(c, code)
        case .blocked(let code): return blocked(c, code)
        case .results: return results(c)
        case .privacy: return privacy(c)
        }
    }

    /// A destructive action that needs a second tap.
    private static func confirming(_ c: KeyboardController, id: String, title: String, confirm: String, run: @escaping () -> Void) -> PanelRow {
        if c.pendingConfirm == id {
            return .action(id: id, title: confirm, style: .destructive) {
                c.pendingConfirm = nil
                run()
                c.renderPanel()
            }
        }
        return .action(id: id, title: title, style: .destructive) {
            c.pendingConfirm = id
            c.renderPanel()
        }
    }

    private static func home(_ c: KeyboardController) -> PanelContent {
        let s = c.settings
        var sections = [PanelSection]()
        let P = c.profile()
        let S = P.summary()
        var status: String
        if S.total == 0 {
            status = "No training swipes yet. A round is 20 words; each swipe teaches the keyboard how you swipe."
        } else if !S.ready {
            status = "Learned from \(plural(S.total, "training swipe", "training swipes")). It starts adjusting at \(PROFILE_MIN_SWIPES)."
        } else {
            status = "Learned from \(S.total) training swipes."
        }
        if S.total > 0 && S.total < PROFILE_FULL_SWIPES { status += " It keeps improving until about \(PROFILE_FULL_SWIPES)." }
        var trainRows: [PanelRow] = [
            .action(id: "train.start", title: "Start a training round", style: .accent) { c.startTraining() },
            .text(id: "train.status", status),
        ]
        for line in describeHabits(S) { trainRows.append(.text(id: nil, "• " + line)) }
        if S.ab.n >= 10 {
            let pct = { (v: Double) in "\(Int((100 * v / S.ab.n).rounded()))%" }
            trainRows.append(.text(id: nil, "Training swipes since it switched on (\(Int(S.ab.n))): \(pct(S.ab.on)) right first time with it, \(pct(S.ab.off)) without it."))
        }
        trainRows.append(.toggle(id: "opt.profile", title: "Use my swipe profile", detail: nil, on: s.useProfile) { v in c.setSetting { $0.useProfile = v } })
        trainRows.append(.link(id: "link.results", title: "Training results", value: c.tests.n > 0 ? "\(c.tests.n) swipes" : nil) { c.openPanel(.results) })
        if S.total > 0 {
            trainRows.append(confirming(c, id: "train.reset", title: "Reset swipe profile", confirm: "Tap again: forget how you swipe") { c.resetProfile() })
        }
        sections.append(PanelSection(title: "Swipe training", rows: trainRows))
        var wordRows = [PanelRow]()
        for L in c.lex.langs where L.enabled {
            let suffix = c.multilingual() ? " · \(L.name)" : ""
            wordRows.append(.link(id: "link.words.\(L.code)", title: "Learned words" + suffix, value: String(L.user.count)) {
                c.openPanel(.words(L.code))
            })
            wordRows.append(.link(id: "link.blocked.\(L.code)", title: "Never suggest" + suffix, value: String(L.user.blockedWords().count)) {
                c.openPanel(.blocked(L.code))
            })
        }
        sections.append(PanelSection(title: "Your words", rows: wordRows))
        sections.append(PanelSection(title: "Typing", rows: [
            .toggle(id: "opt.swipe", title: "Swipe typing", detail: nil, on: s.swipe) { v in c.setSetting { $0.swipe = v } },
            .toggle(id: "opt.smart", title: "Smart fixes", detail: "dont → don’t, i → I, tambien → también", on: s.smartFix) { v in c.setSetting { $0.smartFix = v } },
            .toggle(id: "opt.auto", title: "Fix typos automatically", detail: "When you press space after a word that isn’t one", on: s.autocorrect) { v in c.setSetting { $0.autocorrect = v } },
            .toggle(id: "opt.double", title: "Double space types a period", detail: nil, on: s.doubleSpace) { v in c.setSetting { $0.doubleSpace = v } },
            .toggle(id: "opt.learn", title: "Learn from my typing", detail: "Off: nothing new is remembered", on: s.learn) { v in c.setSetting { $0.learn = v } },
        ]))
        var langRows: [PanelRow] = [
            .toggle(id: "opt.spanish", title: "Español", detail: "Its own word list, learned words and never-suggest list", on: s.languages.contains("es")) { v in
                c.setLanguageOn("es", v)
            },
        ]
        if c.multilingual() {
            let options = [("auto", "Auto")] + c.lex.enabled().map { ($0.code, $0.name) }
            langRows.append(.choice(id: "opt.typingLang", title: "Writing in", options: options, selected: s.typingLang) { v in c.setTypingLang(v) })
            langRows.append(.text(id: nil, "Auto picks the language from the words before the cursor. Hold the space bar to switch."))
        }
        sections.append(PanelSection(title: "Languages", rows: langRows))
        var about: [PanelRow] = [
            .link(id: "link.privacy", title: "What the keyboard keeps", value: nil) { c.openPanel(.privacy) },
        ]
        for p in c.loadProblems { about.append(.text(id: nil, "⚠︎ " + p)) }
        if let p = c.store.problem { about.append(.text(id: "store.problem", "⚠︎ " + p)) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        about.append(.text(id: "about.memory", String(format: "Trail %@ · using %.1f MB of memory", version, memoryInUseMB())))
        sections.append(PanelSection(title: "About", rows: about))
        return PanelContent(title: "Trail settings", sections: sections)
    }

    private static func words(_ c: KeyboardController, _ code: String) -> PanelContent {
        guard let L = c.lex.get(code) else { return PanelContent(title: "", sections: []) }
        let multi = c.multilingual()
        let all = L.user.all()
        let q = (c.wordFilter[code] ?? "").lowercased()
        var top: [PanelRow] = [
            .action(id: "words.add", title: multi ? "Add a word to \(L.name)" : "Add a word", style: .accent) {
                c.beginInput(PanelInput(label: multi ? "Add to \(L.name):" : "Add:") { w in
                    if L.user.addManual(w) { L.user.setInBaseList(w, (L.words?.find(w) ?? -1) >= 0) }
                })
            },
            .action(id: "words.find", title: "Find a word", style: .normal) {
                c.beginInput(PanelInput(label: "Find:") { w in c.wordFilter[code] = w.trimmingCharacters(in: .whitespaces) })
            },
        ]
        if !q.isEmpty {
            top.append(.action(id: "words.showAll", title: "Showing words with “\(q)” · show all", style: .normal) {
                c.wordFilter[code] = nil
                c.renderPanel()
            })
        }
        var rows = [PanelRow]()
        var shown = 0
        var matching = 0
        for e in all {
            if !q.isEmpty && !e.word.lowercased().contains(q) { continue }
            matching += 1
            if shown >= 300 { continue }
            shown += 1
            var detail = "used \(formatCount(e.uses))×"
            if e.rejects > 0 { detail += " · rejected \(e.rejects)×" }
            if e.added { detail += e.active ? " · your word" : " · new, suggested after 2 uses" }
            rows.append(.word(id: "word.\(e.word)", title: e.word, detail: detail, button: "Remove") { L.user.remove(e.word) })
        }
        if matching > shown {
            rows.append(.text(id: nil, "Showing \(shown) of \(matching). Use Find for the others."))
        } else if all.isEmpty {
            rows.append(.text(id: "words.empty", multi ? "No \(L.name) words yet. They show up here as you type." : "Nothing yet. Words show up here as you type."))
        } else if matching == 0 {
            rows.append(.text(id: nil, "No learned words match “\(q)”."))
        }
        var sections = [PanelSection(title: nil, rows: top),
                        PanelSection(title: all.isEmpty ? nil : "\(plural(all.count, "word", "words")), most used first", rows: rows)]
        if !all.isEmpty {
            let what = multi ? "\(L.name) words" : "words"
            sections.append(PanelSection(title: nil, rows: [
                confirming(c, id: "words.clear", title: "Clear learned \(what)", confirm: "Tap again: delete all \(all.count) learned \(what)") { L.user.clearLearned() },
                .text(id: nil, multi ? "Your \(L.name) never-suggest list stays." : "Your never-suggest list stays."),
            ]))
        }
        return PanelContent(title: multi ? "Learned · \(L.name)" : "Learned words", sections: sections)
    }

    private static func blocked(_ c: KeyboardController, _ code: String) -> PanelContent {
        guard let L = c.lex.get(code) else { return PanelContent(title: "", sections: []) }
        let multi = c.multilingual()
        let words = L.user.blockedWords()
        var rows = [PanelRow]()
        for w in words {
            rows.append(.word(id: "blocked.\(w)", title: w, detail: nil, button: "Unblock") { L.user.unblock(w) })
        }
        if words.isEmpty { rows.append(.text(id: nil, "Nothing blocked.")) }
        let note = multi
            ? "These never come up as suggestions or swipe results while you write in \(L.name). Holding a suggestion on the keyboard adds it to the list for the language you’re writing in."
            : "These never come up as suggestions or swipe results. Hold any suggestion on the keyboard to add it here."
        return PanelContent(title: multi ? "Never suggest · \(L.name)" : "Never suggest", sections: [
            PanelSection(title: nil, rows: [
                .action(id: "blocked.add", title: multi ? "Block a word in \(L.name)" : "Block a word", style: .accent) {
                    c.beginInput(PanelInput(label: "Never suggest:") { w in L.user.block(w) })
                },
                .text(id: nil, note),
            ]),
            PanelSection(title: plural(words.count, "word", "words"), rows: rows),
        ])
    }

    private static func results(_ c: KeyboardController) -> PanelContent {
        let T = c.tests
        let pct = { (v: Int) in T.n > 0 ? "\(Int((100 * Double(v) / Double(T.n)).rounded()))%" : "–" }
        var rows: [PanelRow] = [
            .text(id: "results.totals", "\(plural(T.n, "training swipe", "training swipes")) · \(pct(T.top1)) right first try · \(pct(T.top3)) in the top 3 · \(plural(T.fixes, "swipe", "swipes")) fixed while typing"),
        ]
        var misses = [PanelRow]()
        for r in T.recent {
            var what = r.g.isEmpty ? "wasn’t recognised" : "came out as “\(r.g)”"
            if r.m == "f" { what += ", fixed while typing" }
            else if r.r > 0 { what += ", yours was \(ordinal(r.r + 1))" }
            else if !r.g.isEmpty { what += ", not in the top 8" }
            if c.multilingual(), let l = r.l, let L = c.lex.get(l) { what += " · \(L.name)" }
            misses.append(.word(id: "miss.\(misses.count)", title: r.w, detail: what, button: nil, run: nil))
        }
        if misses.isEmpty { misses.append(.text(id: nil, T.n > 0 ? "No misses so far." : "Start a training round to see how often it gets your swipes right.")) }
        if T.n > 0 || T.fixes > 0 || !T.recent.isEmpty {
            rows.append(confirming(c, id: "results.clear", title: "Clear training results", confirm: "Tap again: delete all training results") {
                c.tests = TestStats()
                c.changed()
            })
        }
        return PanelContent(title: "Training results", sections: [
            PanelSection(title: nil, rows: rows),
            PanelSection(title: "Recent misses, newest first", rows: misses),
        ])
    }

    private static func privacy(_ c: KeyboardController) -> PanelContent {
        let size = c.store.fileSize
        let kb = size > 0 ? String(format: "%.1f KB", Double(size) / 1024) : "nothing saved yet"
        return PanelContent(title: "What the keyboard keeps", sections: [
            PanelSection(title: nil, rows: [
                .text(id: "privacy.where", "Everything Trail learns stays inside the keyboard on this iPhone: the single words you use and how often, words you rejected or blocked, your swipe profile (running averages, never the swipes themselves), training results and these settings. All of it is on these pages, and you can delete any of it."),
                .text(id: "privacy.network", "Trail can’t connect to anything: Full Access is off, so iOS gives it no network access. Nothing is sent anywhere."),
                .text(id: "privacy.text", "It doesn’t keep what you write: no sentences, no history, no swipes. It only counts single words, and only in ordinary text fields. In email, web address, username, code, phone, address and card fields it doesn’t learn at all, and password fields always use Apple’s keyboard."),
                .text(id: "privacy.backup", "The saved file (\(kb)) is left out of iCloud and computer backups, so it never leaves this iPhone."),
            ]),
            PanelSection(title: nil, rows: [
                confirming(c, id: "privacy.erase", title: "Erase everything Trail learned", confirm: "Tap again: erase all words, lists, training and settings") {
                    c.eraseEverything()
                },
            ]),
        ])
    }
}

/// Shows a page: a bar with Back (or Done) and the title, and the rows in a scrolling list.
final class PanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onBack: (() -> Void)?
    private let bar = UIView()
    private let back = UIButton(type: .system)
    private let title = UILabel()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var content = PanelContent(title: "", sections: [])
    private var theme = Theme.make(dark: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "trail.panel"
        addSubview(table)
        addSubview(bar)
        bar.addSubview(back)
        bar.addSubview(title)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textAlignment = .center
        back.titleLabel?.font = .systemFont(ofSize: 16)
        back.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
        back.accessibilityIdentifier = "panel.back"
        table.dataSource = self
        table.delegate = self
        table.estimatedRowHeight = 44
        table.rowHeight = UITableView.automaticDimension
        table.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        table.accessibilityIdentifier = "panel.table"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barH: CGFloat = 40
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barH)
        back.frame = CGRect(x: 6, y: 0, width: 80, height: barH)
        title.frame = CGRect(x: 90, y: 0, width: bounds.width - 180, height: barH)
        table.frame = CGRect(x: 0, y: barH, width: bounds.width, height: bounds.height - barH)
    }

    func show(_ c: PanelContent, canGoBack: Bool, theme t: Theme) {
        theme = t
        content = c
        backgroundColor = t.panel
        bar.backgroundColor = t.panel
        table.backgroundColor = t.panel
        title.textColor = t.text
        title.text = c.title
        back.setTitle(canGoBack ? "‹ Back" : "Done", for: .normal)
        back.tintColor = t.accent
        table.overrideUserInterfaceStyle = t.dark ? .dark : .light
        table.reloadData()
    }

    @objc private func tapBack() { onBack?() }

    func numberOfSections(in tableView: UITableView) -> Int { content.sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { content.sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { content.sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let row = content.sections[ip.section].rows[ip.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = theme.panelRow
        cell.textLabel?.textColor = theme.text
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = theme.stripDim
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        switch row {
        case .toggle(let id, let title, let detail, let on, let set):
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = detail
            let sw = UISwitch()
            sw.isOn = on
            sw.accessibilityIdentifier = id
            sw.addAction(UIAction { [weak sw] _ in set(sw?.isOn ?? false) }, for: .valueChanged)
            cell.accessoryView = sw
            cell.accessibilityIdentifier = id + ".row"
        case .choice(let id, let title, let options, let selected, let pick):
            cell.textLabel?.text = title
            let seg = UISegmentedControl(items: options.map { $0.label })
            seg.selectedSegmentIndex = options.firstIndex { $0.value == selected } ?? 0
            seg.accessibilityIdentifier = id
            seg.addAction(UIAction { [weak seg] _ in
                guard let i = seg?.selectedSegmentIndex, i >= 0, i < options.count else { return }
                pick(options[i].value)
            }, for: .valueChanged)
            seg.sizeToFit()
            cell.accessoryView = seg
        case .action(let id, let title, let style, _):
            cell.textLabel?.text = title
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.textColor = style == .destructive ? theme.bad : (style == .accent ? theme.accent : theme.text)
            cell.textLabel?.font = .systemFont(ofSize: 16, weight: style == .accent ? .semibold : .regular)
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = id
            cell.accessibilityTraits = .button
        case .link(let id, let title, let value, _):
            cell.textLabel?.text = title
            cell.accessoryType = .disclosureIndicator
            if let v = value {
                let l = UILabel()
                l.text = v
                l.textColor = theme.stripDim
                l.sizeToFit()
                cell.accessoryView = l
            }
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = id
        case .text(let id, let text):
            cell.textLabel?.text = text
            cell.textLabel?.font = .systemFont(ofSize: 13)
            cell.textLabel?.textColor = theme.stripDim
            if let id = id { cell.accessibilityIdentifier = id }
        case .word(let id, let title, let detail, let button, let run):
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = detail
            cell.accessibilityIdentifier = id
            if let b = button, let run = run {
                let btn = UIButton(type: .system)
                btn.setTitle(b, for: .normal)
                btn.tintColor = theme.accent
                btn.accessibilityIdentifier = id + ".button"
                btn.addAction(UIAction { _ in run() }, for: .touchUpInside)
                btn.sizeToFit()
                cell.accessoryView = btn
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch content.sections[ip.section].rows[ip.row] {
        case .action(_, _, _, let run): run()
        case .link(_, _, _, let open): open()
        default: break
        }
    }
}

/// Above the suggestion bar while training: the word to swipe, how the last one went, and the
/// round so far.
final class TrainingHeaderView: UIView {
    var onSkip: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?
    var onNext: (() -> Void)?
    var onLang: ((String) -> Void)?
    private let counter = UILabel()
    private let word = UILabel()
    private let result = UILabel()
    private let profile = UILabel()
    private let bar = UIView()
    private let barFill = UIView()
    private let skip = UIButton(type: .system)
    private let undo = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private let next = UIButton(type: .system)
    private var langButtons = [UIButton]()
    private var progress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "trail.training"
        counter.font = .systemFont(ofSize: 12)
        word.font = .systemFont(ofSize: 26, weight: .semibold)
        word.textAlignment = .center
        word.adjustsFontSizeToFitWidth = true
        word.minimumScaleFactor = 0.6
        word.accessibilityIdentifier = "training.word"
        result.font = .systemFont(ofSize: 12)
        result.textAlignment = .center
        result.numberOfLines = 1
        result.adjustsFontSizeToFitWidth = true
        result.minimumScaleFactor = 0.75
        result.accessibilityIdentifier = "training.result"
        profile.font = .systemFont(ofSize: 11)
        profile.accessibilityIdentifier = "training.profile"
        for (b, t, id) in [(skip, "Skip", "training.skip"), (undo, "Undo", "training.undo"), (done, "Done", "training.done"), (next, "Next round", "training.next")] {
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: b === next ? .semibold : .regular)
            b.accessibilityIdentifier = id
            addSubview(b)
        }
        skip.addAction(UIAction { [weak self] _ in self?.onSkip?() }, for: .touchUpInside)
        undo.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        next.addAction(UIAction { [weak self] _ in self?.onNext?() }, for: .touchUpInside)
        for v in [counter, word, result, profile, bar] as [UIView] { addSubview(v) }
        bar.addSubview(barFill)
        bar.layer.cornerRadius = 1
        barFill.layer.cornerRadius = 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        done.frame = CGRect(x: w - 54, y: 2, width: 50, height: 26)
        undo.frame = CGRect(x: w - 108, y: 2, width: 50, height: 26)
        skip.frame = CGRect(x: w - 162, y: 2, width: 50, height: 26)
        next.frame = CGRect(x: w - 154, y: 2, width: 96, height: 26)
        var x: CGFloat = 10
        for b in langButtons {
            b.frame = CGRect(x: x, y: 2, width: 34, height: 26)
            x += 36
        }
        counter.frame = CGRect(x: x + 4, y: 2, width: max(0, w - x - 170), height: 26)
        word.frame = CGRect(x: 8, y: 28, width: w - 16, height: 32)
        result.frame = CGRect(x: 8, y: 60, width: w - 16, height: 16)
        profile.frame = CGRect(x: 10, y: 76, width: w - 20, height: 14)
        bar.frame = CGRect(x: 10, y: 92, width: w - 20, height: 2)
        barFill.frame = CGRect(x: 0, y: 0, width: bar.bounds.width * progress, height: 2)
    }

    private func style(_ t: Theme) {
        backgroundColor = t.background
        for l in [counter, profile] { l.textColor = t.stripDim }
        word.textColor = t.text
        bar.backgroundColor = t.divider
        barFill.backgroundColor = t.accent
        for b in [skip, undo, done, next] { b.tintColor = t.accent }
    }

    private func setLangs(_ langs: [(String, String)], _ current: String, _ t: Theme) {
        for b in langButtons { b.removeFromSuperview() }
        langButtons = langs.map { code, short in
            let b = UIButton(type: .system)
            b.setTitle(short, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: code == current ? .bold : .regular)
            b.tintColor = code == current ? t.text : t.stripDim
            b.accessibilityIdentifier = "training.lang.\(code)"
            b.addAction(UIAction { [weak self] _ in self?.onLang?(code) }, for: .touchUpInside)
            addSubview(b)
            return b
        }
    }

    func showWord(counter c: String, word w: String, result r: (text: String, good: Bool)?, habit: String?, profile p: String,
                  progress pr: Double, canUndo: Bool, langs: [(String, String)], lang: String, theme t: Theme) {
        style(t)
        setLangs(langs, lang, t)
        counter.text = c
        word.text = w
        if let r = r {
            result.text = r.text + (habit.map { " · " + $0 } ?? "")
            result.textColor = r.good ? t.good : t.bad
        } else {
            result.text = habit ?? "Swipe it on the keys below, then the next word appears."
            result.textColor = t.stripDim
        }
        profile.text = p
        progress = CGFloat(pr)
        skip.isHidden = false
        undo.isHidden = false
        undo.isEnabled = canUndo
        next.isHidden = true
        setNeedsLayout()
    }

    func showDone(title: String, score: String, detail: String, profile p: String, progress pr: Double, theme t: Theme) {
        style(t)
        setLangs([], "", t)
        counter.text = title
        word.text = score
        result.text = detail
        result.textColor = t.stripDim
        profile.text = p
        progress = CGFloat(pr)
        skip.isHidden = true
        undo.isHidden = true
        next.isHidden = false
        setNeedsLayout()
    }
}
