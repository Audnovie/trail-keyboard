// The keyboard on screen: keys, suggestion bar, key previews, the accent pop-up and the swipe
// trail, and what your fingers do on them (tap, swipe, hold, drag the space bar). Ported from
// KeyboardUI in the web trial (itself from the Android app's KeyboardView).

import UIKit
import TrailEngine

/// Suggestion-bar targets that belong to the keyboard rather than the typing logic.
let NONE_SLOT = -999
let LANG_CHIP = 98
let MENU_CLOSE = 99
let MENU_BASE = 100

protocol KeyboardViewDelegate: AnyObject {
    func kbKey(_ key: Key)
    func kbLongPress(_ key: Key)
    func kbAlt(_ ch: String)
    func kbDelete()
    func kbSwipe(_ xs: [Double], _ ys: [Double])
    func kbCursorMove(_ steps: Int)
    func kbStripTap(_ slot: Int)
    func kbStripLongPress(_ slot: Int)
    func kbGeometry(_ cx: [Double], _ cy: [Double], _ kw: Double)
    func kbEmoji(_ text: String)
    func kbEmojiBack()
    func kbEmojiDelete()
    func kbEmojiSpace()
    func kbOpenSettings()
}

/// One finger on the keyboard.
private final class Pointer {
    let downX: CGFloat
    let downY: CGFloat
    var key: Key?
    var swiping = false
    var spaceDrag = false
    var longFired = false
    var consumed = false
    var inStrip = false
    var stripSlot = NONE_SLOT
    var dragAnchor: CGFloat = 0
    var xs = [Double]()
    var ys = [Double]()

    init(x: CGFloat, y: CGFloat) {
        downX = x
        downY = y
    }
}

private struct AltsState {
    let pointer: Pointer
    let values: [String]
    var sel: Int
    let left: CGFloat
    let cellW: CGFloat
    let reversed: Bool
}

final class KeyboardView: UIView, KeyboardSurface {
    weak var delegate: KeyboardViewDelegate?
    private(set) var theme = Theme.make(dark: false)
    private(set) var globe = false
    private var layouts = [LayoutName: KeyLayout]()
    private var geoLayout = Layouts.letters(globe: false)
    private(set) var layout = Layouts.letters(globe: false)
    private(set) var rowH: CGFloat = Metrics.rowH
    private(set) var keyUnit: CGFloat = 1
    private(set) var headerH: CGFloat = 0
    private var laidOutSize = CGSize.zero
    private(set) var shifted = false
    private(set) var capsLock = false
    var swipeEnabled = true
    /// Holding keys for accents and numbers (off in training, where a slow start shouldn't open one).
    var holdsEnabled = true
    /// Holding the space bar opens the language menu (only with more than one language).
    var spaceHold = false
    /// While a panel's text box is taking the keys, the bar shows that box instead.
    var inputBar: (label: String, text: String)? {
        didSet { stripView.setNeedsDisplay() }
    }

    private(set) var strip: [String?] = [nil, nil, nil]
    private var stripBold = 1
    private(set) var stripMessage: String?
    private(set) var prompt: String?
    private(set) var menu: (title: String, items: [(label: String, on: Bool)])?
    private var chip: String?
    private(set) var spaceLabel = ""
    private var returnLabel: String?

    private var pointers = [ObjectIdentifier: Pointer]()
    private var swipePointer: Pointer?
    private var pressedKey: Key?
    private var previewKey: Key?
    private var previewText: String?
    private(set) var pressedStripSlot = NONE_SLOT
    private var longPressTarget: Pointer?
    private var longPressWork: DispatchWorkItem?
    private var repeatTarget: Pointer?
    private var repeatWork: DispatchWorkItem?
    private var repeatCount = 0
    private var alts: AltsState?
    private(set) var emojiOpen = false

