// The emoji panel, laid out like Apple's: a search box at the top, the emoji in columns that
// scroll sideways through the categories, and ABC, the categories and delete along the bottom.

import UIKit
import TrailEngine

final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onEmoji: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSearch: (() -> Void)?
    let catalog: EmojiCatalog?
    /// Recently used emoji, newest first (shown as the first page when there are any).
    var recent: [String] = [] {
        didSet {
            if recent != oldValue { grid.reloadData(); layoutBar() }
        }
    }

    private let grid: UICollectionView
    private let flow: UICollectionViewFlowLayout
    private let search = UIButton(type: .custom)
    private let bar = UIView()
    private let abc = UIButton(type: .system)
    private let del = UIButton(type: .system)
    private var catButtons = [UIButton]()
    private var selectedCat = -1
    private var repeatWork: DispatchWorkItem?
    private var repeatCount = 0
    private var theme = Theme.make(dark: false)

    /// SF Symbols for the categories (recent first), with an emoji where an older iOS lacks one.
    private static let icons: [(symbol: String, fallback: String, name: String)] = [
        ("clock", "🕘", "Recent"), ("face.smiling", "😀", "Smileys and people"), ("pawprint", "🐻", "Animals and nature"),
        ("fork.knife", "🍔", "Food and drink"), ("soccerball", "⚽", "Activity"), ("car", "🚗", "Travel and places"),
        ("lightbulb", "💡", "Objects"), ("heart", "❤️", "Symbols"), ("flag", "🏳️", "Flags"),
    ]

    /// Read once and kept (a few hundred KB), so opening the panel doesn't read it again.
    private static let shared: EmojiCatalog? = {
        let path = Bundle.main.path(forResource: "Emoji", ofType: nil).map { $0 + "/emoji.tsv" }
        let newest = EmojiCatalog.newestVersion(iOS: ProcessInfo.processInfo.operatingSystemVersion)
        return path.flatMap { EmojiCatalog(path: $0, newest: newest) }
    }()

    override init(frame: CGRect) {
        catalog = EmojiPanel.shared
        let f = UICollectionViewFlowLayout()
        f.scrollDirection = .horizontal
        f.minimumInteritemSpacing = 0
        f.minimumLineSpacing = 0
        flow = f
        grid = UICollectionView(frame: .zero, collectionViewLayout: f)
        super.init(frame: frame)
        grid.dataSource = self
        grid.delegate = self
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        grid.accessibilityIdentifier = "trail.emoji"
        addSubview(grid)

        search.accessibilityIdentifier = "trail.emoji.search"
        search.accessibilityLabel = "Search emoji"
        search.layer.cornerRadius = 10
        search.contentHorizontalAlignment = .left
        search.titleLabel?.font = .systemFont(ofSize: 17)
        search.setTitle("  Search emoji", for: .normal)
        search.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        search.addTarget(self, action: #selector(searchTap), for: .touchUpInside)
        addSubview(search)

        addSubview(bar)
        abc.setTitle("ABC", for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        abc.accessibilityIdentifier = "trail.emoji.abc"
        abc.addTarget(self, action: #selector(back), for: .touchUpInside)
        bar.addSubview(abc)
        del.setImage(UIImage(systemName: "delete.left"), for: .normal)
        del.accessibilityLabel = "Delete"
        del.accessibilityIdentifier = "trail.emoji.delete"
        del.addTarget(self, action: #selector(delDown), for: .touchDown)
        del.addTarget(self, action: #selector(delUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bar.addSubview(del)
        for (i, ic) in EmojiPanel.icons.enumerated() {
            let b = UIButton(type: .system)
            if let img = UIImage(systemName: ic.symbol) {
                b.setImage(img, for: .normal)
            } else {
                b.setTitle(ic.fallback, for: .normal)
            }
            b.tag = i
            b.accessibilityLabel = ic.name
            b.accessibilityIdentifier = "trail.emoji.cat\(i)"
            b.layer.cornerRadius = 14
            b.addTarget(self, action: #selector(catTap(_:)), for: .touchUpInside)
            bar.addSubview(b)
            catButtons.append(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ t: Theme) {
        theme = t
        backgroundColor = t.background
        search.backgroundColor = t.key
        search.setTitleColor(t.hint, for: .normal)
        search.tintColor = t.hint
        for b in [abc, del] + catButtons {
            b.setTitleColor(t.text, for: .normal)
            b.tintColor = t.hint
        }
        abc.tintColor = t.text
        del.tintColor = t.text
        highlight(selectedCat)
    }

    // ---- sections: the recent page (when there is one), then Apple's categories ----

    private var hasRecent: Bool { !recent.isEmpty }

    /// The category button (0 is recent) for a grid section, and back.
    private func cat(forSection s: Int) -> Int { hasRecent ? s : s + 1 }
    private func section(forCat c: Int) -> Int? {
        if c == 0 { return hasRecent ? 0 : nil }
        return hasRecent ? c : c - 1
    }

    func numberOfSections(in cv: UICollectionView) -> Int {
        EmojiCatalog.categories.count + (hasRecent ? 1 : 0)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let c = cat(forSection: section)
        if c == 0 { return recent.count }
        return catalog?.sections[c - 1].count ?? 0
    }

    private func emoji(at ip: IndexPath) -> String? {
        let c = cat(forSection: ip.section)
        if c == 0 { return ip.item < recent.count ? recent[ip.item] : nil }
        guard let cat = catalog, ip.item < cat.sections[c - 1].count else { return nil }
        return cat.items[cat.sections[c - 1][ip.item]].emoji
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
        let e = emoji(at: ip) ?? ""
        c.label.text = e
        c.accessibilityLabel = e
        return c
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        guard let e = emoji(at: ip) else { return }
        UIDevice.current.playInputClick()
        onEmoji?(e)
    }

    // ---- layout ----

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let top = Metrics.stripH
        let barH = Metrics.stripH
        search.frame = CGRect(x: 0, y: 0, width: w, height: top).insetBy(dx: 8, dy: 5)
        let gridH = max(0, bounds.height - top - barH)
        grid.frame = CGRect(x: 0, y: top, width: w, height: gridH)
        bar.frame = CGRect(x: 0, y: bounds.height - barH, width: w, height: barH)
        let rows = max(2, min(5, Int(gridH / 40)))
        let side = floor(gridH / CGFloat(rows))
        if flow.itemSize.height != side && side > 0 {
            flow.itemSize = CGSize(width: side, height: side)
            flow.sectionInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 12)
            flow.invalidateLayout()
        }
        layoutBar()
    }

    private func layoutBar() {
        let w = bar.bounds.width
        let h = bar.bounds.height
        guard w > 0 else { return }
        let sideW = min(64, w * 0.15)
        abc.frame = CGRect(x: 2, y: 0, width: sideW, height: h)
        del.frame = CGRect(x: w - sideW - 2, y: 0, width: sideW, height: h)
        let shown = catButtons.filter { $0.tag != 0 || hasRecent }
        for b in catButtons { b.isHidden = !shown.contains(b) }
        let span = del.frame.minX - abc.frame.maxX
        let cell = span / CGFloat(max(1, shown.count))
        for (i, b) in shown.enumerated() {
            let size = min(cell - 2, 28)
            b.frame = CGRect(x: abc.frame.maxX + CGFloat(i) * cell + (cell - size) / 2, y: (h - size) / 2, width: size, height: size)
        }
        updateSelected()
    }

    // ---- following the scroll; jumping to a category ----

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSelected()
    }

    private func updateSelected() {
        let probe = CGPoint(x: grid.contentOffset.x + 8, y: max(1, flow.itemSize.height / 2))
        let s = grid.indexPathForItem(at: probe)?.section
            ?? grid.indexPathsForVisibleItems.map(\.section).min()
            ?? 0
        highlight(cat(forSection: s))
    }

    private func highlight(_ c: Int) {
        selectedCat = c
        for b in catButtons {
            let on = b.tag == c
            b.backgroundColor = on ? theme.fnKey : .clear
            b.tintColor = on ? theme.text : theme.hint
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    @objc private func catTap(_ b: UIButton) {
        guard let s = section(forCat: b.tag), s < grid.numberOfSections else { return }
        UIDevice.current.playInputClick()
        if grid.numberOfItems(inSection: s) > 0 {
            grid.scrollToItem(at: IndexPath(item: 0, section: s), at: .left, animated: false)
            // The section's left inset stays in view.
            grid.contentOffset.x = max(0, grid.contentOffset.x - flow.sectionInset.left)
        }
        highlight(b.tag)
    }

    /// Back to the first page (recent, or Smileys & People).
    func scrollToStart() {
        grid.setContentOffset(.zero, animated: false)
        updateSelected()
    }

    // ---- buttons ----

    @objc private func searchTap() { onSearch?() }
    @objc private func back() { onBack?() }

    @objc private func delDown() {
        repeatCount = 0
        onDelete?()
        schedule(Metrics.repeatStart)
    }

    @objc private func delUp() {
        repeatWork?.cancel()
        repeatWork = nil
    }

    private func schedule(_ delay: Double) {
        repeatWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.repeatWork != nil else { return }
            self.onDelete?()
            self.repeatCount += 1
            self.schedule(self.repeatCount > 20 ? Metrics.repeatFast : Metrics.repeatEvery)
        }
        repeatWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

final class EmojiCell: UICollectionViewCell {
    let label = EmojiLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: Metrics.emojiFont)
        contentView.addSubview(label)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }
}

/// An emoji drawn at a fixed number of pixels (Metrics.emojiScale), whatever the screen, so the
/// pictures iOS keeps of drawn emoji stay small.
final class EmojiLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyScale()
    }

    private func applyScale() {
        let screen = traitCollection.displayScale > 0 ? traitCollection.displayScale : Metrics.emojiScale
        let s = min(Metrics.emojiScale, screen)
        if contentScaleFactor != s { contentScaleFactor = s }
    }
}
