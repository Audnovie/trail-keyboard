// The keyboard extension iOS loads. It hosts the shared keyboard (KeyboardView and
// KeyboardController) and connects it to the app being typed in.
//
// Full Access is not requested (RequestsOpenAccess is NO in Info.plist): iOS then gives the
// keyboard no network and no shared storage, and the keyboard keeps its learning in its own
// storage, shown in its settings.

import UIKit
import TrailEngine

/// The keyboard's root view; it opts in to the standard key clicks (heard only when the
/// iPhone's Keyboard Clicks setting is on).
final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private var kbView: KeyboardView!
    private var controller: KeyboardController!
    private var target: ProxyTarget!
    private var document: ProxyDocument!
    private var heightConstraint: NSLayoutConstraint?
    private var lastDocument: UUID?

    override func loadView() {
        let v = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        kbView = KeyboardView(frame: view.bounds)
        kbView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kbView)
        NSLayoutConstraint.activate([
            kbView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kbView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kbView.topAnchor.constraint(equalTo: view.topAnchor),
            kbView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        document = ProxyDocument { [unowned self] in self.textDocumentProxy }
        let doc = document!
        target = ProxyTarget { doc }
        let lexicon = Bundle.main.path(forResource: "Lexicon", ofType: nil)
        controller = KeyboardController(view: kbView, target: target, store: StateStore(fileName: "state.json"), lexiconDir: lexicon)
        controller.onHeightChange = { [weak self] in self?.updateHeight() }
        // The app changed the text after all (seen on a second look, or before an edit).
        target.onExternalChange = { [weak self] in self?.controller.externalChange() }
        kbView.globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        kbView.setGlobe(needsInputModeSwitchKey)
        updateHeight()
        target.sync()
        lastDocument = textDocumentProxy.documentIdentifier
        controller.fieldChanged(currentTraits())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS holds back touches near the screen edges for its own gestures, which makes the
        // first and last keys of a row feel late; the keyboard wants them straight away.
        for g in view.window?.gestureRecognizers ?? [] { g.delaysTouchesBegan = false }
    }

    override func viewWillDisappear(_ animated: Bool) {
        controller.willHide()
        super.viewWillDisappear(animated)
    }

    override func viewWillLayoutSubviews() {
        kbView.setGlobe(needsInputModeSwitchKey)
        super.viewWillLayoutSubviews()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.updateHeight() })
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateHeight()
        let t = currentTraits()
        if t.dark != controller.traits.dark { controller.fieldChanged(t) }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        controller.saveNow()
    }

    override func textWillChange(_ textInput: UITextInput?) {}

    override func textDidChange(_ textInput: UITextInput?) {
        let doc = textDocumentProxy.documentIdentifier
        if doc != lastDocument {
            // Another text field.
            lastDocument = doc
            target.sync()
            controller.fieldChanged(currentTraits())
            return
        }
        if target.checkExternal() { controller.externalChange() }
        let t = currentTraits()
        if t.returnLabel != controller.traits.returnLabel { kbView.setReturnLabel(t.returnLabel) }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        if target.checkExternal() { controller.externalChange() }
    }

    private func updateHeight() {
        let landscape = view.traitCollection.verticalSizeClass == .compact
        let rowH = landscape ? Metrics.rowHLandscape : Metrics.rowH
        let h = KeyboardView.height(rowH: rowH, header: controller?.headerHeight ?? 0)
        if let c = heightConstraint {
            if c.constant != h { c.constant = h }
        } else {
            let c = view.heightAnchor.constraint(equalToConstant: h)
            c.priority = UILayoutPriority(999)
            c.isActive = true
            heightConstraint = c
        }
    }

    /// Field kinds that get no suggestions (and so no learning).
    private static let noSuggestTypes: Set<UITextContentType> = {
        var s: Set<UITextContentType> = [.password, .newPassword, .oneTimeCode, .creditCardNumber]
        if #available(iOS 17.0, *) {
            s.formUnion([.creditCardSecurityCode, .creditCardExpiration, .creditCardExpirationMonth,
                          .creditCardExpirationYear, .creditCardType])
        }
        if #available(iOS 17.4, *) { s.formUnion([.cellularEID, .cellularIMEI]) }
        return s
    }()

    /// Field kinds where suggestions are fine but nothing is learned.
    private static let noLearnTypes: Set<UITextContentType> = {
        var s: Set<UITextContentType> = [.username, .emailAddress, .URL, .telephoneNumber, .fullStreetAddress,
                                         .streetAddressLine1, .streetAddressLine2, .addressCity, .addressState,
                                         .addressCityAndState, .sublocality, .countryName, .postalCode, .location,
                                         .flightNumber, .shipmentTrackingNumber]
        if #available(iOS 17.0, *) {
            s.formUnion([.birthdate, .birthdateDay, .birthdateMonth, .birthdateYear, .creditCardName,
                         .creditCardGivenName, .creditCardMiddleName, .creditCardFamilyName])
        }
        return s
    }()

    /// For kinds newer than these lists: the type's name, lower case, letters only.
    private static func looseName(_ t: UITextContentType) -> String {
        String(t.rawValue.lowercased().filter { $0.isLetter })
    }

    static func contentRules(_ type: UITextContentType?) -> (suggest: Bool, learn: Bool) {
        guard let type = type else { return (true, true) }
        if noSuggestTypes.contains(type) { return (false, false) }
        if noLearnTypes.contains(type) { return (true, false) }
        let n = looseName(type)
        if ["password", "onetimecode", "creditcard", "cellular", "securitycode"].contains(where: { n.contains($0) }) || n.hasPrefix("cc") {
            return (false, false)
        }
        if ["username", "email", "url", "tel", "address", "postal", "location", "birth", "bday", "flight",
            "shipment", "country", "sublocality"].contains(where: { n.contains($0) }) {
            return (true, false)
        }
        return (true, true)
    }

    /// What kind of field this is, from the text traits the app gives it.
    private func currentTraits() -> FieldTraits {
        let p = textDocumentProxy
        var t = FieldTraits()
        let kt = p.keyboardType ?? .default
        let rules = KeyboardViewController.contentRules(p.textContentType ?? nil)
        let secure = p.isSecureTextEntry ?? false
        let numeric: [UIKeyboardType] = [.numberPad, .phonePad, .namePhonePad, .decimalPad, .asciiCapableNumberPad, .numbersAndPunctuation]
        t.suggest = !(secure || kt == .emailAddress || kt == .URL || numeric.contains(kt) || !rules.suggest)
        t.learn = t.suggest && rules.learn && (p.autocorrectionType ?? .default) != .no
        switch p.autocapitalizationType ?? .sentences {
        case .none:
            t.sentenceCaps = false
        case .words:
            t.sentenceCaps = false
            t.wordCaps = true
        case .allCharacters:
            t.sentenceCaps = false
            t.allCaps = true
        default:
            t.sentenceCaps = true
        }
        if !t.suggest { t.sentenceCaps = false }
        target.wordCaps = t.wordCaps
        switch p.returnKeyType ?? .default {
        case .go: t.returnLabel = "go"
        case .google, .yahoo, .search: t.returnLabel = "search"
        case .join: t.returnLabel = "join"
        case .next: t.returnLabel = "next"
        case .route: t.returnLabel = "route"
        case .send: t.returnLabel = "send"
        case .done: t.returnLabel = "done"
        case .continue: t.returnLabel = "continue"
        case .emergencyCall: t.returnLabel = "SOS"
        default: t.returnLabel = nil
        }
        t.dark = p.keyboardAppearance == .dark || view.traitCollection.userInterfaceStyle == .dark
        return t
    }
}