    let keysView = KeysView()
    let stripView = StripView()
    let trailView = TrailView()
    private let previewView = PreviewBubble()
    private let altsView = AltsPopup()
    let globeButton = UIButton(type: .custom)
    private var emojiPanel: EmojiPanel?
    /// Shown above the suggestion bar in training (set by the controller).
    var header: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let h = header { addSubview(h) }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        keysView.kb = self
        stripView.kb = self
        for v in [keysView, stripView, trailView, previewView, altsView] as [UIView] {
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        previewView.isHidden = true
        altsView.isHidden = true
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.isHidden = true
        addSubview(globeButton)
        buildLayouts()
        applyTheme(theme)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // ---- setup ----

    func applyTheme(_ t: Theme) {
        theme = t
        backgroundColor = t.background
        trailView.theme = t
        previewView.apply(t)
        altsView.apply(t)
        emojiPanel?.apply(t)
        keysView.setNeedsDisplay()
        stripView.setNeedsDisplay()
    }

    /// Whether the keyboard needs its own globe key (iPhones with a Home button).
    func setGlobe(_ on: Bool) {
        if on == globe { return }
        globe = on
        buildLayouts()
        laidOutSize = .zero
        setNeedsLayout()
    }

    private func buildLayouts() {
        layouts = [.letters: Layouts.letters(globe: globe), .symbols: Layouts.symbols(globe: globe), .symbols2: Layouts.symbols2(globe: globe)]
        geoLayout = Layouts.letters(globe: globe)
        layout = layouts[layout.name] ?? layouts[.letters]!
    }

    func setReturnLabel(_ label: String?) {
        if returnLabel == label { return }
        returnLabel = label
        keysView.setNeedsDisplay()
    }

    var returnKeyLabel: String? { returnLabel }

    func setHeaderHeight(_ h: CGFloat) {
        if headerH == h { return }
        headerH = h
        laidOutSize = .zero
        setNeedsLayout()
    }

    /// The height the keyboard wants for this width (rows are shorter in landscape).
    static func height(rowH: CGFloat, header: CGFloat) -> CGFloat {
        header + Metrics.stripH + 4 * rowH + Metrics.bottomPad
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        guard w > 0 else { return }
        let landscape = traitCollection.verticalSizeClass == .compact
        let rh = landscape ? Metrics.rowHLandscape : Metrics.rowH
        let size = CGSize(width: w, height: bounds.height)
        header?.frame = CGRect(x: 0, y: 0, width: w, height: headerH)
        stripView.frame = CGRect(x: 0, y: headerH, width: w, height: Metrics.stripH)
        keysView.frame = bounds
        trailView.frame = bounds
        emojiPanel?.frame = CGRect(x: 0, y: headerH + Metrics.stripH, width: w, height: max(0, bounds.height - headerH - Metrics.stripH))
        if size == laidOutSize && rh == rowH { return }
        laidOutSize = size
        rowH = rh
        keyUnit = w / 10
        let top = headerH + Metrics.stripH
        for name in [LayoutName.letters, .symbols, .symbols2] {
            if var L = layouts[name] {
                Layouts.place(&L, width: w, top: top, rowH: rh, gapX: Metrics.gapX, gapY: Metrics.gapY)
                layouts[name] = L
            }
        }
        Layouts.place(&geoLayout, width: w, top: top, rowH: rh, gapX: Metrics.gapX, gapY: Metrics.gapY)
        layout = layouts[layout.name]!
        cancelAll()
        placeGlobe()
        a11yCache = nil
        keysView.setNeedsDisplay()
        stripView.setNeedsDisplay()
        var cx = [Double](repeating: 0, count: 26)
        var cy = [Double](repeating: 0, count: 26)
        for row in geoLayout.rows {
            for k in row where k.isLetter {
                cx[k.code - 97] = Double(k.rect.midX)
                cy[k.code - 97] = Double(k.rect.midY)
            }
        }
        delegate?.kbGeometry(cx, cy, Double(keyUnit))
    }

    private func placeGlobe() {
        globeButton.isHidden = true
        guard globe, !emojiOpen else { return }
        for row in layout.rows {
            for k in row where k.code == UIKeyCode.globe {
                globeButton.frame = k.hit
                globeButton.isHidden = false
            }
        }
    }

    /// Where the letter keys are (for drawing ideal paths in training).
    func center(of letter: Int) -> CGPoint? {
        for row in geoLayout.rows {
            for k in row where k.code == 97 + letter { return CGPoint(x: k.rect.midX, y: k.rect.midY) }
        }
        return nil
    }

    // ---- what the typing logic calls (KeyboardSurface) ----

    func setLayout(_ name: LayoutName) {
        guard let L = layouts[name] else { return }
        layout = L
        a11yCache = nil
        cancelAll()
        placeGlobe()
        keysView.setNeedsDisplay()
    }

    func showEmoji(_ show: Bool) {
        emojiOpen = show
        if show {
            cancelAll()
            if emojiPanel == nil {
                let p = EmojiPanel()
                p.apply(theme)
                p.onEmoji = { [weak self] e in self?.delegate?.kbEmoji(e) }
                p.onBack = { [weak self] in self?.delegate?.kbEmojiBack() }
                p.onDelete = { [weak self] in self?.delegate?.kbEmojiDelete() }
                p.onSpace = { [weak self] in self?.delegate?.kbEmojiSpace() }
                emojiPanel = p
                addSubview(p)
            }
            emojiPanel?.isHidden = false
        } else {
            // Dropped when closed: its pictures are the biggest thing the keyboard draws.
            emojiPanel?.removeFromSuperview()
            emojiPanel = nil
        }
        placeGlobe()
        a11yCache = nil
        setNeedsLayout()
    }

    func setShift(_ s: Bool, _ lock: Bool) {
        if shifted == s && capsLock == lock { return }
        shifted = s
        capsLock = lock
        a11yCache = nil
        keysView.setNeedsDisplay()
        renderPress()
    }

    func setSuggestions(_ a: String?, _ b: String?, _ c: String?, bold: Int) {
        strip = [a, b, c]
        stripBold = bold
        stripMessage = nil
        prompt = nil
        stripView.setNeedsDisplay()
        updateStripAccessibility()
    }

    func clearStrip() { setSuggestions(nil, nil, nil, bold: 1) }

    func setStripMessage(_ m: String?) {
        strip = [nil, nil, nil]
        prompt = nil
        stripMessage = m
        stripView.setNeedsDisplay()
        updateStripAccessibility()
    }

    func setPrompt(_ text: String?) {
        prompt = text
        stripView.setNeedsDisplay()
        updateStripAccessibility()
    }

    var hasPrompt: Bool { prompt != nil }

    func openSettings() { delegate?.kbOpenSettings() }

    /// A row of choices in the suggestion bar (the language picker).
    func setMenu(_ title: String, _ items: [(label: String, on: Bool)]) {
        menu = (title, items)
        stripView.setNeedsDisplay()
        updateStripAccessibility()
    }

    func clearMenu() {
        guard menu != nil else { return }
        menu = nil
        stripView.setNeedsDisplay()
        updateStripAccessibility()
    }

    /// The language badge in the empty suggestion bar (nil hides it).
    func setChip(_ text: String?) {
        if chip == text { return }
        chip = text
        stripView.setNeedsDisplay()
    }

    var chipText: String? { chip }

    func setSpaceLabel(_ text: String) {
        if spaceLabel == text { return }
        spaceLabel = text
        a11yCache = nil
        keysView.setNeedsDisplay()
    }

    // ---- drawing state the subviews read ----

    var stripState: (words: [String?], bold: Int, message: String?, prompt: String?, menu: (title: String, items: [(label: String, on: Bool)])?, chip: String?, pressed: Int) {
        (strip, stripBold, stripMessage, prompt, menu, chip, pressedStripSlot)
    }

    var keyState: (layout: KeyLayout, pressed: Key?, shifted: Bool, capsLock: Bool, space: String, returnLabel: String?, hideKeys: Bool) {
        (layout, pressedKey, shifted, capsLock, spaceLabel, returnLabel, emojiOpen)
    }

    private func renderPress() {
        keysView.setNeedsDisplay()
        guard let k = previewKey, swipePointer == nil, alts == nil else {
            previewView.isHidden = true
            return
        }
        var text = previewText ?? k.label
        if k.isLetter && previewText == nil && (shifted || capsLock) { text = text.uppercased() }
        let w = k.rect.width + 14
        let h = rowH * 1.1
        let left = max(2, min(k.rect.midX - w / 2, bounds.width - w - 2))
        let top = max(0, k.rect.minY - h - 2)
        previewView.show(text, frame: CGRect(x: left, y: top, width: w, height: h))
    }

    /// Menu items sit at the right of the bar; tapping left of them closes the menu.
    func menuGeometry() -> (n: Int, itemW: CGFloat, start: CGFloat) {
        let n = menu?.items.count ?? 0
        let itemW = min(96, floor((bounds.width - 90) / CGFloat(max(1, n))) - 4)
        return (n, itemW, bounds.width - CGFloat(n) * (itemW + 4))
    }

    // ---- the pop-up of accents and numbers ----

    private func openAlts(_ p: Pointer) {
        guard let k = p.key, let values = k.alts else { return }
        let n = values.count
        let caps = shifted || capsLock
        let cellW = max(30, k.rect.width)
        let cellH = (rowH * 0.92).rounded()
        let total = cellW * CGFloat(n)
        let cx = k.rect.midX
        // The first choice sits over the key and the rest run toward the middle of the keyboard,
        // so letting go without sliding gives the first one.
        let reversed = cx - cellW / 2 + total > bounds.width - 2
        var left = reversed ? cx + cellW / 2 - total : cx - cellW / 2
        left = max(2, min(left, bounds.width - total - 2))
        alts = AltsState(pointer: p, values: values, sel: 0, left: left, cellW: cellW, reversed: reversed)
        let shown = (0..<n).map { v -> String in
            let i = reversed ? n - 1 - v : v
            return caps ? values[i].uppercased() : values[i]
        }
        altsView.show(shown, selected: reversed ? n - 1 : 0,
                      frame: CGRect(x: left, y: max(0, k.rect.minY - cellH - 7), width: total, height: cellH))
        previewKey = nil
        renderPress()
    }

    private func selectAlt(_ x: CGFloat) {
        guard var a = alts else { return }
        let n = a.values.count
        let v = max(0, min(n - 1, Int(floor((x - a.left) / a.cellW))))
        let i = a.reversed ? n - 1 - v : v
        if i == a.sel { return }
        a.sel = i
        alts = a
        altsView.select(a.reversed ? n - 1 - i : i)
    }

    private func closeAlts() {
        alts = nil
        altsView.isHidden = true
    }

    // ---- touch ----

    func stripSlotAt(_ x: CGFloat) -> Int {
        let w = bounds.width
        if inputBar != nil {
            if x >= w - Metrics.promptButtonW { return PROMPT_NO }
            if x >= w - 2 * Metrics.promptButtonW { return PROMPT_YES }
            return NONE_SLOT
        }
        if prompt != nil {
            if x >= w - Metrics.promptButtonW { return PROMPT_NO }
            if x >= w - 2 * Metrics.promptButtonW { return PROMPT_YES }
            return NONE_SLOT
        }
        if menu != nil {
            let g = menuGeometry()
            if x < g.start { return MENU_CLOSE }
            return MENU_BASE + max(0, min(g.n - 1, Int(floor((x - g.start) / (g.itemW + 4)))))
        }
        if stripMessage != nil { return NONE_SLOT }
        let hasWords = strip.contains { $0 != nil }
        if !hasWords {
            if x < Metrics.stripH * 1.2 { return SLOT_GEAR }
            if chip != nil && x > w - 92 { return LANG_CHIP }
            return NONE_SLOT
        }
        return max(0, min(2, Int(floor(x / (w / 3)))))
    }

    private func holdsFor(_ k: Key) -> Bool {
        if !holdsEnabled { return false }
        return k.alts != nil || (k.code == KeyCode.space && spaceHold)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            down(ObjectIdentifier(t), p.x, p.y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let p = pointers[ObjectIdentifier(t)], !p.consumed else { continue }
            let list = event?.coalescedTouches(for: t) ?? [t]
            for c in (list.isEmpty ? [t] : list) {
                let loc = c.location(in: self)
                move(p, loc.x, loc.y)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            let p = pointers.removeValue(forKey: id)
            let loc = t.location(in: self)
            if let p = p { up(p, loc.x, loc.y) }
        }
        if pointers.isEmpty { cancelAll() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { pointers.removeValue(forKey: ObjectIdentifier(t)) }
        cancelAll()
    }

    private func down(_ id: ObjectIdentifier, _ x: CGFloat, _ y: CGFloat) {
        if emojiOpen && y >= headerH + Metrics.stripH { return }
        if swipePointer != nil || alts != nil { return }
        // A new finger lands: finish any other finger's tap now (fast two-thumb typing).
        for o in pointers.values {
            if !o.consumed && !o.swiping && !o.spaceDrag && !o.inStrip && !o.longFired, let k = o.key, k.code != KeyCode.delete {
                o.consumed = true
                if longPressTarget === o { stopLongPress() }
                delegate?.kbKey(k)
            }
        }
        let p = Pointer(x: x, y: y)
        pointers[id] = p
        if y < headerH {
            p.consumed = true
            return
        }
        if y < headerH + Metrics.stripH {
            p.inStrip = true
            p.stripSlot = stripSlotAt(x)
            if p.stripSlot == NONE_SLOT {
                p.consumed = true
                return
            }
            pressedStripSlot = p.stripSlot
            if p.stripSlot >= 0 && p.stripSlot <= 2 && strip[p.stripSlot] != nil && inputBar == nil {
                scheduleLongPress(p, Metrics.stripLongPress)
            }
            stripView.setNeedsDisplay()
            return
        }
        guard let k = Layouts.keyAt(layout, CGPoint(x: x, y: y)) else {
            p.consumed = true
            return
        }
        p.key = k
        pressedKey = k
        previewKey = k.showsPreview ? k : nil
        previewText = nil
        p.xs.append(Double(x))
        p.ys.append(Double(y))
        if k.code == KeyCode.delete {
            repeatTarget = p
            repeatCount = 0
            delegate?.kbDelete()
            scheduleRepeat(Metrics.repeatStart)
        } else if holdsFor(k) {
            scheduleLongPress(p, k.code == KeyCode.space ? Metrics.spaceLongPress : Metrics.longPress)
        }
        if k.code > 0 { UIDevice.current.playInputClick() }
        renderPress()
    }

    private func move(_ p: Pointer, _ x: CGFloat, _ y: CGFloat) {
        if p.inStrip {
            if abs(x - p.downX) > 30 || y > headerH + Metrics.stripH + 20 {
                p.consumed = true
                pressedStripSlot = NONE_SLOT
                if longPressTarget === p { stopLongPress() }
                stripView.setNeedsDisplay()
            }
            return
        }
        guard let key = p.key else { return }
        if let a = alts, a.pointer === p {
            selectAlt(x)
            return
        }
        if p.swiping {
            p.xs.append(Double(x))
            p.ys.append(Double(y))
            trailView.setLive(p.xs, p.ys)
            return
        }
        if p.spaceDrag {
            let moved = x - p.dragAnchor
            let steps = Int((moved / (Metrics.spaceDragStep * keyUnit)).rounded(.towardZero))
            if steps != 0 {
                p.dragAnchor += CGFloat(steps) * Metrics.spaceDragStep * keyUnit
                delegate?.kbCursorMove(steps)
            }
            return
        }
        p.xs.append(Double(x))
        p.ys.append(Double(y))
        let dx = x - p.downX
        let dy = y - p.downY
        let dist = (dx * dx + dy * dy).squareRoot()
        if key.code == KeyCode.space && !p.longFired && abs(dx) > Metrics.spaceDragStart * keyUnit {
            p.spaceDrag = true
            p.dragAnchor = x
            stopLongPress()
            pressedKey = nil
            previewKey = nil
            renderPress()
            return
        }
        let swipeable = swipeEnabled && layout.name == .letters && key.isLetter && inputBar == nil
        if swipeable && longPressTarget === p && dist > Metrics.longPressSlop * keyUnit {
            // The finger is moving, so this is the start of a swipe, not a hold.
            stopLongPress()
        }
        if swipeable && !p.longFired && pointers.count == 1 && dist > Metrics.swipeStart * keyUnit {
            p.swiping = true
            swipePointer = p
            if longPressTarget === p { stopLongPress() }
            pressedKey = nil
            previewKey = nil
            renderPress()
            trailView.setLive(p.xs, p.ys)
            return
        }
        if !swipeable && key.code != KeyCode.delete && !p.longFired {
            // Sliding onto another key picks that one instead.
            if let k = Layouts.keyAt(layout, CGPoint(x: x, y: y)), k !== key {
                p.key = k
                pressedKey = k
                previewKey = k.showsPreview ? k : nil
                previewText = nil
                if longPressTarget === p { stopLongPress() }
                if holdsFor(k) { scheduleLongPress(p, k.code == KeyCode.space ? Metrics.spaceLongPress : Metrics.longPress) }
                renderPress()
            }
        }
    }

    private func up(_ p: Pointer, _ x: CGFloat, _ y: CGFloat) {
        if longPressTarget === p { stopLongPress() }
        if repeatTarget === p {
            repeatWork?.cancel()
            repeatTarget = nil
        }
        if p.consumed { return }
        if p.inStrip {
            pressedStripSlot = NONE_SLOT
            stripView.setNeedsDisplay()
            if !p.longFired { delegate?.kbStripTap(p.stripSlot) }
            return
        }
        guard let key = p.key else { return }
        if let a = alts, a.pointer === p {
            let ch = a.values[a.sel]
            closeAlts()
            delegate?.kbAlt(ch)
            return
        }
        if p.swiping {
            p.xs.append(Double(x))
            p.ys.append(Double(y))
            swipePointer = nil
            trailView.setLive(nil, nil)
            delegate?.kbSwipe(p.xs, p.ys)
            return
        }
        if p.spaceDrag || p.longFired || key.code == KeyCode.delete { return }
        delegate?.kbKey(key)
    }

    private func scheduleLongPress(_ p: Pointer, _ delay: Double) {
        longPressWork?.cancel()
        longPressTarget = p
        let w = DispatchWorkItem { [weak self] in self?.longPress() }
        longPressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func stopLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
        longPressTarget = nil
    }

    private func longPress() {
        guard let p = longPressTarget else { return }
        longPressTarget = nil
        if p.consumed || p.swiping || p.spaceDrag { return }
        p.longFired = true
        if p.inStrip {
            pressedStripSlot = NONE_SLOT
            stripView.setNeedsDisplay()
            delegate?.kbStripLongPress(p.stripSlot)
        } else if let k = p.key, let a = k.alts, a.count > 1 {
            openAlts(p)
        } else if let k = p.key {
            // One choice (a number, ñ, ¿): it's typed straight away.
            if let c = k.alts?.first { previewText = shifted || capsLock ? c.uppercased() : c }
            delegate?.kbLongPress(k)
            renderPress()
        }
    }

    private func scheduleRepeat(_ delay: Double) {
        repeatWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.repeatDelete() }
        repeatWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func repeatDelete() {
        guard repeatTarget != nil else { return }
        delegate?.kbDelete()
        repeatCount += 1
        scheduleRepeat(repeatCount > 20 ? Metrics.repeatFast : Metrics.repeatEvery)
    }

    func cancelAll() {
        stopLongPress()
        repeatWork?.cancel()
        repeatTarget = nil
        pointers.removeAll()
        if swipePointer != nil { trailView.setLive(nil, nil) }
        swipePointer = nil
        pressedKey = nil
        previewKey = nil
        previewText = nil
        pressedStripSlot = NONE_SLOT
        closeAlts()
        renderPress()
        stripView.setNeedsDisplay()
    }

    // ---- touches made up by the test harness ----

    /// Runs a path through the same code a finger takes (the app's UI tests use this).
    func simulateSwipe(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        let id = ObjectIdentifier(UUID() as NSUUID)
        down(id, first.x, first.y)
        guard let p = pointers[id] else { return }
        for q in points.dropFirst() { move(p, q.x, q.y) }
        let last = points.last!
        pointers.removeValue(forKey: id)
        up(p, last.x, last.y)
        if pointers.isEmpty { cancelAll() }
    }

    /// A tap at a point, through the same code a finger takes.
    func simulateTap(_ point: CGPoint) {
        let id = ObjectIdentifier(UUID() as NSUUID)
        down(id, point.x, point.y)
        guard let p = pointers.removeValue(forKey: id) else { return }
        up(p, point.x, point.y)
        if pointers.isEmpty { cancelAll() }
    }

    func keyRect(code: Int) -> CGRect? {
        for row in layout.rows {
            for k in row where k.code == code { return k.rect }
        }
        return nil
    }

    // ---- accessibility ----

    private var a11yCache: [Any]?

    func invalidateAccessibility() { a11yCache = nil }

    private func a11yName(_ k: Key) -> (label: String, id: String) {
        switch k.code {
        case KeyCode.space: return (spaceLabel.isEmpty ? "space" : "space, " + spaceLabel, "key.space")
        case KeyCode.delete: return ("delete", "key.delete")
        case KeyCode.shift: return (capsLock ? "caps lock" : "shift", "key.shift")
        case KeyCode.enter: return (returnLabel ?? "return", "key.return")
        case KeyCode.emoji: return ("emoji", "key.emoji")
        case KeyCode.symbols: return ("numbers", "key.123")
        case KeyCode.letters: return ("letters", "key.abc")
        case KeyCode.symbols2: return ("more symbols", "key.sym2")
        case UIKeyCode.globe: return ("next keyboard", "key.globe")
        default:
            let l = k.isLetter && (shifted || capsLock) ? k.label.uppercased() : k.label
            let names: [String: String] = [".": "period", ",": "comma", "'": "apostrophe", "?": "question", "!": "exclamation"]
            return (l, "key." + (names[k.label] ?? k.label))
        }
    }

    override var accessibilityElements: [Any]? {
        get {
            if let c = a11yCache { return c }
            var out = [Any]()
            if let panel = subviews.last(where: { $0 is PanelView }) {
                out.append(panel)
                a11yCache = out
                return out
            }
            if let h = header { out.append(h) }
            out.append(stripView)
            if let e = emojiPanel {
                out.append(e)
            } else {
                for row in layout.rows {
                    for k in row where k.code != UIKeyCode.globe {
                        let e = UIAccessibilityElement(accessibilityContainer: self)
                        let n = a11yName(k)
                        e.accessibilityLabel = n.label
                        e.accessibilityIdentifier = n.id
                        e.accessibilityTraits = .keyboardKey
                        e.accessibilityFrameInContainerSpace = k.rect
                        out.append(e)
                    }
                }
            }
            if !globeButton.isHidden { out.append(globeButton) }
            a11yCache = out
            return out
        }
        set {}
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        a11yCache = nil
    }

    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        a11yCache = nil
    }

    private func updateStripAccessibility() {
        stripView.accessibilityValue = [stripMessage, prompt].compactMap { $0 }.first ?? strip.map { $0 ?? "" }.joined(separator: " | ")
    }
}

// MARK: - Keys

final class KeysView: UIView {
    weak var kb: KeyboardView?
    private var icons = [String: UIImage]()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func icon(_ name: String, _ size: CGFloat, _ color: UIColor, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        let key = "\(name)|\(size)|\(color.hashValue)|\(weight.rawValue)"
        if let i = icons[key] { return i }
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
        let img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal)
        if icons.count > 40 { icons.removeAll() }
        icons[key] = img
        return img
    }

    override func draw(_ rect: CGRect) {
        guard let kb = kb else { return }
        let t = kb.theme
        let s = kb.keyState
        if s.hideKeys { return }
        for row in s.layout.rows {
            for k in row {
                let pressed = s.pressed === k
                var fill: UIColor
                if k.isFunction && k.code != KeyCode.space {
                    fill = pressed ? t.fnKeyDown : t.fnKey
                    if k.code == KeyCode.shift && (s.shifted || s.capsLock) { fill = t.dark ? t.key : .white }
                } else {
                    fill = pressed && (k.code == KeyCode.space || !k.showsPreview) ? t.keyDown : t.key
                }
                let r = k.rect
                let shadow = UIBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 1), cornerRadius: 5)
                t.keyShadow.setFill()
                shadow.fill()
                fill.setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 5).fill()
                drawLabel(k, r, s, t)
            }
        }
    }

    private func drawLabel(_ k: Key, _ r: CGRect, _ s: (layout: KeyLayout, pressed: Key?, shifted: Bool, capsLock: Bool, space: String, returnLabel: String?, hideKeys: Bool), _ t: Theme) {
        func image(_ img: UIImage?) {
            guard let img = img else { return }
            img.draw(at: CGPoint(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2))
        }
        func text(_ str: String, _ size: CGFloat, _ color: UIColor, weight: UIFont.Weight = .regular, at: CGPoint? = nil) {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
            let sz = (str as NSString).size(withAttributes: attrs)
            let p = at ?? CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2)
            (str as NSString).draw(at: p, withAttributes: attrs)
        }
        switch k.code {
        case KeyCode.shift:
            let on = s.shifted || s.capsLock
            image(icon(s.capsLock ? "capslock.fill" : (on ? "shift.fill" : "shift"), 18, t.dark && on ? .black : t.text, weight: .medium))
        case KeyCode.delete:
            image(icon("delete.left", 18, t.text))
        case KeyCode.enter:
            if let l = s.returnLabel {
                text(l, 15, t.text)
            } else {
                image(icon("return", 18, t.text))
            }
        case KeyCode.emoji:
            image(icon("face.smiling", 19, t.text))
        case UIKeyCode.globe:
            image(icon("globe", 19, t.text))
        case KeyCode.space:
            if !s.space.isEmpty { text(s.space, 13, t.hint) }
        default:
            var label = k.label
            if k.isLetter && (s.shifted || s.capsLock) { label = label.uppercased() }
            let size: CGFloat = label.count > 2 ? 15 : (k.isLetter ? 23 : 21)
            text(label, size, t.text, weight: k.isLetter ? .regular : .regular)
            if let h = k.hint {
                text(h, 9, t.hint, at: CGPoint(x: r.maxX - 9, y: r.minY + 1))
            }
        }
    }
}

