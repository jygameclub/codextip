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
