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
}