// MARK: - Suggestion bar

final class StripView: UIView {
    weak var kb: KeyboardView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Suggestions"
        accessibilityIdentifier = "trail.strip"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let kb = kb else { return }
        let t = kb.theme
        let s = kb.stripState
        let w = bounds.width
        let h = bounds.height
        func text(_ str: String, in box: CGRect, size: CGFloat = 17, weight: UIFont.Weight = .regular, color: UIColor? = nil, align: NSTextAlignment = .center) {
            let para = NSMutableParagraphStyle()
            para.alignment = align
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? t.stripText, .paragraphStyle: para]
            let lineH = UIFont.systemFont(ofSize: size, weight: weight).lineHeight
            (str as NSString).draw(in: CGRect(x: box.minX, y: box.midY - lineH / 2, width: box.width, height: lineH), withAttributes: attrs)
        }
        func button(_ label: String, _ box: CGRect, pressed: Bool, strong: Bool) {
            let r = box.insetBy(dx: 4, dy: 5)
            (pressed ? t.keyDown : (strong ? t.accent : t.key)).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 7).fill()
            text(label, in: r, size: 15, weight: .semibold, color: strong && !pressed ? .white : t.text)
        }
        if let bar = kb.inputBar {
            text(bar.label + " " + bar.text + "▏", in: CGRect(x: 10, y: 0, width: w - 2 * Metrics.promptButtonW - 14, height: h), size: 17, align: .left)
            button("Add", CGRect(x: w - 2 * Metrics.promptButtonW, y: 0, width: Metrics.promptButtonW, height: h), pressed: s.pressed == PROMPT_YES, strong: true)
            button("Cancel", CGRect(x: w - Metrics.promptButtonW, y: 0, width: Metrics.promptButtonW, height: h), pressed: s.pressed == PROMPT_NO, strong: false)
            return
        }
        if let p = s.prompt {
            text(p, in: CGRect(x: 10, y: 0, width: w - 2 * Metrics.promptButtonW - 14, height: h), size: 14, align: .left)
            button("Block", CGRect(x: w - 2 * Metrics.promptButtonW, y: 0, width: Metrics.promptButtonW, height: h), pressed: s.pressed == PROMPT_YES, strong: true)
            button("Cancel", CGRect(x: w - Metrics.promptButtonW, y: 0, width: Metrics.promptButtonW, height: h), pressed: s.pressed == PROMPT_NO, strong: false)
            return
        }
        if let m = s.menu {
            let g = kb.menuGeometry()
            text(m.title, in: CGRect(x: 10, y: 0, width: max(0, g.start - 14), height: h), size: 14, color: t.stripDim, align: .left)
            for (i, item) in m.items.enumerated() {
                let box = CGRect(x: g.start + CGFloat(i) * (g.itemW + 4), y: 0, width: g.itemW, height: h)
                let r = box.insetBy(dx: 0, dy: 5)
                if item.on || s.pressed == MENU_BASE + i {
                    (s.pressed == MENU_BASE + i ? t.keyDown : t.key).setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: 7).fill()
                }
                text(item.label, in: r, size: 14, weight: item.on ? .semibold : .regular)
            }
            return
        }
        if let m = s.message {
            text(m, in: bounds.insetBy(dx: 10, dy: 0), size: 15, color: t.stripDim)
            return
        }
        let hasWords = s.words.contains { $0 != nil }
        if hasWords {
            let slotW = w / 3
            for i in 0..<3 {
                let box = CGRect(x: CGFloat(i) * slotW, y: 0, width: slotW, height: h)
                if s.pressed == i && s.words[i] != nil {
                    t.divider.setFill()
                    UIBezierPath(roundedRect: box.insetBy(dx: 3, dy: 5), cornerRadius: 7).fill()
                }
                if i > 0 {
                    t.divider.setFill()
                    UIRectFill(CGRect(x: box.minX, y: 12, width: 1, height: h - 24))
                }
                if let word = s.words[i] {
                    text(word, in: box.insetBy(dx: 5, dy: 0), size: 17, weight: i == s.bold ? .semibold : .regular)
                }
            }
            return
        }
        // Empty: the settings button, and the language you're writing in.
        let gearBox = CGRect(x: 0, y: 0, width: Metrics.stripH * 1.2, height: h)
        if s.pressed == SLOT_GEAR {
            t.divider.setFill()
            UIBezierPath(roundedRect: gearBox.insetBy(dx: 4, dy: 5), cornerRadius: 7).fill()
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        if let img = UIImage(systemName: "slider.horizontal.3", withConfiguration: cfg)?.withTintColor(t.stripDim, renderingMode: .alwaysOriginal) {
            img.draw(at: CGPoint(x: gearBox.midX - img.size.width / 2, y: gearBox.midY - img.size.height / 2))
        }
        if let c = s.chip {
            let box = CGRect(x: w - 88, y: 0, width: 84, height: h)
            if s.pressed == LANG_CHIP {
                t.divider.setFill()
                UIBezierPath(roundedRect: box.insetBy(dx: 2, dy: 5), cornerRadius: 7).fill()
            }
            text("🌐 " + c, in: box, size: 14, color: t.stripDim)
        }
    }
}

