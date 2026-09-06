import XCTest
@testable import CodexTipCore

final class LocalizationTests: XCTestCase {
    override func tearDown() { L10n.language = .system; super.tearDown() }

    func testSystemLanguageResolution() {
        XCTAssertTrue(AppLanguage.system.usesChinese(preferredLanguages: ["zh-Hans-CN", "en-US"]))
        XCTAssertTrue(AppLanguage.system.usesChinese(preferredLanguages: ["zh-Hant-TW"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(preferredLanguages: ["en-US", "zh-Hans"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(preferredLanguages: ["ja-JP"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(preferredLanguages: []))
        XCTAssertTrue(AppLanguage.chinese.usesChinese(preferredLanguages: ["en"]))
        XCTAssertFalse(AppLanguage.english.usesChinese(preferredLanguages: ["zh"]))
    }

    func testEnglishQuotaAndConsumptionLabels() {
        L10n.language = .english
        let week = RateWindow(usedPercent: 15, windowDurationMins: 10080, resetsAt: nil)
        XCTAssertEqual(week.label, "Weekly quota")
        XCTAssertEqual(week.compactLabel, "wk")
        XCTAssertEqual(RateWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil).label, "5-hour quota")
        XCTAssertEqual(L10n.period(10), "Last 10 min")
        XCTAssertEqual(L10n.period(60), "Last 1 hour")
        XCTAssertEqual(L10n.period(180), "Last 3 hours")
        XCTAssertEqual(Consumption.measured(points: 2, coverage: 120, partial: true).detail, "2 min recorded")
        XCTAssertEqual(UsageHistory().consumption(windowID: "codex/primary", seconds: 600), .unavailable("Account identity unavailable"))
        XCTAssertTrue(ClientError.timeout.localizedDescription.contains("timed out"))
    }

    func testChineseAndLanguageSwitching() {
        let week = RateWindow(usedPercent: 15, windowDurationMins: 10080, resetsAt: nil)
        L10n.language = .chinese
        XCTAssertEqual(week.label, "周额度")
        XCTAssertEqual(L10n.period(60), "最近 1 小时")
        XCTAssertEqual(L10n.locale.identifier, "zh_CN")
        L10n.language = .english
        XCTAssertEqual(week.label, "Weekly quota")
        XCTAssertEqual(L10n.locale.identifier, "en_US")
    }

    func testExistingPreferencesMigrateWithoutLosingSettings() throws {
        let json = #"{"refreshMinutes":5,"periods":[10,60],"selectedWindowID":"spark/primary","compactMode":true}"#
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertNil(preferences.language)
        XCTAssertEqual(preferences.refreshMinutes, 5)
        XCTAssertEqual(preferences.selectedWindowID, "spark/primary")
        XCTAssertTrue(preferences.compactMode)
    }

    func testLanguageSettingSurvivesPersistence() throws {
        var preferences = Preferences()
        preferences.language = .english
        let data = try JSONEncoder().encode(preferences)
        let loaded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(loaded.language, .english)
    }
}
