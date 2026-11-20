// Colours and sizes: the System theme (close to the iPhone's own keyboard, in light and dark) and
// the colour themes you can pick in the keyboard's settings.

import UIKit

struct Theme {
    let background: UIColor
    let key: UIColor
    let keyDown: UIColor
    let fnKey: UIColor
    let fnKeyDown: UIColor
    let keyShadow: UIColor
    let text: UIColor
    let hint: UIColor
    let stripText: UIColor
    let stripDim: UIColor
    let divider: UIColor
    let accent: UIColor
    let ghost: UIColor
    let bad: UIColor
    let good: UIColor
    let panel: UIColor
    let panelRow: UIColor
    let dark: Bool
    /// The shift key when it's on, and its arrow.
    var shiftOn: UIColor? = nil
    var shiftOnText: UIColor? = nil
    /// iOS's own keyboard background shows behind the keys (the System theme). In iOS 26, apps
    /// with the new look put a strip of it above any keyboard that a keyboard can't draw over;
    /// this way the two match.
    var clear = false

    /// Text on an accent-coloured button.
    var onAccent: UIColor = .white

    /// What goes behind the keys and the bar.
    var surface: UIColor { clear ? .clear : background }

    /// The themes, in the order the settings list them.
    static let all: [(id: String, name: String)] = [
        ("system", "System"), ("graphite", "Graphite"), ("midnight", "Midnight"), ("ocean", "Ocean"),
        ("forest", "Forest"), ("sunset", "Sunset"), ("rose", "Rose"), ("lavender", "Lavender"), ("paper", "Paper"),
    ]

    static func name(of id: String) -> String {
        all.first { $0.id == id }?.name ?? "System"
    }

    /// The theme picked in the settings; System follows the app's light or dark keyboard.
    static func named(_ id: String, dark: Bool) -> Theme {
        switch id {
        case "graphite": return palette(dark: true, bg: 0x000000, key: 0x2C2C2E, fn: 0x1C1C1F, text: 0xFFFFFF, accent: 0x3D9BFF)
        case "midnight": return palette(dark: true, bg: 0x0D1527, key: 0x223252, fn: 0x172440, text: 0xE8EEFC, accent: 0x6AA8FF)
        case "ocean": return palette(dark: true, bg: 0x05272C, key: 0x0F4851, fn: 0x0A3840, text: 0xE3FBFB, accent: 0x4FD1C5)
        case "forest": return palette(dark: true, bg: 0x0F1D15, key: 0x23402F, fn: 0x193224, text: 0xEAF7EE, accent: 0x7FD8A0)
        case "sunset": return palette(dark: true, bg: 0x2B1531, key: 0x512A4C, fn: 0x3D1F3C, text: 0xFFF0E8, accent: 0xFF9A62)
        case "rose": return palette(dark: false, bg: 0xF3D9DF, key: 0xFFFFFF, fn: 0xE5BCC7, text: 0x3A1D27, accent: 0xC84C72)
        case "lavender": return palette(dark: false, bg: 0xE0DBF3, key: 0xFFFFFF, fn: 0xCBC2EA, text: 0x29223F, accent: 0x7254D0)
        case "paper": return palette(dark: false, bg: 0xECE5D8, key: 0xFFFCF5, fn: 0xD9CFBD, text: 0x2B271F, accent: 0xA8702F)
        default:
            var t = make(dark: dark)
            t.clear = true
            return t
        }
    }

    /// White or `dark`, whichever reads better on `fill` (by contrast ratio).
    private static func readableOn(_ fill: UInt32, _ dark: UInt32) -> UIColor {
        func luminance(_ v: UInt32) -> CGFloat {
            func lin(_ c: UInt32) -> CGFloat {
                let s = CGFloat(c) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin((v >> 16) & 0xFF) + 0.7152 * lin((v >> 8) & 0xFF) + 0.0722 * lin(v & 0xFF)
        }
        let f = luminance(fill)
        let onWhite = 1.05 / (f + 0.05)
        let onDark = (f + 0.05) / (luminance(dark) + 0.05)
        return onWhite >= onDark ? .white : rgb(dark)
    }

    private static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// A colour theme from its five colours: background, letter keys, function keys, text, accent.
    private static func palette(dark: Bool, bg: UInt32, key: UInt32, fn: UInt32, text: UInt32, accent: UInt32) -> Theme {
        var t = Theme(
            background: rgb(bg),
            key: rgb(key),
            keyDown: rgb(fn),
            fnKey: rgb(fn),
            fnKeyDown: rgb(key),
            keyShadow: dark ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 0, alpha: 0.22),
            text: rgb(text),
            hint: rgb(text, 0.55),
            stripText: rgb(text),
            stripDim: rgb(text, 0.55),
            divider: rgb(text, 0.18),
            accent: rgb(accent),
            ghost: rgb(text, 0.7),
            bad: dark ? UIColor(red: 1.0, green: 0.45, blue: 0.40, alpha: 1) : UIColor(red: 0.71, green: 0.23, blue: 0.17, alpha: 1),
            good: dark ? UIColor(red: 0.35, green: 0.85, blue: 0.50, alpha: 1) : UIColor(red: 0.13, green: 0.55, blue: 0.27, alpha: 1),
            panel: rgb(bg),
            panelRow: rgb(key),
            dark: dark)
        // Shift on: like Apple's, a light key with a dark arrow (light themes: a letter key's colour).
        t.shiftOn = dark ? rgb(text) : rgb(key)
        t.shiftOnText = dark ? rgb(bg) : rgb(text)
        t.onAccent = readableOn(accent, dark ? bg : text)
        return t
    }