// MARK: - Key preview and accent pop-up

final class PreviewBubble: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 32)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ t: Theme) {
        backgroundColor = t.key
        label.textColor = t.text
    }

    func show(_ text: String, frame f: CGRect) {
        frame = f
        label.frame = bounds
        label.text = text
        isHidden = false
    }
}

final class AltsPopup: UIView {
    private var cells = [UILabel]()
    private var theme = Theme.make(dark: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ t: Theme) {
        theme = t
        backgroundColor = t.key
    }

    func show(_ values: [String], selected: Int, frame f: CGRect) {
        frame = f
        for c in cells { c.removeFromSuperview() }
        cells = []
        let w = f.width / CGFloat(max(1, values.count))
        for (i, v) in values.enumerated() {
            let l = UILabel(frame: CGRect(x: CGFloat(i) * w, y: 0, width: w, height: f.height))
            l.text = v
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 24)
            l.layer.cornerRadius = 7
            l.layer.masksToBounds = true
            addSubview(l)
            cells.append(l)
        }
        select(selected)
        isHidden = false
    }

    func select(_ i: Int) {
        for (j, c) in cells.enumerated() {
            c.backgroundColor = j == i ? theme.accent : .clear
            c.textColor = j == i ? .white : theme.text
        }
    }
}

// MARK: - Swipe trail

