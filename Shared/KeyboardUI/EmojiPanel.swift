// The emoji grid that replaces the keys, with ABC, space and delete underneath.

import UIKit

final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onEmoji: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    private let grid: UICollectionView
    private let bar = UIView()
    private let abc = UIButton(type: .system)
    private let space = UIButton(type: .system)
    private let del = UIButton(type: .system)
    private var repeatWork: DispatchWorkItem?
    private var repeatCount = 0
    private var theme = Theme.make(dark: false)

    override init(frame: CGRect) {
        let flow = UICollectionViewFlowLayout()
        flow.scrollDirection = .vertical
        flow.minimumInteritemSpacing = 0
        flow.minimumLineSpacing = 0
        grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(frame: frame)
        grid.dataSource = self
        grid.delegate = self
        grid.backgroundColor = .clear
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        grid.accessibilityIdentifier = "trail.emoji"
        addSubview(grid)
        addSubview(bar)
        for (b, title) in [(abc, "ABC"), (space, "space"), (del, "")] {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.layer.cornerRadius = 5
            bar.addSubview(b)
        }
        del.setImage(UIImage(systemName: "delete.left"), for: .normal)
        del.accessibilityLabel = "Delete"
        abc.addTarget(self, action: #selector(back), for: .touchUpInside)
        space.addTarget(self, action: #selector(spaceTap), for: .touchUpInside)
        del.addTarget(self, action: #selector(delDown), for: .touchDown)
        del.addTarget(self, action: #selector(delUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ t: Theme) {
        theme = t
        backgroundColor = t.background
        for b in [abc, space, del] {
            b.backgroundColor = b === space ? t.key : t.fnKey
            b.setTitleColor(t.text, for: .normal)
            b.tintColor = t.text
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barH: CGFloat = 46
        grid.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barH)
        bar.frame = CGRect(x: 0, y: bounds.height - barH, width: bounds.width, height: barH)
        let w = bounds.width
        abc.frame = CGRect(x: 4, y: 5, width: w * 0.18, height: barH - 10)
        del.frame = CGRect(x: w - w * 0.18 - 4, y: 5, width: w * 0.18, height: barH - 10)
        space.frame = CGRect(x: abc.frame.maxX + 6, y: 5, width: del.frame.minX - abc.frame.maxX - 12, height: barH - 10)
        if let flow = grid.collectionViewLayout as? UICollectionViewFlowLayout {
            let per = max(6, Int(w / 44))
            let side = floor(w / CGFloat(per))
            flow.itemSize = CGSize(width: side, height: side)
        }
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { EMOJI.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
        c.label.text = EMOJI[ip.item]
        c.accessibilityLabel = EMOJI[ip.item]
        return c
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        UIDevice.current.playInputClick()
        onEmoji?(EMOJI[ip.item])
    }

    @objc private func back() { onBack?() }
    @objc private func spaceTap() { onSpace?() }

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

private final class EmojiCell: UICollectionViewCell {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 28)
        label.textAlignment = .center
        contentView.addSubview(label)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }
}