    static func make(dark: Bool) -> Theme {
        if dark {
            return Theme(
                background: UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1),
                key: UIColor(red: 0.42, green: 0.42, blue: 0.43, alpha: 1),
                keyDown: UIColor(red: 0.30, green: 0.30, blue: 0.31, alpha: 1),
                fnKey: UIColor(red: 0.27, green: 0.27, blue: 0.28, alpha: 1),
                fnKeyDown: UIColor(red: 0.42, green: 0.42, blue: 0.43, alpha: 1),
                keyShadow: UIColor(white: 0, alpha: 0.62),
                text: .white,
                hint: UIColor(white: 1, alpha: 0.55),
                stripText: .white,
                stripDim: UIColor(white: 1, alpha: 0.55),
                divider: UIColor(white: 1, alpha: 0.18),
                accent: UIColor(red: 0.40, green: 0.60, blue: 1.0, alpha: 1),
                ghost: UIColor(white: 0.75, alpha: 1),
                bad: UIColor(red: 1.0, green: 0.45, blue: 0.40, alpha: 1),
                good: UIColor(red: 0.35, green: 0.85, blue: 0.50, alpha: 1),
                panel: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
                panelRow: UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1),
                dark: true)
        }
        return Theme(
            background: UIColor(red: 0.82, green: 0.83, blue: 0.85, alpha: 1),
            key: .white,
            keyDown: UIColor(red: 0.70, green: 0.72, blue: 0.75, alpha: 1),
            fnKey: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
            fnKeyDown: .white,
            keyShadow: UIColor(red: 0.53, green: 0.54, blue: 0.57, alpha: 1),
            text: .black,
            hint: UIColor(white: 0, alpha: 0.45),
            stripText: .black,
            stripDim: UIColor(white: 0, alpha: 0.5),
            divider: UIColor(white: 0, alpha: 0.15),
            accent: UIColor(red: 0.18, green: 0.44, blue: 0.89, alpha: 1),
            ghost: UIColor(red: 0.35, green: 0.38, blue: 0.42, alpha: 1),
            bad: UIColor(red: 0.71, green: 0.23, blue: 0.17, alpha: 1),
            good: UIColor(red: 0.13, green: 0.55, blue: 0.27, alpha: 1),
            panel: UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1),
            panelRow: .white,
            dark: false)
    }
}

/// Sizes and timings from the Android keyboard (by way of the web trial), in points and seconds.
enum Metrics {
    /// The suggestion bar. (With the rows below, the keyboard plus the strip iOS 26 adds above it in
    /// some apps comes to about the height of the iPhone's own keyboard.)
    static let stripH: CGFloat = 37
    static let gapX: CGFloat = 5
    static let gapY: CGFloat = 11
    static let rowH: CGFloat = 52
    /// Rows were 54 pt before November 2026 (a swipe profile learned then carries over).
    static let oldRowH: CGFloat = 54
    static let rowHLandscape: CGFloat = 42
    static let bottomPad: CGFloat = 0
    static let promptButtonW: CGFloat = 84
    /// The narrowest a prompt's button gets (each is as wide as its label needs).
    static let promptButtonMinW: CGFloat = 64
    static let longPress = 0.35
    static let spaceLongPress = 0.55
    static let stripLongPress = 0.45
    static let repeatStart = 0.40
    static let repeatEvery = 0.055
    static let repeatFast = 0.030
    /// Finger travel, in key widths, that turns a letter press into a swipe.
    static let swipeStart: CGFloat = 0.7
    /// Travel that cancels a hold (for a number or an accent) on a letter key.
    static let longPressSlop: CGFloat = 0.25
    static let spaceDragStart: CGFloat = 0.5
    /// The space bar as a trackpad: finger travel per character (in key widths)...
    static let trackpadStep: CGFloat = 0.22
    /// ...and per line up or down (in rows).
    static let trackpadLine: CGFloat = 0.7
    /// For guessing how many characters fit on a line of an app's text (see charsPerLine): the
    /// screen's width less this, at this many points a character (17-point text).
    static let textMargins: CGFloat = 72
    static let textCharWidth: CGFloat = 8.2
    /// The training header above the suggestion bar.
    static let trainingHeaderH: CGFloat = 98
    /// Extra height while a settings panel is open.
    static let panelExtra: CGFloat = 98
    /// Emoji in the emoji panel and its search: one fixed size, drawn at 2 pixels a point
    /// (54 pixels). iOS keeps a picture of every emoji it draws in the keyboard's memory: about
    /// 20 KB each at this size, against about 52 KB at full sharpness, and a keyboard over its
    /// allowance is closed.
    static let emojiFont: CGFloat = 27
    static let emojiScale: CGFloat = 2
}
