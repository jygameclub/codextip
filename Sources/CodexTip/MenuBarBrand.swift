import AppKit
import CodexTipCore

enum MenuBarBrand {
    private static let logo: NSImage? = {
        // Installed .app first, SwiftPM resource bundle for swift run / debug binaries.
        let url = Bundle.main.url(forResource: "codex-logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "codex-logo", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    static func label(hasData: Bool) -> String {
        hasData
            ? L10n.text("绿色 · 近 10 分钟有额度数据", "Green · Quota data received in the last 10 min")
            : L10n.text("蓝色 · 近 10 分钟无额度数据", "Blue · No quota data in the last 10 min")
    }

    static func color(hasData: Bool) -> NSColor { hasData ? .systemGreen : .systemBlue }

    static func image(hasData: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 30, height: 18), flipped: false) { rect in
            let logoRect = NSRect(x: 0, y: 0, width: 18, height: 18)
            if let logo {
                NSGraphicsContext.current?.imageInterpolation = .high
                logo.draw(in: logoRect)
            } else {
                // A missing asset still leaves an identifiable, usable menu-bar button.
                NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex")?.draw(in: logoRect)
            }
            color(hasData: hasData).setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: 6, width: 6, height: 6)).fill()
            return true
        }
        // A template would cause macOS to erase the requested green / blue colors.
        image.isTemplate = false
        image.accessibilityDescription = "Codex · " + label(hasData: hasData)
        return image
    }

    static func statusDot(hasData: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
            color(hasData: hasData).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Offscreen regression preview, using the same image renderer as the real status item.
func renderMenuPreview(to path: String) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let image = NSImage(size: NSSize(width: 420, height: 168), flipped: false) { bounds in
        for (index, variant) in [(false, true), (false, false), (true, true), (true, false)].enumerated() {
            let (dark, hasData) = variant
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let row = NSRect(x: 0, y: bounds.height - CGFloat(index + 1) * 42, width: bounds.width, height: 42)
                NSColor.windowBackgroundColor.setFill(); row.fill()
                MenuBarBrand.image(hasData: hasData).draw(in: NSRect(x: 12, y: row.minY + 12, width: 30, height: 18))
                let title = hasData ? L10n.text("周 84% (10m ≈1% · 1h ≈6%)", "wk 84% (10m ≈1% · 1h ≈6%)") : L10n.text("周 84% · 旧", "wk 84% · stale")
                (title as NSString).draw(at: NSPoint(x: 49, y: row.minY + 14), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
                ])
                let label = hasData ? L10n.text("有数据", "Data received") : L10n.text("无数据", "No recent data")
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
