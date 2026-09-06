import XCTest
@testable import CodexTipCore

final class ActivityAnimationTests: XCTestCase {
    func testOnlyPositiveConsumptionIsActive() {
        for partial in [true, false] {
            for points in [0.01, 1, 10] {
                XCTAssertEqual(UsageActivity(consumption: .measured(points: points, coverage: 600, partial: partial)), .active)
            }
            for points in [0.0, -1.0] {
                XCTAssertEqual(UsageActivity(consumption: .measured(points: points, coverage: 600, partial: partial)), .idle)
            }
        }
        for points in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(UsageActivity(consumption: .measured(points: points, coverage: 600, partial: false)), .unknown)
        }
        XCTAssertEqual(UsageActivity(consumption: .unavailable("stale")), .unknown)
        XCTAssertFalse(UsageActivity.unknown.isActive)
    }

    func testActiveReturnsToIdleAfterConsumptionLeavesTenMinuteWindow() {
        var history = UsageHistory()
        let origin = Date(timeIntervalSince1970: 1_780_000_000)
        for minute in 0...12 {
            history.append(UsageSnapshot(date: origin.addingTimeInterval(Double(minute) * 60), interval: 60,
                                         accountKey: "demo", windows: [
                WindowSnapshot(id: "codex/primary", bucketID: "codex", name: "Codex", plan: "pro",
                               window: RateWindow(usedPercent: minute == 0 ? 10 : 11, windowDurationMins: 10080,
                                                  resetsAt: 1_790_000_000))
            ]))
            let activity = UsageActivity(consumption: history.consumption(windowID: "codex/primary", seconds: 600))
            XCTAssertEqual(activity, minute == 0 ? .unknown : minute <= 10 ? .active : .idle)
        }
    }

    func testAnimationMigrationAndIndependentStatePersistence() throws {
        let old = Data(#"{"refreshMinutes":5,"periods":[10,60],"selectedWindowID":"codex/primary","compactMode":true,"indicatorAppearance":"emoji","dataEmoji":"🚀","noDataEmoji":"🌙"}"#.utf8)
        var preferences = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertFalse(preferences.hasAnimation)
        XCTAssertEqual(preferences.animation(hasData: true), .none)
        XCTAssertEqual(preferences.animation(hasData: false), .none)
        preferences.dataAnimation = .bounce; preferences.noDataAnimation = .breathe
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.animation(hasData: true), .bounce)
        XCTAssertEqual(restored.animation(hasData: false), .breathe)
        XCTAssertEqual(restored.emoji(hasData: true), "🚀")
        XCTAssertEqual(restored.emoji(hasData: false), "🌙")
        XCTAssertEqual(restored.refreshMinutes, 5)
        XCTAssertTrue(restored.compactMode)
    }
}
