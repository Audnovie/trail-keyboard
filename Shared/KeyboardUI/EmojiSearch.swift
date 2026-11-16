// Searching emoji, as on Apple's keyboard: the search box at the top, the matching emoji in a
// row under it (where the suggestions usually are), and the letter keys typing the search.

import UIKit

/// The search box shown above the results while the keys type into it.
final class EmojiSearchField: UIView {
    var onClose: (() -> Void)?
    private let box = UIView()
    private let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let text = UILabel()
    private let close = UIButton(type: .system)
    private var theme = Theme.make(dark: false)
    private var query = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.layer.cornerRadius = 10
        addSubview(box)
        box.addSubview(glass)
        text.font = .systemFont(ofSize: 17)
        text.lineBreakMode = .byTruncatingHead
        box.addSubview(text)
        close.setTitle("Done", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        close.accessibilityIdentifier = "trail.emoji.searchDone"
        close.addTarget(self, action: #selector(closeTap), for: .touchUpInside)
        addSubview(close)
        isAccessibilityElement = false
        text.isAccessibilityElement = true
        text.accessibilityIdentifier = "trail.emoji.query"
        render()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ t: Theme) {
        theme = t
        backgroundColor = t.background
        box.backgroundColor = t.key
        glass.tintColor = t.hint
        close.tintColor = t.accent
        render()
    }

    func setQuery(_ q: String) {
        query = q
        render()
    }

    private func render() {
        if query.isEmpty {
            text.text = "Search emoji"
            text.textColor = theme.hint
        } else {
            text.text = query + "▏"
            text.textColor = theme.text
        }
        text.accessibilityLabel = "Search emoji"
        text.accessibilityValue = query
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let closeW: CGFloat = 64
        close.frame = CGRect(x: bounds.width - closeW - 4, y: 0, width: closeW, height: h)
        box.frame = CGRect(x: 8, y: 5, width: close.frame.minX - 12, height: h - 10)
        glass.frame = CGRect(x: 8, y: (box.bounds.height - 18) / 2, width: 18, height: 18)
        text.frame = CGRect(x: 32, y: 0, width: box.bounds.width - 40, height: box.bounds.height)
    }

    @objc private func closeTap() { onClose?() }
}

/// The matching emoji, in one row that scrolls sideways; tapping one types it.
final class EmojiResultsRow: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onPick: ((String) -> Void)?
    private let grid: UICollectionView
    private let flow: UICollectionViewFlowLayout
    private let note = UILabel()
    private var results = [String]()
    private var theme = Theme.make(dark: false)

    override init(frame: CGRect) {
        let f = UICollectionViewFlowLayout()
        f.scrollDirection = .horizontal
        f.minimumLineSpacing = 0
        f.minimumInteritemSpacing = 0
        flow = f
        grid = UICollectionView(frame: .zero, collectionViewLayout: f)
        super.init(frame: frame)
        grid.dataSource = self
        grid.delegate = self
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        grid.accessibilityIdentifier = "trail.emoji.results"
        addSubview(grid)
        note.font = .systemFont(ofSize: 15)
        note.textAlignment = .center
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ t: Theme) {
        theme = t
        backgroundColor = t.background
        note.textColor = t.hint
    }

    /// The emoji to show, and what to say when there are none.
    func show(_ list: [String], empty: String) {
        results = list
        note.text = list.isEmpty ? empty : nil
        note.isHidden = !list.isEmpty
        grid.reloadData()
        if !list.isEmpty { grid.setContentOffset(.zero, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        grid.frame = bounds
        note.frame = bounds.insetBy(dx: 12, dy: 0)
        let side = bounds.height
        if side > 0 && flow.itemSize.width != side {
            flow.itemSize = CGSize(width: side, height: side)
            flow.sectionInset = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            flow.invalidateLayout()
        }
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { results.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
        let e = ip.item < results.count ? results[ip.item] : ""
        c.label.text = e
        c.label.font = .systemFont(ofSize: floor(bounds.height * 0.68))
        c.accessibilityLabel = e
        return c
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        guard ip.item < results.count else { return }
        UIDevice.current.playInputClick()
        onPick?(results[ip.item])
    }
}