final class TrailView: UIView {
    var theme = Theme.make(dark: false)
    private var live = [CAShapeLayer]()
    private let bands = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        for _ in 0..<bands {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.lineWidth = 7
            layer.addSublayer(l)
            live.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The trail under the finger: the last 90 points, fading toward the start.
    func setLive(_ xs: [Double]?, _ ys: [Double]?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let xs = xs, let ys = ys, xs.count > 1 else {
            for l in live { l.path = nil }
            return
        }
        let start = max(0, xs.count - 90)
        let count = xs.count - start
        for b in 0..<bands {
            let a = start + b * count / bands
            let z = min(xs.count - 1, start + (b + 1) * count / bands)
            let path = UIBezierPath()
            if z > a {
                path.move(to: CGPoint(x: xs[a], y: ys[a]))
                for i in (a + 1)...z { path.addLine(to: CGPoint(x: xs[i], y: ys[i])) }
            }
            live[b].path = path.cgPath
            live[b].strokeColor = theme.accent.withAlphaComponent(CGFloat(60 + 170 * (b + 1) / bands) / 255).cgColor
        }
    }

    /// A path that stays for `hold` seconds and then fades out over `duration`.
    func fade(_ points: [CGPoint], color: UIColor, width: CGFloat = 7, alpha: CGFloat = 1, hold: Double = 0, duration: Double = 0.22, dash: [NSNumber]? = nil) {
        guard points.count > 1 else { return }
        let l = CAShapeLayer()
        let path = UIBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        l.path = path.cgPath
        l.fillColor = nil
        l.strokeColor = color.cgColor
        l.lineWidth = width
        l.lineCap = .round
        l.lineJoin = .round
        l.lineDashPattern = dash
        l.opacity = Float(alpha)
        layer.insertSublayer(l, at: 0)
        animateOut(l, hold: hold, duration: duration)
    }

    /// A circle that fades out, to mark a letter.
    func ring(_ center: CGPoint, radius: CGFloat, color: UIColor, hold: Double, duration: Double) {
        let l = CAShapeLayer()
        l.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        l.fillColor = nil
        l.strokeColor = color.cgColor
        l.lineWidth = 3
        l.opacity = 0.9
        layer.insertSublayer(l, at: 0)
        animateOut(l, hold: hold, duration: duration)
    }

    private func animateOut(_ l: CAShapeLayer, hold: Double, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.opacity
        a.toValue = 0
        a.beginTime = CACurrentMediaTime() + hold
        a.duration = duration
        a.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(a, forKey: "out")
        l.opacity = 0
        CATransaction.commit()
        // Make sure it goes even if the animation is dropped (keyboard hidden mid-way).
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + duration + 0.1) { l.removeFromSuperlayer() }
    }

    func clearFades() {
        for l in layer.sublayers ?? [] where !live.contains(where: { $0 === l }) { l.removeFromSuperlayer() }
    }
}
