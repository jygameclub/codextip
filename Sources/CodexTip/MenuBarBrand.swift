import AppKit
import CodexTipCore

enum MenuBarBrand {
    private static let logo: NSImage? = {
        // Installed .app first, SwiftPM resource bundle for swift run / debug binaries.
        let url = Bundle.main.url(forResource: "codex-logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "codex-logo", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    static func label(hasData: Bool, preferences: Preferences = Preferences()) -> String {
        let status = hasData
            ? L10n.text("近 10 分钟有额度数据", "Quota data received in the last 10 min")
            : L10n.text("近 10 分钟无额度数据", "No quota data in the last 10 min")
        return preferences.dotColor(hasData: hasData).label + " · " + status
    }

    static func color(hasData: Bool, preferences: Preferences) -> NSColor {
        switch preferences.dotColor(hasData: hasData) {
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .cyan: return .systemCyan
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .red: return .systemRed
        case .pink: return .systemPink
        case .yellow: return .systemYellow
        }
    }

    static func image(hasData: Bool, preferences: Preferences = Preferences()) -> NSImage {
        let diameter = CGFloat(preferences.effectiveDotSize)
        let image = NSImage(size: NSSize(width: 24 + diameter, height: 18), flipped: false) { rect in
            let logoRect = NSRect(x: 0, y: 0, width: 18, height: 18)
            if let logo {
                NSGraphicsContext.current?.imageInterpolation = .high
                logo.draw(in: logoRect)
            } else {
                // A missing asset still leaves an identifiable, usable menu-bar button.
                NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex")?.draw(in: logoRect)
            }
            color(hasData: hasData, preferences: preferences).setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: (18 - diameter) / 2, width: diameter, height: diameter)).fill()
            return true
        }
        // A template would cause macOS to erase the requested green / blue colors.
        image.isTemplate = false
        image.accessibilityDescription = "Codex · " + label(hasData: hasData, preferences: preferences)
        return image
    }

    static func statusDot(hasData: Bool, preferences: Preferences = Preferences()) -> NSImage {
        let diameter = CGFloat(preferences.effectiveDotSize)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { bounds in
            color(hasData: hasData, preferences: preferences).setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Offscreen regression preview, using the same image renderer as the real status item.
func renderMenuPreview(to path: String, dotOptions: Bool = false) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let variants: [(Bool, Bool, Int, IndicatorColor?)] = dotOptions
        ? [(false, true, 6, nil), (false, true, 10, nil), (false, true, 14, nil),
           (true, false, 6, nil), (true, false, 10, nil), (true, false, 14, nil),
           (false, true, 14, .purple), (true, false, 14, .orange)]
        : [(false, true, 10, nil), (false, false, 10, nil), (true, true, 10, nil), (true, false, 10, nil)]
    let image = NSImage(size: NSSize(width: 420, height: variants.count * 42), flipped: false) { bounds in
        for (index, variant) in variants.enumerated() {
            let (dark, hasData, diameter, customColor) = variant
            var preferences = Preferences()
            preferences.dotSize = diameter
            if hasData { preferences.dataDotColor = customColor }
            else { preferences.noDataDotColor = customColor }
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let row = NSRect(x: 0, y: bounds.height - CGFloat(index + 1) * 42, width: bounds.width, height: 42)
                NSColor.windowBackgroundColor.setFill(); row.fill()
                let icon = MenuBarBrand.image(hasData: hasData, preferences: preferences)
                icon.draw(in: NSRect(x: 12, y: row.minY + 12, width: icon.size.width, height: 18))
                let title = hasData ? L10n.text("周 84% (10m/1% · 1h/6%)", "wk 84% (10m/1% · 1h/6%)") : L10n.text("周 84% · 旧", "wk 84% · stale")
                (title as NSString).draw(at: NSPoint(x: 12 + icon.size.width + 7, y: row.minY + 14), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
                ])
                let label = dotOptions ? "\(diameter) pt · " + preferences.dotColor(hasData: hasData).label : hasData ? L10n.text("有数据", "Data received") : L10n.text("无数据", "No recent data")
                (label as NSString).draw(at: NSPoint(x: 330, y: row.minY + 14), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor
                ])
            }
        }
        return true
    }
    guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: URL(fileURLWithPath: path))
}
