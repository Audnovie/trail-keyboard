// The emoji panel's list (Resources/Emoji/emoji.tsv): Apple's categories and order, only emoji
// the iPhone can draw, and searching in English and Spanish.

import XCTest
@testable import TrailEngine

final class EmojiCatalogTests: XCTestCase {
    private static let path = TestData.repoRoot.appendingPathComponent("Resources/Emoji/emoji.tsv").path

    private func catalog(_ newest: Double = 17) -> EmojiCatalog {
        guard let c = EmojiCatalog(path: EmojiCatalogTests.path, newest: newest) else {
            fatalError("can't read \(EmojiCatalogTests.path)")
        }
        return c
    }

    private func category(_ c: EmojiCatalog, _ e: String) -> Int? {
        c.items.first { $0.emoji == e }?.category
    }

    func testCategoriesInApplesOrder() {
        let c = catalog()
        XCTAssertEqual(c.sections.count, EmojiCatalog.categories.count)
        XCTAssertGreaterThan(c.items.count, 1800)
        for (i, s) in c.sections.enumerated() {
            XCTAssertFalse(s.isEmpty, EmojiCatalog.categories[i])
            for k in s { XCTAssertEqual(c.items[k].category, i) }
        }
        XCTAssertEqual(c.sections.map(\.count).reduce(0, +), c.items.count, "each emoji in one category")
        XCTAssertEqual(c.items[c.sections[0][0]].emoji, "😀")
        XCTAssertEqual(c.items[c.sections[6][0]].emoji, "💘", "hearts open Symbols, as on Apple's keyboard")
        XCTAssertEqual(category(c, "❤️"), 6)
        XCTAssertEqual(category(c, "👕"), 0, "clothing with Smileys & People")
        XCTAssertEqual(category(c, "🐶"), 1)
        XCTAssertEqual(category(c, "🍕"), 2)
        XCTAssertEqual(category(c, "⚽"), 3)
        XCTAssertEqual(category(c, "🚗"), 4)
        XCTAssertEqual(category(c, "💡"), 5)
        XCTAssertEqual(category(c, "🇨🇦"), 7)
        XCTAssertEqual(Set(c.items.map(\.emoji)).count, c.items.count, "no emoji twice")
    }

    func testOnlyEmojiThisIPhoneCanDraw() {
        func v(_ major: Int, _ minor: Int) -> Double {
            EmojiCatalog.newestVersion(iOS: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        XCTAssertEqual(v(15, 0), 13.1)
        XCTAssertEqual(v(15, 4), 14)
        XCTAssertEqual(v(16, 3), 14)
        XCTAssertEqual(v(16, 4), 15)
        XCTAssertEqual(v(17, 4), 15.1)
        XCTAssertEqual(v(18, 3), 15.1)
        XCTAssertEqual(v(18, 4), 16)
        XCTAssertEqual(v(26, 1), 16)
        XCTAssertEqual(v(26, 4), 17)
        XCTAssertEqual(v(27, 0), 17)
        let old = catalog(13.1)
        let new = catalog(17)
        XCTAssertLessThan(old.items.count, new.items.count)
        XCTAssertNil(category(old, "🫠"), "melting face is Emoji 14")
        XCTAssertEqual(category(new, "🫠"), 0)
        XCTAssertNil(category(catalog(16), "🫍"), "orca is Emoji 17")
    }

    func testSearchInEnglishAndSpanish() {
        let c = catalog()
        XCTAssertEqual(c.search("heart").first, "❤️")
        XCTAssertEqual(c.search("Corazón").first, "❤️")
        XCTAssertEqual(c.search("red heart").first, "❤️")
        XCTAssertEqual(c.search("thumbs up").first, "👍")
        XCTAssertEqual(c.search("canada"), ["🇨🇦"])
        XCTAssertTrue(c.search("pizza").contains("🍕"))
        XCTAssertTrue(c.search("perro").contains("🐶"))
        XCTAssertTrue(c.search("hea").contains("❤️"), "the start of a word is enough")
        XCTAssertFalse(c.search("art").contains("❤️"), "only the starts of words count")
        XCTAssertTrue(c.search("").isEmpty)
        XCTAssertTrue(c.search("  ").isEmpty)
        XCTAssertTrue(c.search("xyzzy").isEmpty)
        XCTAssertLessThanOrEqual(c.search("a").count, 80)
        XCTAssertTrue(c.search("hairy creature").contains("🫈"))
        XCTAssertFalse(catalog(16).search("hairy creature").contains("🫈"), "newer emoji aren't offered to older iPhones")
    }

    func testNormalize() {
        XCTAssertEqual(EmojiCatalog.normalize("  Corazón  ROJO! "), "corazon rojo")
        XCTAssertEqual(EmojiCatalog.normalize("T-shirt"), "t shirt")
        XCTAssertEqual(EmojiCatalog.normalize("piñata"), "pinata")
        XCTAssertEqual(EmojiCatalog.normalize("100"), "100")
    }

    func testSearchIsQuick() {
        let c = catalog()
        let queries = ["h", "he", "hea", "heart", "c", "co", "cor", "corazon", "smile", "fire", "a", "e"]
        let start = Date()
        for q in queries { _ = c.search(q) }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(queries.count)
        print(String(format: "BUDGET emoji search: %.1f ms a search", ms))
        #if !DEBUG
        XCTAssertLessThan(ms, 30)
        #endif
    }
}
