import Foundation
import CryptoKit

public struct RateWindow: Codable, Equatable {
    public var usedPercent: Double?
    public var windowDurationMins: Int?
    public var resetsAt: Double?

    public init(usedPercent: Double?, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var remaining: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    public var label: String {
        guard let minutes = windowDurationMins else { return L10n.text("周期未知", "Unknown window") }
        if minutes == 10080 { return L10n.text("周额度", "Weekly quota") }
        if minutes % 1440 == 0 { return L10n.text("\(minutes / 1440) 天额度", "\(minutes / 1440)-day quota") }
        if minutes % 60 == 0 { return L10n.text("\(minutes / 60) 小时额度", "\(minutes / 60)-hour quota") }
        return L10n.text("\(minutes) 分钟额度", "\(minutes)-minute quota")
    }

    public var compactLabel: String {
        guard let minutes = windowDurationMins else { return "" }
        if minutes == 10080 { return L10n.text("周", "wk") }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

public struct RateBucket: Decodable {
    public var limitId: String?
    public var limitName: String?
    public var primary: RateWindow?
    public var secondary: RateWindow?
    public var planType: String?
}

public struct RateResponse: Decodable {
    public var rateLimits: RateBucket?
    public var rateLimitsByLimitId: [String: RateBucket]?
    public var accountId: String?

    public func snapshot(at date: Date = Date(), interval: TimeInterval) -> UsageSnapshot {
        // Persist only a one-way account identifier; never tokens, email or raw responses.
        let accountKey = accountId.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        var buckets = rateLimitsByLimitId ?? [:]
        if buckets.isEmpty, let legacy = rateLimits { buckets[legacy.limitId ?? "codex"] = legacy }
        var windows: [WindowSnapshot] = []
        for (id, bucket) in buckets {
            let name = bucket.limitName ?? (id == "codex" ? "Codex" : id)
            for (slot, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                if let window {
                    windows.append(WindowSnapshot(id: "\(id)/\(slot)", bucketID: id, name: name, plan: bucket.planType, window: window))
                }
            }
        }
        windows.sort {
            if $0.bucketID != $1.bucketID {
                if $0.bucketID == "codex" { return true }
                if $1.bucketID == "codex" { return false }
                return $0.bucketID < $1.bucketID
            }
            return $0.id < $1.id
        }
        return UsageSnapshot(date: date, interval: interval, accountKey: accountKey, windows: windows)
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public var id: String
    public var bucketID: String
    public var name: String
    public var plan: String?
    public var window: RateWindow
    public init(id: String, bucketID: String, name: String, plan: String?, window: RateWindow) {
        self.id = id; self.bucketID = bucketID; self.name = name; self.plan = plan; self.window = window
    }
}

public struct UsageSnapshot: Codable, Equatable {
    public var date: Date
    public var interval: TimeInterval
    public var accountKey: String?
    public var windows: [WindowSnapshot]
    public init(date: Date, interval: TimeInterval, accountKey: String?, windows: [WindowSnapshot]) {
        self.date = date; self.interval = interval; self.accountKey = accountKey; self.windows = windows
    }
}

public enum Consumption: Equatable {
    case measured(points: Double, coverage: TimeInterval, partial: Bool)
    case unavailable(String)

    /// Short menu-bar notation; approximation is explained in the dashboard/tooltip.
    public func menuLabel(minutes: Int) -> String {
        let amount: String
        switch self {
        case let .measured(points, _, partial): amount = "\(percent(points))%\(partial ? "*" : "")"
        case .unavailable: amount = "—"
        }
        return "\(Preferences.periodLabel(minutes))/\(amount)"
    }

    public var compact: String {
        switch self {
        case let .measured(points, _, partial): return "≈\(percent(points))%\(partial ? "*" : "")"
        case .unavailable: return "—"
        }
    }

    public var detail: String {
        switch self {
        case let .measured(_, coverage, partial):
            return partial ? L10n.text("已记录 \(max(1, Int(coverage / 60))) 分钟", "\(max(1, Int(coverage / 60))) min recorded") : L10n.text("采样估算", "Estimated from samples")
        case let .unavailable(reason): return reason
        }
    }
}

public func percent(_ value: Double) -> String {
    String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
}

public struct UsageHistory: Codable {
    public private(set) var samples: [UsageSnapshot] = []
    public init() {}
    public var latest: UsageSnapshot? { samples.last }

    /// Data presence is independent of consumption: a valid 0%-change sample counts.
    /// Use wall-clock time so an old successful sample cannot stay green indefinitely.
    public func hasRecentData(windowID: String, now: Date = Date()) -> Bool {
        guard let latest else { return false }
        return samples.reversed().contains { sample in
            let age = now.timeIntervalSince(sample.date)
            guard age >= 0, age <= 600, sample.accountKey == latest.accountKey,
                  let window = sample.windows.first(where: { $0.id == windowID }),
                  let used = window.window.usedPercent else { return false }
            return used.isFinite && (0...100).contains(used)
        }
    }

    public mutating func append(_ sample: UsageSnapshot) {
        // A changed/missing identity or clock reversal must never join two usage histories.
        if let previous = latest,
           previous.accountKey != sample.accountKey || sample.accountKey == nil || sample.date < previous.date {
            samples.removeAll()
        }
        if latest?.date == sample.date { samples.removeLast() }
        samples.append(sample)
        // Keep enough history for a 24h comparison plus a boundary sample.
        let cutoff = sample.date.addingTimeInterval(-48 * 3600)
        samples.removeAll { $0.date < cutoff }
        if samples.count > 10000 { samples.removeFirst(samples.count - 10000) }
    }

    public func consumption(windowID: String, seconds: TimeInterval) -> Consumption {
        guard let last = latest, last.accountKey != nil else { return .unavailable(L10n.text("账户标识不可用", "Account identity unavailable")) }
        guard samples.count >= 2 else { return .unavailable(L10n.text("正在积累采样", "Collecting samples")) }
        let target = last.date.addingTimeInterval(-seconds)
        let index = samples.lastIndex(where: { $0.date <= target }) ?? 0
        let slice = Array(samples[index...])
        guard slice.count >= 2 else { return .unavailable(L10n.text("正在积累采样", "Collecting samples")) }
        let partial = slice[0].date > target
        var baseline: Double?
        var endValue: Double?
        for pair in zip(slice, slice.dropFirst()) {
            let (a, b) = pair
            guard a.accountKey == last.accountKey, b.accountKey == last.accountKey,
                  let wa = a.windows.first(where: { $0.id == windowID })?.window,
                  let wb = b.windows.first(where: { $0.id == windowID })?.window,
                  let ua = wa.usedPercent, let ub = wb.usedPercent,
                  ua.isFinite, ub.isFinite, (0...100).contains(ua), (0...100).contains(ub),
                  let duration = wa.windowDurationMins, duration > 0,
                  wb.windowDurationMins == duration,
                  let ra = wa.resetsAt, let rb = wb.resetsAt else {
                return .unavailable(L10n.text("额度数据不完整", "Incomplete quota data"))
            }
            let gap = b.date.timeIntervalSince(a.date)
            guard gap > 0, gap <= max(a.interval, b.interval) * 1.8 + 30 else {
                return .unavailable(L10n.text("采样中断，等待新数据", "Sampling gap; waiting for new data"))
            }
            // Don't guess the unobserved consumption before a reset/correction.
            // Idle windows may shift their reset time before any usage starts.
            guard ub >= ua, (abs(ra - rb) <= 2 || (ua == 0 && ub == 0)),
                  !(ra > a.date.timeIntervalSince1970 && ra <= b.date.timeIntervalSince1970) else {
                return .unavailable(L10n.text("期间额度已重置或调整", "Quota reset or adjusted in this period"))
            }
            if baseline == nil {
                let fraction = max(0, min(1, target.timeIntervalSince(a.date) / gap))
                baseline = ua + (ub - ua) * fraction
            }
            endValue = ub
        }
        guard let baseline, let endValue else { return .unavailable(L10n.text("正在积累采样", "Collecting samples")) }
        let coverage = last.date.timeIntervalSince(max(target, slice[0].date))
        return .measured(points: max(0, endValue - baseline), coverage: coverage, partial: partial)
    }
}

public struct Preferences: Codable {
    public static let refreshOptions = [1, 2, 3, 5, 10]
    public static let periodOptions = [5, 10, 30, 60, 180, 360, 1440]
    public static let dotSizeOptions = [6, 8, 10, 12, 14]
    public static let emojiSizeOptions = [12, 14, 16, 18]
    public var refreshMinutes = 1
    public var periods = [10, 60]
    public var selectedWindowID = "codex/primary"
    public var compactMode = false
    public var executablePath: String? = nil
    // Optional so preferences written before language support still decode unchanged.
    public var language: AppLanguage? = nil
    public var dotSize: Int? = nil
    public var dataDotColor: IndicatorColor? = nil
    public var noDataDotColor: IndicatorColor? = nil
    public var indicatorAppearance: IndicatorAppearance? = nil
    public var emojiSize: Int? = nil
    public var dataEmoji: String? = nil
    public var noDataEmoji: String? = nil
    public var dataAnimation: IndicatorAnimation? = nil
    public var noDataAnimation: IndicatorAnimation? = nil
    public init() {}

    public func animation(hasData: Bool) -> IndicatorAnimation {
        (hasData ? dataAnimation : noDataAnimation) ?? .none
    }
    public var hasAnimation: Bool { animation(hasData: true) != .none || animation(hasData: false) != .none }

    public var effectiveIndicatorAppearance: IndicatorAppearance { indicatorAppearance ?? .dot }
    public var effectiveEmojiSize: Int {
        guard let emojiSize, Self.emojiSizeOptions.contains(emojiSize) else { return 16 }
        return emojiSize
    }
    public func emoji(hasData: Bool) -> String {
        StatusEmoji.normalized(hasData ? dataEmoji : noDataEmoji) ?? (hasData ? "🙂" : "😴")
    }

    public var effectiveDotSize: Int {
        guard let dotSize, Self.dotSizeOptions.contains(dotSize) else { return 10 }
        return dotSize
    }

    public func dotColor(hasData: Bool) -> IndicatorColor {
        hasData ? (dataDotColor ?? .green) : (noDataDotColor ?? .blue)
    }

    public mutating func validate() {
        if let emojiSize, !Self.emojiSizeOptions.contains(emojiSize) { self.emojiSize = nil }
        dataEmoji = StatusEmoji.normalized(dataEmoji)
        noDataEmoji = StatusEmoji.normalized(noDataEmoji)
        if let dotSize, !Self.dotSizeOptions.contains(dotSize) { self.dotSize = nil }
        if !Self.refreshOptions.contains(refreshMinutes) { refreshMinutes = 1 }
        periods = Array(Set(periods.filter { Self.periodOptions.contains($0) })).sorted()
        if periods.count > 3 { periods = Array(periods.prefix(3)) }
    }

    public static func periodLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }
}

public enum LocalStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexTip", isDirectory: true)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
