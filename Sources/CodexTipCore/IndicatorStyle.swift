import Foundation

public enum IndicatorColor: String, Codable, CaseIterable {
    case green, blue, cyan, orange, purple, red, pink, yellow

    public var label: String {
        switch self {
        case .green: return L10n.text("绿色", "Green")
        case .blue: return L10n.text("蓝色", "Blue")
        case .cyan: return L10n.text("青色", "Cyan")
        case .orange: return L10n.text("橙色", "Orange")
        case .purple: return L10n.text("紫色", "Purple")
        case .red: return L10n.text("红色", "Red")
        case .pink: return L10n.text("粉色", "Pink")
        case .yellow: return L10n.text("黄色", "Yellow")
        }
    }
}

public enum IndicatorAppearance: String, Codable, CaseIterable {
    case dot, emoji
    public var label: String { self == .dot ? L10n.text("圆点", "Dot") : L10n.text("表情", "Emoji") }
}

public enum StatusEmoji {
    public static let presets = ["🙂", "😴", "🟢", "🔵", "⚡️", "💤", "✅", "⏳", "🚀", "🌙", "🤖", "☕️"]
    /// One complete grapheme, including flags, skin tones, keycaps and ZWJ families.
    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, trimmed.utf8.count <= 128 else { return nil }
        let scalars = trimmed.unicodeScalars
        guard scalars.contains(where: { $0.properties.isEmoji && !$0.properties.isEmojiModifier && $0.value > 127 })
            || (scalars.contains(where: { $0.value == 0x20E3 }) && scalars.contains(where: { $0.properties.isEmoji })) else { return nil }
        return trimmed
    }
}
