import XCTest
@testable import CodexTipCore

final class LocalTokenTests: XCTestCase {
    private var root: URL!
    private let origin = Date(timeIntervalSince1970: 1_780_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func record(_ type: String, _ payload: [String: Any], at time: Double = 0) throws -> Data {
        let object: [String: Any] = ["type": type, "timestamp": origin.addingTimeInterval(time).timeIntervalSince1970, "payload": payload]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
    }
    private func meta(_ id: String, parent: String? = nil, boundary: Int? = nil, at time: Double = 0) throws -> Data {
        var payload: [String: Any] = ["id": id, "timestamp": origin.addingTimeInterval(time).timeIntervalSince1970]
        if let parent { payload["forked_from_id"] = parent }
        if let boundary { payload["subagent_history_start_ordinal"] = boundary }
        return try record("session_meta", payload, at: time)
    }
    private func count(_ input: Int, _ output: Int = 10, cached: Int = 0, reasoning: Int = 0) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached, "reasoning_output_tokens": reasoning]
    }
    private func usage(_ total: [String: Any]?, last: [String: Any]? = nil, at time: Double = 1) throws -> Data {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = total }
        if let last { info["last_token_usage"] = last }
        return try record("event_msg", ["type": "token_count", "info": info], at: time)
    }
    @discardableResult private func write(_ data: Data, _ name: String = "sessions/a.jsonl") throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    private func indexer(cache: Bool = false) -> LocalTokenIndexer {
        LocalTokenIndexer(root: root, cacheURL: cache ? root.appendingPathComponent("index.json") : nil)
    }

    func testLastUsageCumulativeFallbackAndSubsets() throws {
        var data = try meta("main") + record("turn_context", ["model": "test-model"])
        data += try usage(count(100, 20, cached: 80, reasoning: 5), last: count(100, 20, cached: 80, reasoning: 5))
        data += try usage(count(100, 20, cached: 80, reasoning: 5), last: count(100, 20, cached: 80, reasoning: 5), at: 2)
        data += try usage(count(150, 30, cached: 110, reasoning: 7), at: 3)
        // After compaction the last request can differ from the cumulative delta.
        data += try usage(count(160, 35, cached: 115, reasoning: 8), last: count(40, 8, cached: 20, reasoning: 2), at: 4)
        try write(data)
        let report = try indexer().scan()
        let total = report.summary(period: .all).counts
        XCTAssertEqual(report.events.count, 3)
        XCTAssertEqual(total, TokenCounts(input: 190, cached: 130, output: 38, reasoning: 9))
        XCTAssertEqual(total.total, 228)
        XCTAssertEqual(report.events.map(\.model), Array(repeating: "test-model", count: 3))
    }

    func testIncrementalCachePartialTailAndPrivacy() throws {
        let data = try meta("secret-session-id") + record("turn_context", ["model": "m", "cwd": "/secret/project"])
            + record("response_item", ["type": "message", "content": "PRIVATE CONVERSATION"])
            + usage(count(100))
        let url = try write(data)
        let scanner = indexer(cache: true)
        XCTAssertEqual(try scanner.scan().events.count, 1)
        XCTAssertEqual(try scanner.scan().bytesRead, 0)
        let new = try usage(count(180, 18), at: 2)
        let midpoint = new.count / 2
        try append(new.prefix(midpoint), to: url)
        XCTAssertEqual(try scanner.scan().events.count, 1)
        try append(new.dropFirst(midpoint), to: url)
        let refreshed = try scanner.scan()
        XCTAssertEqual(refreshed.events.count, 2)
        XCTAssertEqual(refreshed.summary(period: .all).counts.total, 198)
        XCTAssertLessThan(refreshed.bytesRead, UInt64(data.count + new.count))
        let loaded = try indexer(cache: true).scan()
        XCTAssertEqual(loaded.events, refreshed.events)
        XCTAssertEqual(loaded.bytesRead, 0)
        let stored = try String(contentsOf: root.appendingPathComponent("index.json"))
        for secret in ["secret-session-id", "/secret/project", "PRIVATE CONVERSATION", root.path] { XCTAssertFalse(stored.contains(secret)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("index.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testTruncatedReplacedAndRemovedLogs() throws {
        let original = try meta("a") + usage(count(100)) + usage(count(200), at: 2)
        let url = try write(original)
        let scanner = indexer()
        XCTAssertEqual(try scanner.scan().events.count, 2)
        try write(try meta("a") + usage(count(300)))
        XCTAssertEqual(try scanner.scan().summary(period: .all).counts.input, 300)
        // Same-size rewrite must invalidate the old cache too.
        try write(try meta("a") + usage(count(900)))
        XCTAssertEqual(try scanner.scan().summary(period: .all).counts.input, 900)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(try scanner.scan().events.isEmpty)
    }

    func testArchiveCopiesAndIndependentSessions() throws {
        let data = try meta("a") + usage(count(100))
        try write(data)
        try write(data, "archived_sessions/copy.jsonl")
        try write(try meta("b") + usage(count(200), at: 2), "sessions/b.jsonl")
        let report = try indexer().scan()
        XCTAssertEqual(report.fileCount, 3)
        XCTAssertEqual(report.events.count, 2)
        XCTAssertEqual(report.summary(period: .all).counts.input, 300)
    }

    func testSubagentHistoryBoundaryKeepsCumulativeBaseline() throws {
        try write(try meta("parent") + usage(count(100)), "sessions/parent.jsonl")
        // Ordinals: metadata 0, inherited usage 1, own usage 2.
        try write(try meta("child", parent: "parent", boundary: 2) + usage(count(100)) + usage(count(140, 14), at: 2))
        let report = try indexer().scan()
        XCTAssertEqual(report.events.count, 2)
        XCTAssertEqual(report.summary(period: .all).counts.total, 154)
        XCTAssertEqual(report.duplicates, 1)
    }

    func testLegacyForkRewrittenTimestampsDeduplicated() throws {
        try write(try meta("parent") + usage(count(100), at: 1) + usage(count(150, 15), at: 2), "sessions/parent.jsonl")
        try write(try meta("child", parent: "parent", at: 10)
                  + usage(count(100), at: 10) + usage(count(150, 15), at: 11) + usage(count(170, 17), at: 12))
        let report = try indexer().scan()
        XCTAssertEqual(report.summary(period: .all).counts.total, 187)
        XCTAssertEqual(report.events.count, 3)
        XCTAssertEqual(report.duplicates, 2)
    }

    func testModelSwitchUnknownAndMalformedRecords() throws {
        var data = try usage(count(100))
        data += Data("{\"type\":\"event_msg\",broken}\n".utf8)
        data += try record("turn_context", ["model": "next"])
        data += try usage(count(200, 20), at: 2)
        try write(data)
        let report = try indexer().scan()
        XCTAssertEqual(report.events.map(\.model), ["unknown", "next"])
        XCTAssertEqual(report.malformedRecords, 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("archived_sessions"))
        XCTAssertFalse(try indexer().scan().sourceAvailable)
    }

    func testMissingLegacyParentIsReportedAsUncertain() throws {
        try write(try meta("child", parent: "missing") + usage(count(100)))
        XCTAssertEqual(try indexer().scan().unresolvedForks, 1)
        try write(try meta("child", parent: "missing", boundary: 1) + usage(count(100)))
        XCTAssertEqual(try indexer().scan().unresolvedForks, 0)
    }

    func testOversizedToolOutputAcrossChunksPreservesNextUsageAndOrdinal() throws {
        var data = try meta("child", parent: "parent", boundary: 2)
        data += Data("{\"type\":\"response_item\",\"payload\":{\"output\":\"".utf8)
        data += Data(repeating: 65, count: 17 * 1024 * 1024)
        data += Data("\"}}\n".utf8)
        data += try usage(count(100))
        let url = try write(data)
        let scanner = indexer()
        let report = try scanner.scan()
        XCTAssertEqual(report.events.count, 1)
        XCTAssertEqual(report.events[0].counts.total, 110)
        XCTAssertEqual(try scanner.scan().bytesRead, 0)
        try append(try usage(count(140, 14), at: 2), to: url)
        XCTAssertEqual(try scanner.scan().summary(period: .all).counts.total, 154)
    }

    func testLocalCalendarBoundariesAndBucketTotals() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z")!
        let today = calendar.startOfDay(for: now)
        let dates = [-31, -29, -7, -6, -1, 0].map { calendar.date(byAdding: .day, value: $0, to: today)! }
        let events = dates.map { LocalTokenEvent(date: $0, model: "m", counts: TokenCounts(input: 100, output: 10)) }
        let report = LocalTokenReport(events: events, scannedAt: now, fileCount: 1, skippedFiles: 0, malformedRecords: 0, duplicates: 0, sourceAvailable: true, bytesRead: 0)
        for (period, expected, buckets) in [(LocalTokenPeriod.today, 1, 24), (.week, 3, 7), (.month, 5, 30), (.all, 6, 32)] {
            let summary = report.summary(period: period, now: now, calendar: calendar)
            XCTAssertEqual(summary.events, expected)
            XCTAssertEqual(summary.buckets.count, buckets)
            XCTAssertEqual(summary.buckets.reduce(Int64(0)) { $0 + $1.counts.total }, Int64(expected * 110))
        }
        XCTAssertEqual(report.summary(period: .today, now: now, calendar: calendar).buckets.first?.start, today)
    }

    func testDaylightSavingAndLongHistory() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2026-03-08T20:00:00Z")!
        let first = calendar.date(byAdding: .month, value: -4, to: now)!
        let report = LocalTokenReport(events: [LocalTokenEvent(date: first, model: "m", counts: TokenCounts(input: 50))], scannedAt: now, fileCount: 1, skippedFiles: 0, malformedRecords: 0, duplicates: 0, sourceAvailable: true, bytesRead: 0)
        XCTAssertEqual(report.summary(period: .today, now: now, calendar: calendar).buckets.count, 23)
        let summary = report.summary(period: .all, now: now, calendar: calendar)
        XCTAssertTrue(summary.monthly)
        XCTAssertEqual(summary.buckets.count, 5)
        XCTAssertEqual(summary.buckets.first?.counts.total, 50)
    }
}
