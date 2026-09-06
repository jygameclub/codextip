import AppKit
import CodexTipCore

private let accent = NSColor.systemTeal

private final class DashboardBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

final class DashboardController: NSViewController {
    private unowned let app: AppController
    init(app: AppController) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = DashboardBackground(frame: NSRect(x: 0, y: 0, width: 390, height: 580)); rebuild() }

    func rebuild() {
        guard isViewLoaded else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22)
        ])
        func add(_ child: NSView) {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let title = text("CodexTip", size: 17, weight: .semibold)
        let plan = app.selected?.plan?.uppercased() ?? "USAGE"
        add(row(title, text(plan, size: 10, weight: .semibold, color: .secondaryLabelColor)))

        let summary = vertical(spacing: 5)
        let selected = app.selected
        summary.addArrangedSubview(text("\(selected?.name ?? "Codex") · \(selected?.window.label ?? L10n.text("订阅额度", "Subscription quota"))", size: 12, color: .secondaryLabelColor))
        let number = selected?.window.remaining.map { percent($0) + "%" } ?? "—"
        let numberRow = NSStackView(views: [text(number, size: 43, weight: .semibold, color: app.stale ? .secondaryLabelColor : .labelColor), text(L10n.text("剩余", "remaining"), size: 13, color: .secondaryLabelColor)])
        numberRow.orientation = .horizontal; numberRow.alignment = .firstBaseline; numberRow.spacing = 8
        summary.addArrangedSubview(numberRow)
        let bar = QuotaBar(remaining: selected?.window.remaining ?? 0)
        summary.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let resetText: String
        if let resetsAt = selected?.window.resetsAt {
            let date = Date(timeIntervalSince1970: resetsAt)
            resetText = date > Date() ? L10n.text("\(L10n.date(date, includeDay: true)) 重置", "Resets \(L10n.date(date, includeDay: true))") : L10n.text("等待服务器更新重置时间", "Waiting for the updated reset time")
        } else { resetText = L10n.text("重置时间暂不可用", "Reset time unavailable") }
        summary.addArrangedSubview(text(resetText, size: 11, color: .secondaryLabelColor))
        add(summary)
        add(separator())

        let recent = vertical(spacing: 12)
        recent.addArrangedSubview(text(L10n.text("最近消耗", "Recent consumption"), size: 12, weight: .semibold))
        let periods = Array(Set(app.preferences.periods + [10, 60])).sorted()
        for minutes in periods {
            let usage = app.consumption(minutes: minutes)
            let duration = L10n.period(minutes)
            let left = vertical(spacing: 3)
            left.addArrangedSubview(text(duration, size: 12))
            left.addArrangedSubview(text(usage.detail, size: 10, color: .secondaryLabelColor))
            let line = row(left, text(usage.compact, size: 16, weight: .medium, color: accent))
            recent.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: recent.widthAnchor).isActive = true
        }
        add(recent)
        add(text(L10n.text("% 表示所选额度的百分点变化，按采样估算。\n* 尚未覆盖完整时段；— 暂无可靠统计。", "% is the estimated percentage-point change in this quota.\n* Partial history; — no reliable estimate yet."), size: 10, color: .secondaryLabelColor))

        let otherWindows = (app.history.latest?.windows ?? []).filter { $0.id != selected?.id }
        if !otherWindows.isEmpty {
            add(separator())
            let other = vertical(spacing: 9)
            other.addArrangedSubview(text(L10n.text("其他额度", "Other quotas"), size: 12, weight: .semibold))
            for window in otherWindows {
                let line = row(text("\(window.name) · \(window.window.label)", size: 11, color: .secondaryLabelColor),
                               text(window.window.remaining.map { percent($0) + "%" } ?? "—", size: 12, weight: .medium))
                other.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: other.widthAnchor).isActive = true
            }
            add(other)
        }
        add(separator())
        let status: String
        if let error = app.error { status = error + (app.history.latest == nil ? "" : L10n.text("\n当前显示上次成功读取的数据。", "\nShowing the last successful reading.")) }
        else if app.refreshing { status = L10n.text("正在刷新额度…", "Refreshing quota…") }
        else if let latest = app.history.latest {
            let updated = L10n.text("更新于 \(L10n.date(latest.date)) · 每 \(app.preferences.refreshMinutes) 分钟刷新",
                                    "Updated \(L10n.date(latest.date)) · Every \(app.preferences.refreshMinutes) min")
            status = (app.stale ? L10n.text("数据已过期 · ", "Stale · ") : "") + updated
        } else { status = L10n.text("正在连接本机 Codex…", "Connecting to local Codex…") }
        add(text(status, size: 10, color: app.error != nil ? .systemOrange : .secondaryLabelColor))
        let hasData = app.hasRecentData
        let statusRow = NSStackView(views: [NSImageView(image: MenuBarBrand.statusDot(hasData: hasData)), text(MenuBarBrand.label(hasData: hasData), size: 10, color: .secondaryLabelColor)])
        statusRow.orientation = .horizontal; statusRow.spacing = 6; statusRow.alignment = .centerY
        add(statusRow)
        if let storageError = app.storageError { add(text(storageError, size: 10, color: .systemOrange)) }
        let refresh = NSButton(title: app.refreshing ? L10n.text("刷新中…", "Refreshing…") : L10n.text("立即刷新", "Refresh now"), target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .rounded; refresh.isEnabled = !app.refreshing
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading
        let settings = NSButton(title: L10n.text("设置", "Settings"), target: self, action: #selector(settingsClicked(_:)))
        settings.bezelStyle = .rounded
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        add(row(refresh, settings))
        view.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 44
        preferredContentSize = NSSize(width: 390, height: height)
        view.setFrameSize(preferredContentSize)
        view.layoutSubtreeIfNeeded()
    }

    @objc private func refreshClicked() { app.refresh() }
    @objc private func settingsClicked(_ sender: NSButton) { app.showSettings(from: sender) }
}

private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: string)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.isSelectable = false; field.maximumNumberOfLines = 0
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    return field
}

private func vertical(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    return stack
}

private func row(_ left: NSView, _ right: NSView) -> NSStackView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [left, spacer, right])
    stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
    right.setContentCompressionResistancePriority(.required, for: .horizontal)
    return stack
}

private func separator() -> NSView {
    let line = NSBox(); line.boxType = .separator
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

private final class QuotaBar: NSView {
    let remaining: Double
    init(remaining: Double) { self.remaining = remaining; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        (remaining <= 10 ? NSColor.systemOrange : accent).setFill()
        var fill = bounds; fill.size.width *= max(0, min(100, remaining)) / 100
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

func renderPreview(to path: String, dark: Bool) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let controller = AppController()
    controller.loadPreview()
    let dashboard = DashboardController(app: controller)
    let view = dashboard.view
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    dashboard.rebuild()
    let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = view.appearance
    window.backgroundColor = .windowBackgroundColor
    window.contentView = view
    // Render our own UI offscreen; no screen recording or foreground window needed.
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path)) }
}
