import XCTest
@testable import CodexTipCore

final class IndicatorStyleTests: XCTestCase {
    func testOldPreferencesAdoptLargerDotWithoutLosingSettings() throws {
        let data = Data(#"{"refreshMinutes":5,"periods":[10,60],"selectedWindowID":"codex/primary","compactMode":true,"language":"english"}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(preferences.effectiveDotSize, 10)
        XCTAssertEqual(preferences.dotColor(hasData: true), .green)
        XCTAssertEqual(preferences.dotColor(hasData: false), .blue)
        XCTAssertEqual(preferences.refreshMinutes, 5)
        XCTAssertTrue(preferences.compactMode)
        XCTAssertEqual(preferences.language, .english)
        XCTAssertEqual(preferences.effectiveIndicatorAppearance, .dot)
        XCTAssertEqual(preferences.effectiveEmojiSize, 16)
        XCTAssertEqual(preferences.emoji(hasData: true), "🙂")
        XCTAssertEqual(preferences.emoji(hasData: false), "😴")
    }

    func testSizeAndIndependentColorsSurvivePersistence() throws {
        var preferences = Preferences()
        preferences.dotSize = 14
        preferences.dataDotColor = .purple
        preferences.noDataDotColor = .orange
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.effectiveDotSize, 14)
        XCTAssertEqual(restored.dotColor(hasData: true), .purple)
        XCTAssertEqual(restored.dotColor(hasData: false), .orange)
    }

    func testInvalidSizesCannotOverflowMenuBar() {
        for size in [-10, 0, 1, 9, 1000] {
            var preferences = Preferences()
            preferences.dotSize = size
            XCTAssertEqual(preferences.effectiveDotSize, 10)
            preferences.validate()
            XCTAssertNil(preferences.dotSize)
        }
    }

    func testShortConsumptionFormatPreservesPartialAndUnknownStates() {
        XCTAssertEqual(Consumption.measured(points: 1, coverage: 600, partial: false).menuLabel(minutes: 10), "10m/1%")
        XCTAssertEqual(Consumption.measured(points: 0.5, coverage: 120, partial: true).menuLabel(minutes: 60), "1h/0.5%*")
        XCTAssertEqual(Consumption.measured(points: 0, coverage: 600, partial: false).menuLabel(minutes: 10), "10m/0%")
        XCTAssertEqual(Consumption.unavailable("gap").menuLabel(minutes: 10), "10m/—")
        XCTAssertEqual(Consumption.measured(points: 1, coverage: 600, partial: false).compact, "≈1%")
    }

    func testEmojiPreferencesPersistAndKeepDotSettings() throws {
        var preferences = Preferences()
        preferences.indicatorAppearance = .emoji
        preferences.emojiSize = 18
        preferences.dataEmoji = "👩🏽‍💻"
        preferences.noDataEmoji = "🌙"
        preferences.dataDotColor = .purple
        preferences.noDataDotColor = .orange
        preferences.dotSize = 14
        var restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.effectiveIndicatorAppearance, .emoji)
        XCTAssertEqual(restored.effectiveEmojiSize, 18)
        XCTAssertEqual(restored.emoji(hasData: true), "👩🏽‍💻")
        XCTAssertEqual(restored.emoji(hasData: false), "🌙")
        restored.indicatorAppearance = .dot
        XCTAssertEqual(restored.dotColor(hasData: true), .purple)
        XCTAssertEqual(restored.dotColor(hasData: false), .orange)
        XCTAssertEqual(restored.effectiveDotSize, 14)
        XCTAssertEqual(restored.emoji(hasData: true), "👩🏽‍💻")
    }

    func testEmojiValidationAcceptsWholeGraphemesAndRejectsText() {
        for emoji in StatusEmoji.presets + ["👩🏽‍💻", "🇯🇵", "👨‍👩‍👧‍👦", "1️⃣", "🏳️‍🌈"] {
            XCTAssertEqual(StatusEmoji.normalized(emoji), emoji)
        }
        XCTAssertEqual(StatusEmoji.normalized("  🙂\n"), "🙂")
        for value in ["", " ", "a", "1", "12", "#", "hello", "🙂🙂", "🙂 text", "\n\t", "🏽", String(repeating: "🙂", count: 1000)] {
            XCTAssertNil(StatusEmoji.normalized(value), value)
        }
    }

    func testInvalidStoredEmojiFallsBackSafely() {
        var preferences = Preferences()
        preferences.indicatorAppearance = .emoji
        preferences.emojiSize = 1000
        preferences.dataEmoji = "not an emoji"
        preferences.noDataEmoji = "🙂🙂"
        XCTAssertEqual(preferences.effectiveEmojiSize, 16)
        XCTAssertEqual(preferences.emoji(hasData: true), "🙂")
        XCTAssertEqual(preferences.emoji(hasData: false), "😴")
        preferences.validate()
        XCTAssertNil(preferences.emojiSize)
        XCTAssertNil(preferences.dataEmoji)
        XCTAssertNil(preferences.noDataEmoji)
        XCTAssertEqual(preferences.effectiveIndicatorAppearance, .emoji)
    }
}
