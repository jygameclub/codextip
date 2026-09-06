import AppKit
import CodexTipCore

extension MenuBarBrand {
    /// Fixed canvas across every phase and both states: quota text never moves.
    /// A nil phase renders a still marker, including when Reduce Motion is enabled.
    static func animatedIndicator(hasData: Bool, preferences: Preferences, phase: Double?) -> NSImage {
        let marker = statusIndicator(hasData: hasData, preferences: preferences)
        guard preferences.hasAnimation else { return marker }
        let effect = preferences.animation(hasData: hasData)
        let angle = (phase ?? 0) * 2 * Double.pi
        return NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var scale = 1.0, opacity = 1.0, x = 0.0, y = 0.0, rotation = 0.0
            if phase != nil {
                switch effect {
                case .none: break
                case .breathe:
                    let wave = (1 - cos(angle)) / 2
                    scale = 0.74 + 0.26 * wave; opacity = 0.65 + 0.35 * wave
                case .bounce:
                    scale = 0.80; y = 1.6 * sin(angle)
                case .sway:
                    scale = 0.80; x = 1.5 * sin(angle); rotation = 0.18 * sin(angle)
                case .orbit:
                    scale = 0.66
                }
            }
            context.saveGState()
            context.translateBy(x: 11 + x, y: 9 + y)
            context.rotate(by: rotation)
            context.scaleBy(x: scale, y: scale)
            marker.draw(in: NSRect(x: -marker.size.width / 2, y: -marker.size.height / 2,
                                   width: marker.size.width, height: marker.size.height),
                        from: .zero, operation: .sourceOver, fraction: opacity)
            context.restoreGState()
            if phase != nil && effect == .orbit {
                color(hasData: hasData, preferences: preferences).setFill()
                let bead = NSRect(x: 11 + 7.6 * cos(angle) - 1, y: 9 + 7.6 * sin(angle) - 1, width: 2, height: 2)
                NSBezierPath(ovalIn: bead).fill()
            }
            return true
        }
    }

    /// Eager 2x rasterization keeps font and drawing work out of animation ticks.
    static func rasterized(_ source: NSImage) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(source.size.width * 2),
                                      pixelsHigh: Int(source.size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = source.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // bitmap.size supplies the 2x backing scale to AppKit.
        source.draw(in: NSRect(origin: .zero, size: source.size))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: source.size)
        result.addRepresentation(bitmap)
        result.accessibilityDescription = source.accessibilityDescription
        return result
    }
}

/// Only swaps cached images. It never polls quota, reads logs, or rebuilds the dashboard.
final class StatusAnimator {
    private struct Key: Equatable {
        let preferences: Data
        let hasData: Bool
        let still: Bool
        let appearance: NSAppearance.Name
        let language: AppLanguage
    }
    private var key: Key?
    private var timer: Timer?
    private(set) var frames: [NSImage] = []
    private(set) var frameInterval: TimeInterval = 0.1
    var isRunning: Bool { timer?.isValid == true }
    private let display: (NSImage) -> Void
    init(display: @escaping (NSImage) -> Void) { self.display = display }
    deinit { timer?.invalidate() }

    func configure(hasData: Bool, preferences: Preferences, reduceMotion: Bool, suspended: Bool = false) {
        let appearance = NSApp.effectiveAppearance
        let still = reduceMotion || suspended || preferences.animation(hasData: hasData) == .none
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let newKey = Key(preferences: (try? encoder.encode(preferences)) ?? Data(), hasData: hasData,
                         still: still, appearance: appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua,
                         language: L10n.language)
        if newKey != key {
            stop()
            key = newKey
            frameInterval = hasData ? 0.1 : 0.2
            appearance.performAsCurrentDrawingAppearance {
                frames = (0..<(still ? 1 : 24)).map { index in
                    MenuBarBrand.rasterized(MenuBarBrand.image(hasData: hasData, preferences: preferences,
                                                               phase: still ? nil : Double(index) / 24))
                }
            }
        }
        advance(at: ProcessInfo.processInfo.systemUptime)
        if !still && !isRunning {
            let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
                self?.advance(at: ProcessInfo.processInfo.systemUptime)
            }
            timer.tolerance = frameInterval * 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func advance(at uptime: TimeInterval) {
        guard !frames.isEmpty else { return }
        let index = Int((max(0, uptime) / frameInterval).truncatingRemainder(dividingBy: Double(frames.count)))
        display(frames[index])
    }

    func stop() { timer?.invalidate(); timer = nil }
}
