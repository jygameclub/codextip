import XCTest
@testable import CodexTipCore

final class TokenPricingTests: XCTestCase {
    func testCacheReadsWritesAndReasoningAreNotDoubleCharged() {
        let counts = TokenCounts(input: 200_000, cached: 120_000, cacheWrite: 40_000, output: 10_000, reasoning: 8_000)
        let cost = TokenPricing.estimate(model: "gpt-6-astra", counts: counts)
        XCTAssertEqual(cost.inputUSD, 0.4, accuracy: 1e-10)
        XCTAssertEqual(cost.cachedUSD, 0.12, accuracy: 1e-10)
        XCTAssertEqual(cost.cacheWriteUSD, 0.5, accuracy: 1e-10)
        XCTAssertEqual(cost.outputUSD, 0.5, accuracy: 1e-10)
        XCTAssertEqual(cost.knownUSD, 1.52, accuracy: 1e-10)
        XCTAssertEqual(cost.pricedTokens, 210_000)
        XCTAssertFalse(cost.isPartial)
    }

    func testLongContextThresholdAndAllInputCategories() {
        let short = TokenPricing.estimate(model: "gpt-6-astra", counts: TokenCounts(input: 272_000, output: 10_000))
        let long = TokenPricing.estimate(model: "gpt-6-astra", counts: TokenCounts(input: 272_001, output: 10_000))
        XCTAssertEqual(short.knownUSD, 3.22, accuracy: 1e-10)
        XCTAssertEqual(long.knownUSD, 6.19002, accuracy: 1e-10)
        let mixed = TokenPricing.estimate(model: "gpt-6-astra", counts: TokenCounts(input: 273_000, cached: 100_000, cacheWrite: 50_000, output: 10_000))
        XCTAssertEqual(mixed.knownUSD, 4.66, accuracy: 1e-10)
    }

    func testUnknownModelsAndUnknownCacheWriteRateAreExcluded() {
        for model in ["gpt-5.3-codex-spark", "gpt-6-astra-pro", "unknown", "gpt-5.6-sol-custom"] {
            let cost = TokenPricing.estimate(model: model, counts: TokenCounts(input: 100))
            XCTAssertEqual(cost.pricedTokens, 0)
            XCTAssertEqual(cost.unpricedTokens, 100)
            XCTAssertEqual(cost.unpricedModels, [model])
            XCTAssertTrue(cost.isPartial)
        }
        let missingWrite = TokenPricing.estimate(model: "gpt-5.5", counts: TokenCounts(input: 100, cacheWrite: 50))
        XCTAssertEqual(missingWrite.unpricedTokens, 100)
        XCTAssertEqual(missingWrite.knownUSD, 0)
    }

    func testKnownAliasesAndRates() {
        let counts = TokenCounts(input: 100_000, cached: 80_000, cacheWrite: 10_000, output: 20_000)
        let sol = TokenPricing.estimate(model: "gpt-5.6-sol", counts: counts)
        XCTAssertEqual(sol.knownUSD, 0.522, accuracy: 1e-10)
        XCTAssertEqual(sol.knownUSD, TokenPricing.estimate(model: "gpt-5.6", counts: counts).knownUSD)
        XCTAssertEqual(TokenPricing.estimate(model: "gpt-5.4-mini", counts: TokenCounts(input: 1_000_000)).knownUSD, 0.75)
        XCTAssertEqual(TokenPricing.estimate(model: "gpt-5.3-codex", counts: TokenCounts(input: 1_000_000)).knownUSD, 1.75)
    }

    func testSessionLongContextIncludesHistoryOutsideSelectedPeriod() {
        let now = Date(timeIntervalSince1970: 1_788_680_000)
        let old = now.addingTimeInterval(-10 * 86400)
        let events = [
            LocalTokenEvent(date: old, model: "gpt-5.4", counts: TokenCounts(input: 300_000), pricingSession: "a"),
            LocalTokenEvent(date: now, model: "gpt-5.4", counts: TokenCounts(input: 100_000), pricingSession: "a"),
            LocalTokenEvent(date: now, model: "gpt-5.4", counts: TokenCounts(input: 100_000), pricingSession: "b"),
            LocalTokenEvent(date: now, model: "gpt-6-astra", counts: TokenCounts(input: 100_000), pricingSession: "a")
        ]
        let report = LocalTokenReport(events: events, scannedAt: now, fileCount: 2, skippedFiles: 0, malformedRecords: 0, duplicates: 0, sourceAvailable: true, bytesRead: 0)
        let summary = report.summary(period: .week, now: now)
        XCTAssertEqual(summary.cost.knownUSD, 0.5 + 0.25 + 1, accuracy: 1e-10)
        XCTAssertEqual(summary.buckets.reduce(0.0) { $0 + $1.cost.knownUSD }, summary.cost.knownUSD, accuracy: 1e-10)
        XCTAssertEqual(summary.models.reduce(0.0) { $0 + $1.cost.knownUSD }, summary.cost.knownUSD, accuracy: 1e-10)
    }

    func testMixedCoverageAndLocalizedLabels() {
        let known = TokenPricing.estimate(model: "gpt-5.6-sol", counts: TokenCounts(input: 100_000))
        let unknown = TokenPricing.estimate(model: "gpt-5.3-codex-spark", counts: TokenCounts(input: 200_000))
        let mixed = known + unknown
        XCTAssertEqual(mixed.pricedTokens, 100_000)
        XCTAssertEqual(mixed.unpricedTokens, 200_000)
        XCTAssertEqual(mixed.knownUSD, 0.4, accuracy: 1e-10)
        defer { L10n.language = .system }
        L10n.language = .chinese
        XCTAssertEqual(mixed.display, "已知部分 ≈$0.40")
        XCTAssertEqual(unknown.display, "价格未知")
        L10n.language = .english
        XCTAssertEqual(mixed.display, "Known part ≈$0.40")
        XCTAssertEqual(unknown.display, "Price unknown")
        XCTAssertEqual(TokenCostEstimate().display, "≈$0.00")
        XCTAssertEqual(usd(0.00001), "<$0.01")
    }

    func testOldEventsDecodeWithoutPricingMetadata() throws {
        let event = LocalTokenEvent(date: Date(), model: "gpt-5.6-sol", counts: TokenCounts(input: 100))
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("pricingSession"))
        let decoded = try JSONDecoder().decode(LocalTokenEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertNil(decoded.pricingSession)
    }
}
