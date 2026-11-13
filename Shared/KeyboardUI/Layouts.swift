// The keys: letters, two pages of symbols, and what holding a key offers. Ported from the web
// trial (itself from the Android app's Layout.java), plus a globe key for iPhones that need one.

import UIKit
import TrailEngine

/// Extra key codes the keyboard handles itself (not the typing logic).
enum UIKeyCode {
    static let globe = -8
}

final class Key {
    let code: Int
    let label: String
    /// Small hint in the corner (the number on the top row).
    let hint: String?
    /// What holding the key offers; the first is what you get letting go without sliding.
    let alts: [String]?
    /// In key widths.
    let width: CGFloat
    /// Where it's drawn, and the area that counts as touching it (edge keys reach the edge).
    var rect = CGRect.zero
    var hit = CGRect.zero

    init(_ code: Int, _ label: String, hint: String? = nil, alts: [String]? = nil, width: CGFloat = 1) {
        self.code = code
        self.label = label
        self.hint = hint
        self.alts = (alts?.isEmpty ?? true) ? nil : alts
        self.width = width
    }

    var isLetter: Bool { code >= 97 && code <= 122 }
    /// Function keys (shift, delete, layout switches, return) are drawn darker.
    var isFunction: Bool { code < 0 }
    var showsPreview: Bool { code > 32 && !label.isEmpty && label.count <= 2 }
}

struct KeyLayout {
    let name: LayoutName
    var rows: [[Key]]
}

enum Layouts {
    static let alts: [String: [String]] = [
        "a": ["á", "à", "â", "ä", "ã"],
        "e": ["é", "è", "ê", "ë"],
        "i": ["í", "ì", "î", "ï"],
        "o": ["ó", "ò", "ô", "ö", "õ"],
        "u": ["ú", "ü", "ù", "û"],
        "n": ["ñ"],
        ".": ["?", "!", "¿", "¡", "…"],
        "?": ["¿"],
        "!": ["¡"],
    ]

    private static func chars(_ s: String) -> [Key] {
        s.map { c in
            let str = String(c)
            return Key(Int(str.unicodeScalars.first!.value), str, alts: alts[str])
        }
    }

    private static func bottomRow(letters: Bool, globe: Bool) -> [Key] {
        let switchKey = letters ? Key(KeyCode.symbols, "123", width: globe ? 1.25 : 1.5)
                                : Key(KeyCode.letters, "ABC", width: globe ? 1.25 : 1.5)
        var row = [switchKey]
        if globe { row.append(Key(UIKeyCode.globe, "", width: 1)) }
        row.append(Key(44, ","))
        row.append(Key(KeyCode.emoji, "", width: 1))
        row.append(Key(KeyCode.space, "", width: globe ? 3.5 : 4))
        row.append(Key(46, ".", alts: alts["."]))
        row.append(Key(KeyCode.enter, "", width: globe ? 1.25 : 1.5))
        return row
    }

    static func letters(globe: Bool) -> KeyLayout {
        let top = Array("qwertyuiop")
        let digits = Array("1234567890")
        var r0 = [Key]()
        for (i, c) in top.enumerated() {
            let s = String(c)
            r0.append(Key(Int(s.unicodeScalars.first!.value), s, hint: String(digits[i]), alts: [String(digits[i])] + (alts[s] ?? [])))
        }
        return KeyLayout(name: .letters, rows: [
            r0,
            chars("asdfghjkl"),
            [Key(KeyCode.shift, "", width: 1.5)] + chars("zxcvbnm") + [Key(KeyCode.delete, "", width: 1.5)],
            bottomRow(letters: true, globe: globe),
        ])
    }

    static func symbols(globe: Bool) -> KeyLayout {
        KeyLayout(name: .symbols, rows: [
            chars("1234567890"),
            chars("@#$_&-+()/"),
            [Key(KeyCode.symbols2, "=\\<", width: 1.5)] + chars("*\"':;!?") + [Key(KeyCode.delete, "", width: 1.5)],
            bottomRow(letters: false, globe: globe),
        ])
    }

    static func symbols2(globe: Bool) -> KeyLayout {
        KeyLayout(name: .symbols2, rows: [
            chars("~`|•√π÷×¶∆"),
            chars("£€¥^°={}[]"),
            [Key(KeyCode.symbols, "123", width: 1.5)] + chars("%©®™<>\\") + [Key(KeyCode.delete, "", width: 1.5)],
            bottomRow(letters: false, globe: globe),
        ])
    }

