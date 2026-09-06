import Foundation

public enum AppLanguage: String, Codable, CaseIterable {
    case system, chinese, english

    public var menuLabel: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    public func usesChinese(preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        switch self {
        case .chinese: return true
        case .english: return false
        case .system: return preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

/// UI language is changed on the main thread. Background quota decoding does not use UI strings.
public enum L10n {
    public static var language: AppLanguage = .system
    public static var locale: Locale { Locale(identifier: language.usesChinese() ? "zh_CN" : "en_US") }

    public static func text(_ chinese: String, _ english: String) -> String {
        language.usesChinese() ? chinese : english
    }

    public static func period(_ minutes: Int) -> String {
        if minutes < 60 { return text("最近 \(minutes) 分钟", "Last \(minutes) min") }
        return text("最近 \(minutes / 60) 小时", "Last \(minutes / 60) \(minutes == 60 ? "hour" : "hours")")
    }

    public static func date(_ date: Date, includeDay: Bool = false) -> String {
        if includeDay { return date.formatted(.dateTime.month().day().hour().minute().locale(locale)) }
        return date.formatted(.dateTime.hour().minute().second().locale(locale))
    }
}
