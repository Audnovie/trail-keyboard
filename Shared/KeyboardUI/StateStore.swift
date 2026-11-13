// Everything the keyboard keeps between uses, in one JSON file inside the keyboard's own storage
// on this iPhone: settings, learned words and never-suggest lists per language, swipe profiles
// and training results. Nothing else is written anywhere, the keyboard has no network access
// (Full Access is off), and the file is left out of iCloud backups. Every bit of it can be seen
// and deleted from the keyboard's settings.

import Foundation
import TrailEngine

struct AppSettings: Codable, Equatable {
    var swipe = true
    var smartFix = true
    var autocorrect = false
    var doubleSpace = true
    var learn = true
    var useProfile = true
    /// Languages switched on (English always is).
    var languages = ["en", "es"]
    /// "auto" or a language code.
    var typingLang = "auto"
    var lastLang = "en"

    init() {}

    enum CodingKeys: String, CodingKey {
        case swipe, smartFix, autocorrect, doubleSpace, learn, useProfile, languages, typingLang, lastLang
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        swipe = (try? c.decodeIfPresent(Bool.self, forKey: .swipe)) ?? nil ?? d.swipe
        smartFix = (try? c.decodeIfPresent(Bool.self, forKey: .smartFix)) ?? nil ?? d.smartFix
        autocorrect = (try? c.decodeIfPresent(Bool.self, forKey: .autocorrect)) ?? nil ?? d.autocorrect
        doubleSpace = (try? c.decodeIfPresent(Bool.self, forKey: .doubleSpace)) ?? nil ?? d.doubleSpace
        learn = (try? c.decodeIfPresent(Bool.self, forKey: .learn)) ?? nil ?? d.learn
        useProfile = (try? c.decodeIfPresent(Bool.self, forKey: .useProfile)) ?? nil ?? d.useProfile
        let langs = (try? c.decodeIfPresent([String].self, forKey: .languages)) ?? nil ?? d.languages
        languages = KeyboardLanguages.all.filter { $0 == "en" || langs.contains($0) }
        let tl = (try? c.decodeIfPresent(String.self, forKey: .typingLang)) ?? nil ?? d.typingLang
        typingLang = tl == "auto" || KeyboardLanguages.all.contains(tl) ? tl : "auto"
        let ll = (try? c.decodeIfPresent(String.self, forKey: .lastLang)) ?? nil ?? d.lastLang
        lastLang = KeyboardLanguages.all.contains(ll) ? ll : "en"
    }

    var typing: TypingSettings {
        var t = TypingSettings()
        t.swipe = swipe
        t.smartFix = smartFix
        t.autocorrect = autocorrect
        t.doubleSpace = doubleSpace
        t.learn = learn
        t.typingLang = typingLang
        t.lastLang = lastLang
        return t
    }
}

enum KeyboardLanguages {
    static let all = ["en", "es"]
}

/// Training results. "recent" keeps the last 40 misses (the word, what came out, where yours
/// ranked) so the next rounds can retry them; they're words from the training list or swipes
/// you corrected while typing.
struct TestStats: Codable, Equatable {
    struct Round: Codable, Equatable {
        var n = 0
        var top1 = 0
        var ab = 0
        var on = 0
        var off = 0
    }

    struct Miss: Codable, Equatable {
        /// The word meant.
        var w: String
        /// What came out first.
        var g: String
        /// Where the meant word ranked (-1 if not in the top 8).
        var r: Int
        /// "t" in training, "f" fixed while typing.
        var m: String
        var l: String?
    }

    var n = 0
    var top1 = 0
    var top3 = 0
    var fixes = 0
    var recent = [Miss]()
    var rounds = 0
    var round = Round()

    init() {}

    enum CodingKeys: String, CodingKey { case n, top1, top3, fixes, recent, rounds, round }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? nil ?? 0
        top1 = (try? c.decodeIfPresent(Int.self, forKey: .top1)) ?? nil ?? 0
        top3 = (try? c.decodeIfPresent(Int.self, forKey: .top3)) ?? nil ?? 0
        fixes = (try? c.decodeIfPresent(Int.self, forKey: .fixes)) ?? nil ?? 0
        recent = Array(((try? c.decodeIfPresent([Miss].self, forKey: .recent)) ?? nil ?? []).prefix(40))
        rounds = (try? c.decodeIfPresent(Int.self, forKey: .rounds)) ?? nil ?? 0
        round = (try? c.decodeIfPresent(Round.self, forKey: .round)) ?? nil ?? Round()
    }
}

struct SavedState: Codable {
    var v = 2
    var updatedAt: Double = 0
    var langs = [String: UserWords.Saved]()
    var settings = AppSettings()
    var tests = TestStats()
    var profiles = [String: SwipeProfile.Saved]()

    init() {}

    enum CodingKeys: String, CodingKey { case v, updatedAt, langs, settings, tests, profiles }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? nil ?? 2
        updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil ?? 0
        if let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .langs)) ?? nil {
            for (code, value) in raw {
                if let data = try? JSONEncoder().encode(value), let s = try? JSONDecoder().decode(UserWords.Saved.self, from: data) {
                    langs[code] = s
                }
            }
        }
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? nil ?? AppSettings()
        tests = (try? c.decodeIfPresent(TestStats.self, forKey: .tests)) ?? nil ?? TestStats()
        if let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .profiles)) ?? nil {
            for (key, value) in raw {
                if let data = try? JSONEncoder().encode(value), let p = try? JSONDecoder().decode(SwipeProfile.Saved.self, from: data) {
                    profiles[key] = p
                }
            }
        }
    }
}

final class StateStore {
    let url: URL
    /// Something about saving the user should know (shown in settings), or nil.
    private(set) var problem: String?
    /// False after the saved file couldn't be read, so a fresh start never overwrites it.
    private(set) var canSave = true

    init(fileName: String) {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        var dir = base.appendingPathComponent("Trail", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Learned words stay on this iPhone: not in iCloud or computer backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        url = dir.appendingPathComponent(fileName)
    }

    /// The saved state, or nil for a fresh start.
    func load() -> SavedState? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            canSave = false
            problem = "Your saved words couldn't be opened just now, so nothing new will be saved until the keyboard is reopened."
            return nil
        }
        if let s = try? JSONDecoder().decode(SavedState.self, from: data) { return s }
        // Unreadable: keep the file aside rather than overwrite it.
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("state-unreadable-\(stamp).json")
        do {
            try fm.moveItem(at: url, to: aside)
            problem = "Your saved words file couldn't be read, so it was set aside (\(aside.lastPathComponent)) and the keyboard started fresh."
        } catch {
            canSave = false
            problem = "Your saved words file couldn't be read, so nothing new will be saved over it."
        }
        return nil
    }

    func save(_ s: SavedState) {
        guard canSave else { return }
        do {
            let data = try JSONEncoder().encode(s)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            problem = nil
        } catch {
            problem = "The last save didn't go through. Your changes are kept while the keyboard is open and will save on the next change."
        }
    }

    /// Bytes on disk, for showing.
    var fileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Earlier saved files that couldn't be read and were set aside rather than overwritten.
    var setAside: [URL] {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("state-unreadable-") && $0.hasSuffix(".json") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// Deletes everything saved, set-aside copies included. Saving works again afterwards.
    func eraseAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        for u in setAside { try? fm.removeItem(at: u) }
        canSave = true
        problem = nil
    }
}
