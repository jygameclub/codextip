import Foundation

public enum IndicatorAnimation: String, Codable, CaseIterable {
    case none, breathe, bounce, sway, orbit

    public var label: String {
        switch self {
        case .none: return L10n.text("静止", "Still")
        case .breathe: return L10n.text("呼吸", "Breathe")
        case .bounce: return L10n.text("轻跳", "Bounce")
        case .sway: return L10n.text("摇摆", "Sway")
        case .orbit: return L10n.text("环绕", "Orbit")
        }
    }
}

/// Activity is based on the selected quota's ten-minute consumption, not successful polling.
public enum UsageActivity: Equatable {
    case active, idle, unknown

    public init(consumption: Consumption) {
        switch consumption {
        case let .measured(points, _, _) where points.isFinite: self = points > 0 ? .active : .idle
        case let .resetPartial(points, _) where points.isFinite && points > 0: self = .active
        // Zero in recorded intervals cannot establish idleness across an unknown reset.
        default: self = .unknown
        }
    }
    public var isActive: Bool { self == .active }
    public var label: String {
        switch self {
        case .active: return L10n.text("近 10 分钟有消耗", "Usage in the last 10 min")
        case .idle: return L10n.text("近 10 分钟无消耗", "No usage in the last 10 min")
        case .unknown: return L10n.text("近 10 分钟暂无可靠统计", "10 min usage unavailable")
        }
    }
}
