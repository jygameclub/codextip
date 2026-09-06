import AppKit
import XCTest
import CodexTipCore
@testable import CodexTip

final class StatusAnimatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    }
    override func tearDown() { L10n.language = .system; super.tearDown() }

    func testAnimationCacheSurvivesRefreshAndStopsForReduceMotionSleepAndStill() {
        var displayed: NSImage?
        let animator = StatusAnimator { displayed = $0 }
        defer { animator.stop() }
        var preferences = Preferences()
        preferences.indicatorAppearance = .emoji
        preferences.dataAnimation = .bounce; preferences.noDataAnimation = .breathe
        animator.configure(hasData: true, preferences: preferences, reduceMotion: false)
        XCTAssertTrue(animator.isRunning)
        XCTAssertEqual(animator.frames.count, 24)
        XCTAssertEqual(animator.frameInterval, 0.1)
        let frame = animator.frames[0]
        animator.configure(hasData: true, preferences: preferences, reduceMotion: false)
        XCTAssertTrue(frame === animator.frames[0], "Refresh must reuse the same cached frames")
        animator.advance(at: 0); XCTAssertTrue(displayed === animator.frames[0])
        animator.advance(at: 0.31); XCTAssertTrue(displayed === animator.frames[3])
        animator.configure(hasData: false, preferences: preferences, reduceMotion: false)
        XCTAssertEqual(animator.frameInterval, 0.2)
        XCTAssertFalse(frame === animator.frames[0])
        animator.configure(hasData: false, preferences: preferences, reduceMotion: true)
        XCTAssertFalse(animator.isRunning); XCTAssertEqual(animator.frames.count, 1)
        animator.configure(hasData: true, preferences: preferences, reduceMotion: false)
        XCTAssertTrue(animator.isRunning)
        animator.configure(hasData: true, preferences: preferences, reduceMotion: false, suspended: true)
        XCTAssertFalse(animator.isRunning); XCTAssertEqual(animator.frames.count, 1)
        preferences.dataAnimation = IndicatorAnimation.none
        animator.configure(hasData: true, preferences: preferences, reduceMotion: false)
        XCTAssertFalse(animator.isRunning)
    }

    func testAnimationTimerActuallyDeliversFrames() {
        let ticked = expectation(description: "Cached animation frames reach the status button callback")
        var deliveries = 0
        let animator = StatusAnimator { _ in
            deliveries += 1
            if deliveries == 3 { ticked.fulfill() }
        }
        defer { animator.stop() }
        var preferences = Preferences(); preferences.dataAnimation = .sway
        animator.configure(hasData: true, preferences: preferences, reduceMotion: false)
        wait(for: [ticked], timeout: 2)
        XCTAssertGreaterThanOrEqual(deliveries, 3)
    }

    func testEveryEffectAnimatesBothStylesWithoutMovingLogoOrChangingWidth() throws {
        for style in IndicatorAppearance.allCases {
            for effect in IndicatorAnimation.allCases where effect != .none {
                var preferences = Preferences()
                preferences.indicatorAppearance = style; preferences.emojiSize = 18; preferences.dotSize = 14
                preferences.dataAnimation = effect
                var bitmaps = Set<Data>()
                var logo: Data?
                for frame in 0..<24 {
                    let image = MenuBarBrand.rasterized(MenuBarBrand.image(hasData: true, preferences: preferences, phase: Double(frame) / 24))
                    XCTAssertEqual(image.size, NSSize(width: 46, height: 18))
                    let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
                    bitmaps.insert(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
                    var logoPixels = Data()
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<36 {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            logoPixels.append(contentsOf: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { UInt8(max(0, min(255, $0 * 255))) })
                        }
                    }
                    if let logo { XCTAssertEqual(logoPixels, logo) } else { logo = logoPixels }
                }
                XCTAssertGreaterThan(bitmaps.count, 8, "\(style) / \(effect) must visibly animate")
                XCTAssertEqual(MenuBarBrand.image(hasData: false, preferences: preferences).size, NSSize(width: 46, height: 18))
            }
        }
    }

    func testSettingsOffersIndependentAnimationChoicesInBothLanguages() throws {
        let app = AppController(); app.loadPreview()
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            let menu = app.makeSettingsMenu()
            let effects = menu.items.compactMap(\.submenu).filter { $0.items.map(\.representedObject).compactMap { $0 as? String } == IndicatorAnimation.allCases.map(\.rawValue) }
            XCTAssertEqual(effects.count, 2)
            for (index, submenu) in effects.enumerated() {
                XCTAssertEqual(submenu.items.map(\.title), IndicatorAnimation.allCases.map(\.label))
                XCTAssertEqual(submenu.items.first?.state, .on)
                for option in submenu.items {
                    XCTAssertEqual(option.tag, index == 0 ? 1 : 0)
                    XCTAssertNotNil(option.action); XCTAssertTrue(option.target === app)
                }
            }
            XCTAssertNotEqual(MenuBarBrand.label(activity: .unknown, preferences: Preferences()),
                              MenuBarBrand.label(activity: .idle, preferences: Preferences()))
        }
    }
}
