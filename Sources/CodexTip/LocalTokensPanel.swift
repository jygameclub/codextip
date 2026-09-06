import AppKit
import CodexTipCore

private final class LocalTokenContentView: NSView {
    override var isFlipped: Bool { true }
}

final class LocalTokensController: NSViewController {
    private unowned let app: AppController
    private var period: LocalTokenPeriod = .week
    var onPeriodChange: (() -> Void)?
    private var heightConstraint: NSLayoutConstraint?
    init(app: AppController) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = LocalTokenContentView(frame: NSRect(x: 0, y: 0, width: 346, height: 560)); rebuild() }

    func rebuild() {
        guard isViewLoaded else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        heightConstraint?.isActive = false
        let stack = vertical(spacing: 13)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor)
        ])
        func add(_ child: NSView) { stack.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        add(text(L10n.text("本机用量趋势", "On-device usage"), size: 17, weight: .semibold))
        add(text(L10n.text("本地日志 · 所有账号合计 · 离线可读", "Local logs · All accounts combined · Available offline"), size: 10, color: .secondaryLabelColor))
        let periods = LocalTokenPeriod.allCases
        let picker = NSSegmentedControl(labels: periods.map(\.label), trackingMode: .selectOne, target: self, action: #selector(periodChanged(_:)))
        picker.selectedSegment = periods.firstIndex(of: period) ?? 1
        picker.segmentDistribution = .fillEqually
        add(picker)

        if let report = app.localTokens {
            let summary = report.summary(period: period)
            let total = text(report.sourceAvailable ? shortTokens(summary.counts.total) : "—", size: 32, weight: .semibold)
            total.toolTip = exactTokens(summary.counts.total) + " tokens"
            add(row(total, text("TOKENS", size: 10, weight: .semibold, color: .secondaryLabelColor)))
            let cost = summary.cost
            let costLabel = text(report.sourceAvailable ? cost.display : "—", size: 18, weight: .semibold, color: .systemTeal)
            costLabel.toolTip = L10n.text("普通输入 \(usd(cost.inputUSD)) · 缓存读取 \(usd(cost.cachedUSD)) · 缓存写入 \(usd(cost.cacheWriteUSD)) · 输出 \(usd(cost.outputUSD))",
                                          "Uncached input \(usd(cost.inputUSD)) · Cache reads \(usd(cost.cachedUSD)) · Cache writes \(usd(cost.cacheWriteUSD)) · Output \(usd(cost.outputUSD))")
            add(row(text(L10n.text("API 等值估算", "API-equivalent estimate"), size: 11, color: .secondaryLabelColor), costLabel))
            add(text(L10n.text("USD · 标准 API 单价估算，非订阅账单或实际扣费。", "USD · Standard API rates; not your subscription bill or actual charges."), size: 9, color: .secondaryLabelColor))
            if cost.isPartial {
                let warning = text(L10n.text("\(shortTokens(cost.unpricedTokens)) tokens 缺少价格，未计入金额。", "\(shortTokens(cost.unpricedTokens)) tokens have no price and are excluded."), size: 10, color: .systemOrange)
                warning.toolTip = cost.unpricedModels.sorted().joined(separator: ", ")
                add(warning)
            }
            let chart = TokenTrendView(buckets: summary.buckets, hourly: summary.hourly, monthly: summary.monthly)
            add(chart); chart.heightAnchor.constraint(equalToConstant: 132).isActive = true
            add(text(L10n.text("蓝：输入（含缓存）  青：输出  ·  悬停查看详情", "Blue: input (incl. cache)  Teal: output · Hover for details"), size: 9, color: .secondaryLabelColor))
            add(separator())
            let columns = NSStackView()
            columns.orientation = .horizontal; columns.distribution = .fillEqually; columns.spacing = 10
            for (label, value) in [(L10n.text("输入", "Input"), summary.counts.input),
                                   (L10n.text("缓存命中", "Cached input"), summary.counts.cached),
                                   (L10n.text("输出", "Output"), summary.counts.output)] {
                let column = vertical(spacing: 5)
                column.addArrangedSubview(text(label, size: 10, color: .secondaryLabelColor))
                let number = text(shortTokens(value), size: 16, weight: .medium); number.toolTip = exactTokens(value)
                column.addArrangedSubview(number); columns.addArrangedSubview(column)
            }
            add(columns)
            let rate = summary.cacheHitRate.map { String(format: "%.1f%%", $0) } ?? "—"
            add(row(text(L10n.text("缓存命中率 \(rate)", "Cache hit rate \(rate)"), size: 10, color: .secondaryLabelColor),
                    text(L10n.text("推理 \(shortTokens(summary.counts.reasoning))", "Reasoning \(shortTokens(summary.counts.reasoning))"), size: 10, color: .secondaryLabelColor)))
            add(text(L10n.text("总量 = 输入 + 输出；缓存已含于输入，推理已含于输出。", "Total = input + output. Cache and reasoning are subsets, not extra tokens."), size: 9, color: .secondaryLabelColor))
            add(separator())
            add(text(L10n.text("模型分布", "By model"), size: 12, weight: .semibold))
            for model in summary.models.prefix(5) {
                let name = model.name == "unknown" ? L10n.text("模型未知", "Unknown model") : model.name
                let line = row(text(name, size: 11), text("\(shortTokens(model.counts.total)) · \(model.cost.display)", size: 11, weight: .medium))
                line.toolTip = "\(name): \(exactTokens(model.counts.total)) tokens · \(model.cost.display)"
                add(line)
            }
            if summary.models.count > 5 {
                let rest = summary.models.dropFirst(5).reduce(Int64(0)) { $0 + $1.counts.total }
                let restCost = summary.models.dropFirst(5).reduce(TokenCostEstimate()) { $0 + $1.cost }
                add(row(text(L10n.text("其他 \(summary.models.count - 5) 个模型", "\(summary.models.count - 5) other models"), size: 10, color: .secondaryLabelColor), text("\(shortTokens(rest)) · \(restCost.display)", size: 11)))
            }
            if summary.events == 0 {
                add(text(report.sourceAvailable ? L10n.text("此时段没有可用的 token 记录。", "No token records in this period.") : L10n.text("未找到 sessions / archived_sessions 本地日志。", "No local sessions / archived_sessions logs found."), size: 11, color: .secondaryLabelColor))
            }
            let pricing = NSButton(title: L10n.text("价格表 · \(TokenPricing.checkedOn)", "Price table · \(TokenPricing.checkedOn)"), target: self, action: #selector(showPricing))
            pricing.bezelStyle = .rounded; pricing.controlSize = .small; pricing.font = .systemFont(ofSize: 10)
            add(pricing)
            let updated = L10n.date(report.scannedAt)
            add(text(L10n.text("\(report.fileCount) 个日志文件 · \(summary.events) 条用量记录 · \(updated)", "\(report.fileCount) log files · \(summary.events) usage records · \(updated)"), size: 9, color: .secondaryLabelColor))
            if report.skippedFiles > 0 || report.malformedRecords > 0 {
                add(text(L10n.text("部分数据不可读：\(report.skippedFiles) 个文件、\(report.malformedRecords) 条记录；统计可能不完整。", "Partial data: \(report.skippedFiles) unreadable files, \(report.malformedRecords) invalid records. Totals may be incomplete."), size: 10, color: .systemOrange))
            }
            if report.unresolvedForks > 0 {
                add(text(L10n.text("\(report.unresolvedForks) 个旧版分支缺少父日志，继承用量可能重复。", "\(report.unresolvedForks) legacy forks have no parent log; inherited usage may be duplicated."), size: 10, color: .systemOrange))
            }
        } else {
            add(text(L10n.text("首次读取会索引已有历史，之后只处理新增日志。", "The first scan indexes existing history; later scans only process new log data."), size: 12, color: .secondaryLabelColor))
        }
        if let error = app.localTokensError { add(text(error, size: 10, color: .systemOrange)) }
        if app.localTokensRefreshing {
            let p = app.localTokensProgress
            add(text(L10n.text("正在后台索引 \(p.done)/\(p.total)…", "Indexing in the background \(p.done)/\(p.total)…"), size: 10, color: .secondaryLabelColor))
        }
        let refresh = NSButton(title: L10n.text("刷新本地数据", "Refresh local data"), target: app, action: #selector(AppController.refreshLocalTokens))
        refresh.bezelStyle = .rounded; refresh.isEnabled = !app.localTokensRefreshing
        add(refresh)
        view.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        heightConstraint = view.heightAnchor.constraint(equalToConstant: height)
        heightConstraint?.isActive = true
        view.setFrameSize(NSSize(width: 346, height: height))
        view.layoutSubtreeIfNeeded()
    }

    @objc private func showPricing() {
        NSWorkspace.shared.open(TokenPricing.sourceURL)
    }

    @objc private func periodChanged(_ sender: NSSegmentedControl) {
        guard LocalTokenPeriod.allCases.indices.contains(sender.selectedSegment) else { return }
        period = LocalTokenPeriod.allCases[sender.selectedSegment]
        onPeriodChange?()
    }
}

private final class TokenTrendView: NSView {
    let buckets: [TokenTrendBucket]
    let hourly: Bool
    let monthly: Bool
    init(buckets: [TokenTrendBucket], hourly: Bool, monthly: Bool) {
        self.buckets = buckets; self.hourly = hourly; self.monthly = monthly
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.text("本地 token 用量趋势", "Local token usage trend"))
        setAccessibilityValue(buckets.map { "\(dateLabel($0.start)): \(exactTokens($0.counts.total)), \($0.cost.display)" }.joined(separator: "\n"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.dateFormat = hourly ? "HH:mm" : (monthly ? "yyyy-MM" : "MM/dd")
        return formatter.string(from: date)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !buckets.isEmpty else { return }
        removeAllToolTips()
        let maximum = max(1, buckets.map { $0.counts.total }.max() ?? 1)
        let baseline: CGFloat = 23
        let height = bounds.height - baseline - 22
        let step = bounds.width / CGFloat(buckets.count)
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: baseline)); line.line(to: NSPoint(x: bounds.width, y: baseline)); line.stroke()
        (shortTokens(maximum) as NSString).draw(at: NSPoint(x: 0, y: bounds.height - 14), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
        for (index, bucket) in buckets.enumerated() {
            let x = CGFloat(index) * step + min(3, step * 0.15)
            let width = max(0.5, step - min(6, step * 0.3))
            let inputHeight = height * CGFloat(bucket.counts.input) / CGFloat(maximum)
            let outputHeight = height * CGFloat(bucket.counts.output) / CGFloat(maximum)
            NSColor.systemBlue.setFill(); NSRect(x: x, y: baseline, width: width, height: inputHeight).fill()
            NSColor.systemTeal.setFill(); NSRect(x: x, y: baseline + inputHeight, width: width, height: outputHeight).fill()
            addToolTip(NSRect(x: CGFloat(index) * step, y: baseline, width: step, height: height), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        for index in Set([0, buckets.count / 2, buckets.count - 1]) {
            let label = dateLabel(buckets[index].start) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
            let width = label.size(withAttributes: attrs).width
            let x = max(0, min(bounds.width - width, (CGFloat(index) + 0.5) * step - width / 2))
            label.draw(at: NSPoint(x: x, y: 4), withAttributes: attrs)
        }
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard buckets.indices.contains(index) else { return "" }
        let bucket = buckets[index]
        return "\(dateLabel(bucket.start))\n\(exactTokens(bucket.counts.total)) tokens · \(bucket.cost.display)\n" + L10n.text("输入 \(exactTokens(bucket.counts.input)) · 输出 \(exactTokens(bucket.counts.output))", "Input \(exactTokens(bucket.counts.input)) · Output \(exactTokens(bucket.counts.output))")
    }
}
