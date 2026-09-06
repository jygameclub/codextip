import AppKit
import XCTest
import CodexTipCore
@testable import CodexTip

final class DashboardInteractionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        L10n.language = .english
    }
    override func tearDown() { L10n.language = .system; super.tearDown() }

    private func controls<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { controls($0, of: type) }
    }
    private func select(_ index: Int, in control: NSSegmentedControl) {
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
    }

    func testPopoverSizeFollowsTabHeight() throws {
        let app = AppController(); app.loadPreview()
        let dashboard = DashboardController(app: app)
        _ = dashboard.view
        let popover = NSPopover()
        dashboard.attach(to: popover)
        let tabs = try XCTUnwrap(controls(dashboard.view, of: NSSegmentedControl.self).first { $0.segmentCount == 2 })
        let initial = popover.contentSize
        select(1, in: tabs)
        XCTAssertTrue(dashboard.showsLocalTokens)
        XCTAssertNotEqual(dashboard.preferredContentSize, initial)
        XCTAssertEqual(popover.contentSize, dashboard.preferredContentSize, "The popup must grow with its view so the tabs remain within the clickable window")
    }

    func testRepeatedTabAndPeriodSwitchesKeepHeaderReachableAfterRefresh() throws {
        let app = AppController(); app.loadPreview()
        let dashboard = DashboardController(app: app)
        let popover = NSPopover()
        dashboard.attach(to: popover)
        let tabs = try XCTUnwrap(controls(dashboard.view, of: NSSegmentedControl.self).first { $0.segmentCount == 2 })
        let settings = try XCTUnwrap(controls(dashboard.view, of: NSButton.self).first { $0.title == "Settings" })
        let quotaSize = popover.contentSize
        // Never order this window onscreen. Its bounds model the popup's content area.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: popover.contentSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)
        root.addSubview(dashboard.view)

        func checkHeader() throws {
            XCTAssertEqual(popover.contentSize, dashboard.preferredContentSize)
            window.setContentSize(popover.contentSize)
            root.layoutSubtreeIfNeeded()
            XCTAssertTrue(controls(dashboard.view, of: NSSegmentedControl.self).contains { $0 === tabs })
            XCTAssertTrue(controls(dashboard.view, of: NSButton.self).contains { $0 === settings })
            for control in [tabs as NSControl, settings] {
                let frame = control.convert(control.bounds, to: root)
                XCTAssertTrue(root.bounds.contains(frame), "Header must remain inside the clickable window")
                let hit = try XCTUnwrap(root.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
                XCTAssertTrue(hit === control || hit.isDescendant(of: control))
                XCTAssertTrue(control.isEnabled)
                XCTAssertNotNil(control.target)
                XCTAssertNotNil(control.action)
            }
        }

        for language in [AppLanguage.english, .chinese] {
            L10n.language = language
            for _ in 0..<5 {
                select(1, in: tabs)
                XCTAssertTrue(dashboard.showsLocalTokens)
                try checkHeader()
                let picker = try XCTUnwrap(controls(dashboard.view, of: NSSegmentedControl.self).first { $0.segmentCount == 4 })
                for period in [0, 2, 3, 1] {
                    select(period, in: picker)
                    XCTAssertEqual(picker.selectedSegment, period)
                    XCTAssertTrue(controls(dashboard.view, of: NSSegmentedControl.self).contains { $0 === picker })
                    dashboard.rebuild() // Same path used by background refreshes.
                    XCTAssertEqual(picker.selectedSegment, period)
                    try checkHeader()
                }
                let scroll = try XCTUnwrap(controls(dashboard.view, of: NSScrollView.self).first)
                let document = try XCTUnwrap(scroll.documentView)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                dashboard.rebuild()
                try checkHeader()
                select(0, in: tabs)
                XCTAssertFalse(dashboard.showsLocalTokens)
                XCTAssertEqual(popover.contentSize, quotaSize)
                dashboard.rebuild()
                try checkHeader()
            }
        }
    }

}
