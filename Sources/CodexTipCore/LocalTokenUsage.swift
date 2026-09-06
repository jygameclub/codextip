import Foundation

/// Cached/reasoning counts are subsets of input/output, never additional totals.
public struct TokenCounts: Codable, Equatable, Hashable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var total: Int64 { input + output }
    public var uncached: Int64 { max(0, input - cached) }
    public init(input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = max(0, input); self.cached = min(max(0, cached), self.input)
        self.cacheWrite = min(max(0, cacheWrite), max(0, self.input - self.cached))
        self.output = max(0, output); self.reasoning = min(max(0, reasoning), self.output)
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
             output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning)
    }
    func subtracting(_ other: Self) -> Self {
        Self(input: input - other.input, cached: cached - other.cached, cacheWrite: cacheWrite - other.cacheWrite,
             output: output - other.output, reasoning: reasoning - other.reasoning)
    }
    static func parse(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any], object["input_tokens"] != nil || object["output_tokens"] != nil else { return nil }
        func count(_ key: String) -> Int64 {
            guard let number = object[key] as? NSNumber else { return 0 }
            let n = number.doubleValue
            // Reject non-finite, negative or implausibly large per-request counters.
            return n.isFinite && n >= 0 && n <= 1e15 ? Int64(n) : 0
        }
        return Self(input: count("input_tokens"), cached: count("cached_input_tokens"), cacheWrite: count("cache_write_input_tokens"),
                    output: count("output_tokens"), reasoning: count("reasoning_output_tokens"))
    }
}

public struct LocalTokenEvent: Codable, Hashable {
    public var date: Date
    public var model: String
    public var counts: TokenCounts
    // Filled from the hashed session identity after deduplication; old caches remain readable.
    public var pricingSession: String?
    // Signature from the original snapshot, useful for copied histories with rewritten timestamps.
    var cumulative: TokenCounts?
    public init(date: Date, model: String, counts: TokenCounts, cumulative: TokenCounts? = nil, pricingSession: String? = nil) {
        self.date = date; self.model = model; self.counts = counts; self.cumulative = cumulative; self.pricingSession = pricingSession
    }
}

public enum LocalTokenPeriod: Int, CaseIterable {
    case today = 1, week = 7, month = 30, all = 0
    public var label: String {
        switch self {
        case .today: return L10n.text("今天", "Today")
        case .week: return L10n.text("7 天", "7 days")
        case .month: return L10n.text("30 天", "30 days")
        case .all: return L10n.text("全部", "All")
        }
    }
}

public struct TokenTrendBucket {
    public let start: Date
    public let end: Date
    public var counts = TokenCounts()
    public var cost = TokenCostEstimate()
}

public struct LocalTokenSummary {
    public var counts = TokenCounts()
    public var events = 0
    public var cost = TokenCostEstimate()
    public var models: [(name: String, counts: TokenCounts, cost: TokenCostEstimate)] = []
    public var buckets: [TokenTrendBucket] = []
    public var hourly = false
    public var monthly = false
    public var cacheHitRate: Double? { counts.input > 0 ? Double(counts.cached) / Double(counts.input) * 100 : nil }
}

public struct LocalTokenReport {
    public var events: [LocalTokenEvent]
    public var scannedAt: Date
    public var fileCount: Int
    public var skippedFiles: Int
    public var malformedRecords: Int
    public var duplicates: Int
    public var sourceAvailable: Bool
    public var bytesRead: UInt64
    public var unresolvedForks: Int = 0
    public var firstDate: Date? { events.first?.date }
    public var lastDate: Date? { events.last?.date }

    public func summary(period: LocalTokenPeriod, now: Date = Date(), calendar: Calendar = .current) -> LocalTokenSummary {
        var result = LocalTokenSummary()
        let today = calendar.startOfDay(for: now)
        let start: Date
        let component: Calendar.Component
        switch period {
        case .today:
            start = today; component = .hour; result.hourly = true
        case .week, .month:
            start = calendar.date(byAdding: .day, value: -(period.rawValue - 1), to: today)!
            component = .day
        case .all:
            let first = min(firstDate ?? today, today)
            let days = calendar.dateComponents([.day], from: first, to: now).day ?? 0
            result.monthly = days > 60
            component = result.monthly ? .month : .day
            start = result.monthly ? calendar.dateInterval(of: .month, for: first)!.start : calendar.startOfDay(for: first)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        var cursor = start
        while cursor < end, result.buckets.count < 2400 {
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            result.buckets.append(TokenTrendBucket(start: cursor, end: next)); cursor = next
        }
        // GPT-5.4/5.5 use session-wide long-context pricing. Inspect retained history
        // outside the selected date range as well, keeping one model's session separate.
        struct SessionModel: Hashable { let session: String; let model: String }
        var longSessions = Set<SessionModel>()
        for event in events where event.date <= now && event.counts.input > 272_000 {
            if let session = event.pricingSession, TokenPricing.price(for: event.model)?.sessionLongContext == true {
                longSessions.insert(SessionModel(session: session, model: event.model))
            }
        }
        var models: [String: TokenCounts] = [:]
        var modelCosts: [String: TokenCostEstimate] = [:]
        var index = 0
        for event in events where event.date >= start && event.date <= now {
            let sessionIsLong = event.pricingSession.map { longSessions.contains(SessionModel(session: $0, model: event.model)) } ?? false
            let cost = TokenPricing.estimate(model: event.model, counts: event.counts, sessionIsLong: sessionIsLong)
            result.cost = result.cost + cost
            modelCosts[event.model, default: TokenCostEstimate()] = modelCosts[event.model, default: TokenCostEstimate()] + cost
            result.counts = result.counts + event.counts; result.events += 1
            models[event.model, default: TokenCounts()] = models[event.model, default: TokenCounts()] + event.counts
            while index + 1 < result.buckets.count && event.date >= result.buckets[index].end { index += 1 }
            if result.buckets.indices.contains(index), event.date >= result.buckets[index].start && event.date < result.buckets[index].end {
                result.buckets[index].counts = result.buckets[index].counts + event.counts
                result.buckets[index].cost = result.buckets[index].cost + cost
            }
        }
        result.models = models.map { (name: $0.key, counts: $0.value, cost: modelCosts[$0.key] ?? TokenCostEstimate()) }.sorted { $0.counts.total > $1.counts.total }
        return result
    }

    public static func demo(now: Date = Date()) -> Self {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let models = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"]
        var events: [LocalTokenEvent] = []
        for day in 0..<30 {
            for hour in [0, 6, 10, 13, 18, 21] {
                let date = calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: -day, to: today)!)!
                guard date <= now else { continue }
                let input = Int64(120000 + ((day * 137 + hour * 41) % 900) * 900)
                events.append(LocalTokenEvent(date: date, model: models[(day + hour) % 3], counts: TokenCounts(
                    input: input, cached: input * 3 / 4, output: input / 12, reasoning: input / 40)))
            }
        }
        return Self(events: events.sorted { $0.date < $1.date }, scannedAt: now, fileCount: 42, skippedFiles: 0,
                    malformedRecords: 0, duplicates: 12, sourceAvailable: true, bytesRead: 0)
    }
}

public func shortTokens(_ count: Int64) -> String {
    if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1e9) }
    if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1e6) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1e3) }
    return String(count)
}

public func exactTokens(_ count: Int64) -> String {
    count.formatted(.number.locale(L10n.locale))
}
