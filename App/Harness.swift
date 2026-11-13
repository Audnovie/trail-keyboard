// A test harness: the keyboard hosted inside the app (not as a keyboard extension), typing into
// a model text field. The UI tests launch the app with -UITestHarness and tap and swipe on it,
// with real touches and with scripted swipes, then read the text back.

import SwiftUI
import UIKit
import TrailEngine

struct HarnessView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HarnessViewController { HarnessViewController() }
    func updateUIViewController(_ vc: HarnessViewController, context: Context) {}
}

final class HarnessViewController: UIViewController {
    private let editor = Editor()
    private let textLabel = UILabel()
    private let memoryLabel = UILabel()
    private let doneLabel = UILabel()
    private let runButton = UIButton(type: .system)
    private var kbView: KeyboardView!
    private var controller: KeyboardController!
    private var heightConstraint: NSLayoutConstraint!
    private var steps = [String]()
    /// The script's batches (separated by |): each tap on Run plays the next one.
    private var batches = [[String]]()
    private let args = ProcessInfo.processInfo.arguments

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textLabel.numberOfLines = 0
        textLabel.font = .systemFont(ofSize: 18)
        textLabel.accessibilityIdentifier = "harness.text"
        memoryLabel.font = .systemFont(ofSize: 11)
        memoryLabel.textColor = .secondaryLabel
        memoryLabel.accessibilityIdentifier = "harness.memory"
        doneLabel.font = .systemFont(ofSize: 11)
        doneLabel.accessibilityIdentifier = "harness.done"
        doneLabel.text = "idle"
        runButton.setTitle("Run script", for: .normal)
        runButton.accessibilityIdentifier = "harness.run"
        runButton.addAction(UIAction { [weak self] _ in self?.runScript() }, for: .touchUpInside)

        let store = StateStore(fileName: "harness-state.json")
        if args.contains("-HarnessReset") { store.eraseAll() }
        kbView = KeyboardView(frame: .zero)
        kbView.accessibilityIdentifier = "harness.keyboard"
        let lexicon = Bundle.main.path(forResource: "Lexicon", ofType: nil)
        controller = KeyboardController(view: kbView, target: editor, store: store, lexiconDir: lexicon)
        controller.onHeightChange = { [weak self] in self?.updateHeight() }
        controller.onUpdate = { [weak self] in self?.render() }
        editor.onChange = { [weak self] in self?.render() }

        for v in [textLabel, memoryLabel, doneLabel, runButton, kbView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        heightConstraint = kbView.heightAnchor.constraint(equalToConstant: KeyboardView.height(rowH: Metrics.rowH, header: 0))
        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            runButton.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 12),
            runButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            memoryLabel.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            memoryLabel.leadingAnchor.constraint(equalTo: runButton.trailingAnchor, constant: 16),
            doneLabel.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            doneLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            kbView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kbView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kbView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            heightConstraint,
        ])
        controller.fieldChanged(FieldTraits(dark: traitCollection.userInterfaceStyle == .dark))
        render()
        if let i = args.firstIndex(of: "-HarnessScript"), i + 1 < args.count {
            batches = args[i + 1].split(separator: "|").map { $0.split(separator: ";").map(String.init) }
        }
    }

    private func updateHeight() {
        heightConstraint.constant = KeyboardView.height(rowH: kbView.rowH, header: controller.headerHeight)
        view.layoutIfNeeded()
    }

    private func render() {
        // The caret shows as | so tests can see where it is.
        let u = editor.units
        let caret = String(decoding: u[0..<editor.sel], as: UTF16.self) + "|" + String(decoding: u[editor.sel...], as: UTF16.self)
        textLabel.text = caret
        textLabel.accessibilityValue = editor.text
        memoryLabel.text = String(format: "%.1f MB", memoryInUseMB())
    }

    // ---- scripted touches ----

    private func runScript() {
        guard !batches.isEmpty else { return }
        steps = batches.removeFirst()
        doneLabel.text = "running"
        next()
    }

    private func next() {
        guard !steps.isEmpty else {
            render()
            doneLabel.text = batches.isEmpty ? "done" : "done \(batches.count) left"
            return
        }
        let step = steps.removeFirst()
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let op = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.15
        switch op {
        case "swipe": swipe(arg)
        case "swipeTraining": swipe(controller.training.current())
        case "tap": tap(arg)
        case "wait": delay = (Double(arg) ?? 100) / 1000
        default: break
        }
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.next() }
    }

    /// A smooth path through the word's keys, like a careful finger.
    private func swipe(_ word: String) {
        let nodes = distinctKeys(word).compactMap { kbView.center(of: $0) }
        guard nodes.count >= 1 else { return }
        var pts = nodes
        if pts.count == 1 { pts.append(CGPoint(x: pts[0].x + kbView.keyUnit * 0.3, y: pts[0].y + 2)) }
        var path = [CGPoint]()
        let n = pts.count
        for i in 0..<(n - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(n - 1, i + 2)]
            for q in 0..<9 {
                let t = CGFloat(q) / 9
                let t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                path.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        path.append(pts[n - 1])
        kbView.simulateSwipe(path)
    }

    private func tap(_ name: String) {
        let codes: [String: Int] = ["space": KeyCode.space, "delete": KeyCode.delete, "shift": KeyCode.shift, "enter": KeyCode.enter,
                                    "123": KeyCode.symbols, "abc": KeyCode.letters, "emoji": KeyCode.emoji]
        let stripY = kbView.headerH + Metrics.stripH / 2
        switch name {
        case "gear": kbView.simulateTap(CGPoint(x: 20, y: stripY))
        case "slot0": kbView.simulateTap(CGPoint(x: kbView.bounds.width / 6, y: stripY))
        case "slot1": kbView.simulateTap(CGPoint(x: kbView.bounds.width / 2, y: stripY))
        case "slot2": kbView.simulateTap(CGPoint(x: kbView.bounds.width * 5 / 6, y: stripY))
        default:
            let code = codes[name] ?? Int(name.unicodeScalars.first?.value ?? 0)
            if let r = kbView.keyRect(code: code) { kbView.simulateTap(CGPoint(x: r.midX, y: r.midY)) }
        }
    }
}
