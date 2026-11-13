// Colours and sizes, close to the iPhone's own keyboard, in light and dark.

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

    static func make(dark: Bool) -> Theme {
        if dark {
            return Theme(
                background: UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1),
                key: UIColor(red: 0.42, green: 0.42, blue: 0.43, alpha: 1),
                keyDown: UIColor(red: 0.30, green: 0.30, blue: 0.31, alpha: 1),
                fnKey: UIColor(red: 0.27, green: 0.27, blue: 0.28, alpha: 1),
                fnKeyDown: UIColor(red: 0.42, green: 0.42, blue: 0.43, alpha: 1),
                keyShadow: UIColor(white: 0, alpha: 0.6),
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
            background: UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1),
            key: .white,
            keyDown: UIColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1),
            fnKey: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
            fnKeyDown: .white,
            keyShadow: UIColor(red: 0.53, green: 0.54, blue: 0.56, alpha: 1),
            text: .black,
            hint: UIColor(white: 0, alpha: 0.45),
            stripText: .black,
            stripDim: UIColor(white: 0, alpha: 0.5),
            divider: UIColor(white: 0, alpha: 0.15),
            accent: UIColor(red: 0.18, green: 0.44, blue: 0.89, alpha: 1),
            ghost: UIColor(red: 0.36, green: 0.38, blue: 0.42, alpha: 1),
            bad: UIColor(red: 0.71, green: 0.23, blue: 0.17, alpha: 1),
            good: UIColor(red: 0.13, green: 0.55, blue: 0.27, alpha: 1),
            panel: UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1),
            panelRow: .white,
            dark: false)
    }
}

/// Sizes and timings from the Android keyboard (by way of the web trial), in points and seconds.
enum Metrics {
    static let stripH: CGFloat = 44
    static let gapX: CGFloat = 6
    static let gapY: CGFloat = 11
    static let rowH: CGFloat = 54
    static let rowHLandscape: CGFloat = 42
    static let bottomPad: CGFloat = 4
    static let promptButtonW: CGFloat = 84
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
    static let spaceDragStep: CGFloat = 0.4
    /// The training header above the suggestion bar.
    static let trainingHeaderH: CGFloat = 96
    /// Extra height while a settings panel is open.
    static let panelExtra: CGFloat = 96
}
