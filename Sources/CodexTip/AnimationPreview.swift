import AppKit
import ImageIO
import CodexTipCore

/// Uses real menu-bar frames with demonstration values. Never opens a window.
func renderAnimationPreview(to path: String) throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let destinationURL = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "com.compuserve.gif" as CFString, 48, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<48 {
        try autoreleasepool {
            let image = NSImage(size: NSSize(width: 460, height: 616), flipped: false) { bounds in
                NSColor.white.setFill(); bounds.fill()
                for (title, x) in [(L10n.text("效果", "Effect"), 14.0),
                                   (L10n.text("有消耗 · 10m > 0", "Active · 10m > 0"), 154.0),
                                   (L10n.text("无消耗 · 10m = 0", "Idle · 10m = 0"), 314.0)] {
                    (title as NSString).draw(at: NSPoint(x: x, y: 592), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
                }
                var rowIndex = 0
                for dark in [false, true] {
                    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                    appearance.performAsCurrentDrawingAppearance {
                        for style in IndicatorAppearance.allCases {
                            for effect in IndicatorAnimation.allCases where effect != .none {
                                let row = NSRect(x: 0, y: 580 - CGFloat(rowIndex + 1) * 34, width: bounds.width, height: 34)
                                NSColor.windowBackgroundColor.setFill(); row.fill()
                                ((effect.label + " · " + style.label) as NSString).draw(at: NSPoint(x: 14, y: row.minY + 10), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                                for active in [true, false] {
                                    var preferences = Preferences()
                                    preferences.indicatorAppearance = style
                                    preferences.dataAnimation = effect; preferences.noDataAnimation = effect
                                    let phase = Double(frame % (active ? 24 : 48)) / (active ? 24 : 48)
                                    let icon = MenuBarBrand.image(hasData: active, preferences: preferences, phase: phase)
                                    let x: CGFloat = active ? 154 : 314
                                    icon.draw(in: NSRect(x: x, y: row.minY + 8, width: icon.size.width, height: 18))
                                    ((active ? "10m/1%" : "10m/0%") as NSString).draw(at: NSPoint(x: x + 52, y: row.minY + 10), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
                                }
                                rowIndex += 1
                            }
                        }
                    }
                }
                (L10n.text("演示数据 · 圆点与表情均支持 · 系统减少动态效果时静止", "Demo data · Dot and emoji support · Respects Reduce Motion") as NSString).draw(at: NSPoint(x: 14, y: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
                return true
            }
            let raster = MenuBarBrand.rasterized(image)
            guard let bitmap = raster.representations.first as? NSBitmapImageRep, let cgImage = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            if frame == 6, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: destinationURL.deletingPathExtension().appendingPathExtension("png"))
            }
        }
    }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