    /// Each row is 10 key widths; short rows are centred and their edge keys' touch areas reach the edge.
    static func place(_ L: inout KeyLayout, width: CGFloat, top: CGFloat, rowH: CGFloat, gapX: CGFloat, gapY: CGFloat) {
        let unit = width / 10
        for (r, row) in L.rows.enumerated() {
            var total: CGFloat = 0
            for k in row { total += k.width }
            var x = (10 - total) / 2 * unit
            let y = top + CGFloat(r) * rowH
            for (i, k) in row.enumerated() {
                let w = k.width * unit
                k.rect = CGRect(x: x + gapX / 2, y: y + gapY / 2, width: w - gapX, height: rowH - gapY)
                let l = i == 0 ? 0 : x
                let rr = i == row.count - 1 ? width : x + w
                k.hit = CGRect(x: l, y: y, width: rr - l, height: rowH)
                x += w
            }
        }
    }

    /// The key under a point, or the nearest one.
    static func keyAt(_ L: KeyLayout, _ p: CGPoint) -> Key? {
        var nearest: Key?
        var best = CGFloat.infinity
        for row in L.rows {
            for k in row {
                let h = k.hit
                if p.x >= h.minX && p.x < h.maxX && p.y >= h.minY && p.y < h.maxY { return k }
                let dx = max(h.minX - p.x, 0, p.x - h.maxX)
                let dy = max(h.minY - p.y, 0, p.y - h.maxY)
                let d = dx * dx + dy * dy
                if d < best {
                    best = d
                    nearest = k
                }
            }
        }
        return nearest
    }
}

/// The emoji the emoji panel offers (the same set as the web trial).
let EMOJI: [String] = {
    let all = """
    😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 \
    😑 😶 😏 😒 🙄 😬 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 😵 🤯 🤠 🥳 😎 🤓 😕 😟 🙁 😮 😯 😲 😳 🥺 \
    😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 💀 💩 🤡 👻 👽 🤖 😺 😸 😹 😻 🙀 😿 \
    👋 🤚 ✋ 🖖 👌 🤌 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 👏 🙌 👐 🤲 🤝 🙏 💪 👀 🧠 💅 🤳 \
    ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 💔 ❣️ 💕 💞 💓 💗 💖 💘 💯 🔥 ✨ ⭐ 🌟 💥 💢 💦 💨 💫 💬 💤 🎉 🎊 🎁 🎂 \
    🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦆 🦉 🐝 🦋 🐢 🐍 🐙 🐠 🐬 🐳 🦈 🐊 🦄 🐉 \
    🌵 🌲 🌴 🌱 🍀 🍁 🍄 🌹 🌻 🌸 🌞 🌙 ☁️ 🌧️ ⛈️ ❄️ ☃️ 🌈 🌊 🌍 🍎 🍊 🍋 🍌 🍉 🍇 🍓 🍑 🥑 🍅 🌽 🥕 \
    🍞 🧀 🍳 🥓 🍔 🍟 🍕 🌭 🌮 🌯 🍝 🍜 🍣 🍱 🍛 🍚 🍩 🍪 🍰 🧁 🍫 🍬 🍭 🍿 ☕ 🍵 🥤 🍺 🍻 🍷 🥂 🍸 \
    ⚽ 🏀 🏈 ⚾ 🎾 🏐 🏒 🎮 🕹️ 🎲 🧩 🎨 🎬 🎤 🎧 🎵 🎸 🎹 📷 📱 💻 ⌨️ 🖥️ 💡 📚 ✏️ 📝 📅 📌 📎 🔒 🔑 \
    🔨 🛠️ ⚙️ 💰 💸 💳 ✉️ 🚗 🚕 🚌 🚆 ✈️ 🚀 🚲 🏠 ✅ ❌ ❓ ❗ ⚠️ 🚫 ♻️ ✔️ ➕ ➖ ➡️ ⬅️ ⬆️ ⬇️ 🔴 🟢 🇨🇦
    """
    var seen = Set<String>()
    var out = [String]()
    for s in all.split(separator: " ").map(String.init) where !s.isEmpty && !seen.contains(s) {
        seen.insert(s)
        out.append(s)
    }
    return out
}()
