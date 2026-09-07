import XCTest
@testable import CodexTipCore

final class UsageTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.language = .chinese }
    override func tearDown() { L10n.language = .system; super.tearDown() }
    private let origin = Date(timeIntervalSince1970: 1_780_000_000)
    private func sample(_ minute: Double, _ used: Double?, account: String? = "account-a", interval: Double = 60,
                        reset: Double = 1_790_000_000, duration: Int = 10080) -> UsageSnapshot {
        UsageSnapshot(date: origin.addingTimeInterval(minute * 60), interval: interval, accountKey: account, windows: [
            WindowSnapshot(id: "codex/primary", bucketID: "codex", name: "Codex", plan: "pro",
                           window: RateWindow(usedPercent: used, windowDurationMins: duration, resetsAt: reset))
        ])
    }
    private func measured(_ result: Consumption, points: Double, partial: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .measured(value, _, isPartial) = result else { return XCTFail("Expected measured, got \(result)", file: file, line: line) }
        XCTAssertEqual(value, points, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(isPartial, partial, file: file, line: line)
    }
    private func delta(_ history: UsageHistory, minutes: Double = 10) -> Consumption {
        history.consumption(windowID: "codex/primary", seconds: minutes * 60)
    }

    func testRecentDataExpiresUsingWallClock() {
        var history = UsageHistory()
        history.append(sample(0, 15))
        XCTAssertTrue(history.hasRecentData(windowID: "codex/primary", now: origin))
        XCTAssertTrue(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(600)))
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(600.001)))
    }

    func testRecentDataDoesNotRequireConsumption() {
        var history = UsageHistory()
        history.append(sample(0, 0)); history.append(sample(1, 0))
        XCTAssertTrue(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(60)))
    }

    func testRecentDataRejectsEmptyMissingInvalidAndFutureSamples() {
        var history = UsageHistory()
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin))
        history.append(sample(0, nil))
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin))
        history.append(sample(1, 101))
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(60)))
        history.append(sample(2, 15))
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(90)))
    }

    func testRecentDataUsesSelectedWindowAndCurrentAccount() {
        var history = UsageHistory()
        history.append(sample(0, 15))
        XCTAssertFalse(history.hasRecentData(windowID: "spark/primary", now: origin))
        history.append(sample(1, nil, account: "account-b"))
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(60)))
    }

    func testRecentValidDataSurvivesAnIncompleteReadingWithinTenMinutes() {
        var history = UsageHistory()
        history.append(sample(0, 15)); history.append(sample(1, nil))
        XCTAssertTrue(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(90)))
        XCTAssertFalse(history.hasRecentData(windowID: "codex/primary", now: origin.addingTimeInterval(601)))
    }

    func testLatestQuotaCanShowRecentDataWithoutAnAccountIdentifier() {
        var history = UsageHistory()
        history.append(sample(0, 15, account: nil))
        XCTAssertTrue(history.hasRecentData(windowID: "codex/primary", now: origin))
        XCTAssertEqual(delta(history), .unavailable("账户标识不可用"))
    }

    func testNormalTenMinutesAndHour() {
        var history = UsageHistory()
        for i in 0...60 { history.append(sample(Double(i), 10 + Double(i) * 0.2)) }
        measured(delta(history), points: 2)
        measured(delta(history, minutes: 60), points: 12)
    }

    func testPartialHistoryClearlyMarked() {
        var history = UsageHistory()
        history.append(sample(0, 10))
        XCTAssertEqual(delta(history), .unavailable("正在积累采样"))
        history.append(sample(1, 12))
        measured(delta(history), points: 2, partial: true)
        XCTAssertEqual(delta(history).compact, "≈2%*")
    }

    func testInterpolationWithFiveMinuteSampling() {
        var history = UsageHistory()
        history.append(sample(0, 10, interval: 300))
        history.append(sample(5, 12, interval: 300))
        history.append(sample(10, 14, interval: 300))
        history.append(sample(12, 16, interval: 300))
        measured(delta(history), points: 5.2)
    }

    func testResetDoesNotEraseHourWhenTenMinutesHaveRecovered() {
        var history = UsageHistory()
        for minute in 0...60 {
            let beforeReset = minute < 45
            history.append(sample(Double(minute), beforeReset ? 10 + Double(minute) * 0.1 : Double(minute - 45) * 0.2,
                                  reset: beforeReset ? 1_790_000_000 : 1_800_000_000))
        }
        measured(delta(history), points: 2)
        XCTAssertEqual(delta(history, minutes: 60).compact, "≈7.4%*")
        XCTAssertEqual(history.samples.count, 61)
    }

    func testResetNotReportedAsZero() {
        var history = UsageHistory()
        history.append(sample(0, 90))
        history.append(sample(1, 2, reset: 1_800_000_000))
        XCTAssertEqual(delta(history), .unavailable("期间额度已重置或调整"))
    }

    func testResetWithRisingUsageStillInvalidatesHistory() {
        var history = UsageHistory()
        history.append(sample(0, 1))
        history.append(sample(1, 5, reset: 1_800_000_000))
        XCTAssertEqual(delta(history), .unavailable("期间额度已重置或调整"))
    }

    func testUsageCorrectionNotTreatedAsConsumption() {
        var history = UsageHistory()
        history.append(sample(0, 30)); history.append(sample(1, 29))
        XCTAssertEqual(delta(history), .unavailable("期间额度已重置或调整"))
    }

    func testResetOutsideRequestedRangeDoesNotPoisonNewData() {
        var history = UsageHistory()
        history.append(sample(0, 90))
        for i in 1...12 { history.append(sample(Double(i), Double(i), reset: 1_800_000_000)) }
        measured(delta(history), points: 10)
        XCTAssertEqual(delta(history, minutes: 60), .resetPartial(points: 11, coverage: 660))
    }

    func testMultipleResetsPreserveKnownSegmentsWithoutCountingRefills() {
        var history = UsageHistory()
        for (minute, used, reset) in [(0.0, 90.0, 1_790_000_000.0), (1, 95, 1_790_000_000),
                                     (2, 2, 1_800_000_000), (3, 4, 1_800_000_000),
                                     (4, 1, 1_810_000_000), (5, 4, 1_810_000_000)] {
            history.append(sample(minute, used, reset: reset))
        }
        XCTAssertEqual(delta(history), .resetPartial(points: 10, coverage: 180))
        XCTAssertEqual(delta(history).menuLabel(minutes: 60), "1h/10%*")
        XCTAssertEqual(UsageActivity(consumption: delta(history)), .active)
    }

    func testZeroKnownConsumptionAcrossResetRemainsUnknownActivity() {
        var history = UsageHistory()
        history.append(sample(0, 5)); history.append(sample(1, 5))
        history.append(sample(2, 0, reset: 1_800_000_000)); history.append(sample(3, 0, reset: 1_800_000_000))
        XCTAssertEqual(delta(history), .resetPartial(points: 0, coverage: 120))
        XCTAssertEqual(delta(history).compact, "≈0%*")
        XCTAssertEqual(UsageActivity(consumption: delta(history)), .unknown)
        XCTAssertTrue(delta(history).detail.contains("未计入"))
        L10n.language = .english
        XCTAssertTrue(delta(history).detail.contains("excluded"))
    }

    func testCrossResetEstimateInterpolatesOnlyComparableBoundaryInterval() {
        var history = UsageHistory()
        history.append(sample(0, 10, interval: 300)); history.append(sample(5, 20, interval: 300))
        history.append(sample(6, 0, interval: 300, reset: 1_800_000_000))
        history.append(sample(10, 4, interval: 300, reset: 1_800_000_000))
        history.append(sample(12, 6, interval: 300, reset: 1_800_000_000))
        XCTAssertEqual(delta(history), .resetPartial(points: 12, coverage: 540))
    }

    func testResetDoesNotHideUnrelatedSamplingGap() {
        var history = UsageHistory()
        history.append(sample(0, 10)); history.append(sample(1, 12))
        history.append(sample(2, 0, reset: 1_800_000_000)); history.append(sample(3, 1, reset: 1_800_000_000))
        history.append(sample(9, 2, reset: 1_800_000_000))
        XCTAssertEqual(delta(history), .unavailable("采样中断，等待新数据"))
    }

    func testSleepGapUnavailableThenRecovers() {
        var history = UsageHistory()
        history.append(sample(0, 10)); history.append(sample(60, 40))
        XCTAssertEqual(delta(history), .unavailable("采样中断，等待新数据"))
        for i in 61...70 { history.append(sample(Double(i), 40)) }
        measured(delta(history), points: 0)
    }

    func testAccountChangeClearsHistory() {
        var history = UsageHistory()
        history.append(sample(0, 10)); history.append(sample(1, 99, account: "account-b"))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(delta(history), .unavailable("正在积累采样"))
    }

    func testMissingIdentityDisablesComparisons() {
        var history = UsageHistory()
        history.append(sample(0, 10, account: nil)); history.append(sample(1, 12, account: nil))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(delta(history), .unavailable("账户标识不可用"))
    }

    func testClockReversalClearsHistory() {
        var history = UsageHistory()
        history.append(sample(10, 10)); history.append(sample(0, 11))
        XCTAssertEqual(history.samples.count, 1)
    }

    func testMissingUsageIsNotZero() {
        var history = UsageHistory()
        history.append(sample(0, nil)); history.append(sample(1, 10))
        XCTAssertNil(history.samples[0].windows[0].window.remaining)
        XCTAssertEqual(delta(history), .unavailable("额度数据不完整"))
    }

    func testDurationChangeInvalidatesComparison() {
        var history = UsageHistory()
        history.append(sample(0, 10)); history.append(sample(1, 12, duration: 300))
        XCTAssertEqual(delta(history), .unavailable("额度数据不完整"))
    }

    func testChangingRefreshIntervalDoesNotCreateFalseGap() {
        var history = UsageHistory()
        history.append(sample(0, 10, interval: 60))
        history.append(sample(10, 12, interval: 600))
        measured(delta(history), points: 2)
    }

    func testRealResponseShapeWeekPrimaryAndSparkBucket() throws {
        let json = """
        {"accountId":"private-account", "rateLimits":{"limitId":"codex","primary":{"usedPercent":99}},
        "rateLimitsByLimitId":{
          "codex":{"primary":{"usedPercent":15,"windowDurationMins":10080,"resetsAt":1790000000},"secondary":null,"planType":"pro"},
          "spark":{"limitName":"Spark","primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":66,"windowDurationMins":10080}}
        }}
        """
        let response = try JSONDecoder().decode(RateResponse.self, from: Data(json.utf8))
        let snapshot = response.snapshot(interval: 60)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].window.label, "周额度")
        XCTAssertEqual(snapshot.windows[0].window.remaining, 85)
        XCTAssertEqual(snapshot.windows[1].window.label, "5 小时额度")
        XCTAssertEqual(snapshot.accountKey?.count, 64)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-account"))
    }

    func testLegacyFallbackAndNullFields() throws {
        let response = try JSONDecoder().decode(RateResponse.self, from: Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":null}}}".utf8))
        let snapshot = response.snapshot(interval: 60)
        XCTAssertEqual(snapshot.windows[0].id, "codex/primary")
        XCTAssertNil(snapshot.windows[0].window.remaining)
        XCTAssertNil(snapshot.accountKey)
    }

    func testHistoryPersistenceAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        var history = UsageHistory()
        history.append(sample(0, 10)); history.append(sample(1, 11))
        try LocalStore.save(history, to: url)
        let loaded = try LocalStore.read(UsageHistory.self, from: url)
        XCTAssertEqual(loaded.samples, history.samples)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testPreferenceValidation() {
        var preferences = Preferences()
        preferences.refreshMinutes = 0
        preferences.periods = [60, 10, 10, -1, 1440, 180]
        preferences.validate()
        XCTAssertEqual(preferences.refreshMinutes, 1)
        XCTAssertEqual(preferences.periods, [10, 60, 180])
    }
}
