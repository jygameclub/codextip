import AppKit
import ServiceManagement
import CodexTipCore

final class AppController: NSObject, NSApplicationDelegate {
    private(set) var preferences = Preferences()
    private(set) var history = UsageHistory()
    private(set) var error: String?
    private(set) var storageError: String?
    private(set) var refreshing = false
    private(set) var localTokens: LocalTokenReport?
    private(set) var localTokensRefreshing = false
    private(set) var localTokensProgress = (done: 0, total: 0)
    private(set) var localTokensError: String?
    private let tokenIndexer = LocalTokenIndexer()
    private var timer: Timer?
    private var clockTimer: Timer?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private var dashboard: DashboardController!
    private var optionsMenu: NSMenu?
    private let store = LocalStore.directory
    private var historyURL: URL { store.appendingPathComponent("history.json") }
    private var preferencesURL: URL { store.appendingPathComponent("preferences.json") }

    var selected: WindowSnapshot? {
        guard let windows = history.latest?.windows else { return nil }
        return windows.first { $0.id == preferences.selectedWindowID } ?? windows.first
    }

    var stale: Bool {
        guard let latest = history.latest else { return true }
        let age = Date().timeIntervalSince(latest.date)
        return error != nil || age < 0 || age > Double(preferences.refreshMinutes * 60) * 1.8 + 30
    }

    var hasRecentData: Bool {
        history.hasRecentData(windowID: selected?.id ?? preferences.selectedWindowID)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Prevent duplicate menu-bar items when the binary is launched directly twice.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) { NSApp.terminate(nil); return }
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do { preferences = try LocalStore.read(Preferences.self, from: preferencesURL) }
            catch { storageError = L10n.text("设置读取失败，已使用默认设置。", "Could not load settings. Using defaults.") }
        }
        preferences.validate()
        L10n.language = preferences.language ?? .system
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try LocalStore.read(UsageHistory.self, from: historyURL) }
            catch { storageError = L10n.text("历史记录读取失败，将从现在重新采样。", "Could not load history. Starting a new history.") }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.setAccessibilityLabel(L10n.text("Codex 额度", "Codex quota"))
        dashboard = DashboardController(app: self)
        popover.contentViewController = dashboard
        popover.behavior = .transient
        popover.animates = false
        redraw()
        schedule()
        refresh()
        clockTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.redraw() }
        if let clockTimer { RunLoop.main.add(clockTimer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); clockTimer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    @objc private func woke() { refresh(); schedule() }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        dashboard.rebuild()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func consumption(minutes: Int) -> Consumption {
        if stale { return .unavailable(L10n.text("等待最新采样", "Waiting for a fresh sample")) }
        guard let selected else { return .unavailable(L10n.text("等待额度数据", "Waiting for quota data")) }
        return history.consumption(windowID: selected.id, seconds: Double(minutes * 60))
    }

    var title: String {
        guard let selected, let remaining = selected.window.remaining else {
            return refreshing ? "···" : "—"
        }
        let name = selected.bucketID == "codex" ? "" : (selected.name.contains("Spark") ? "Spark " : selected.name + " ")
        let main = "\(name)\(selected.window.compactLabel) \(percent(remaining))%"
        if stale { return main + L10n.text(" · 旧", " · stale") }
        if preferences.compactMode || preferences.periods.isEmpty { return main }
        let deltas = preferences.periods.map { consumption(minutes: $0).menuLabel(minutes: $0) }.joined(separator: " · ")
        return main + " (\(deltas))"
    }

    private func redraw() {
        guard statusItem != nil else { return }
        statusItem.button?.title = title
        let hasData = hasRecentData
        statusItem.button?.image = MenuBarBrand.image(hasData: hasData, preferences: preferences)
        statusItem.button?.setAccessibilityLabel(L10n.text("Codex 额度", "Codex quota"))
        statusItem.button?.toolTip = L10n.text("Codex 剩余额度；10m/1% 表示近 10 分钟约消耗 1 个百分点。* 表示部分时段，— 表示暂无统计。点击查看详情和设置。", "Remaining Codex quota. 10m/1% means an estimated 1 percentage point consumed in 10 minutes. * means partial history; — means unavailable. Click for details and settings.")
        statusItem.button?.toolTip = (statusItem.button?.toolTip ?? "") + "\n" + MenuBarBrand.label(hasData: hasData, preferences: preferences)
        statusItem.button?.setAccessibilityValue(title + " · " + MenuBarBrand.label(hasData: hasData, preferences: preferences))
        if popover.isShown && optionsMenu == nil { dashboard.rebuild() }
    }

    private func schedule() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: Double(preferences.refreshMinutes * 60), repeats: true) { [weak self] _ in self?.refresh() }
        newTimer.tolerance = 3
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    @objc func refresh() {
        refreshLocalTokens()
        guard !refreshing else { return }
        refreshing = true; redraw()
        let path = preferences.executablePath
        let interval = Double(preferences.refreshMinutes * 60)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CodexClient.fetch(executable: path, interval: interval) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch result {
                case let .success(snapshot):
                    self.error = nil
                    self.history.append(snapshot)
                    do { try LocalStore.save(self.history, to: self.historyURL) }
                    catch { self.storageError = L10n.text("无法保存采样记录，退出后可能丢失历史。", "Could not save samples. History may be lost after quitting.") }
                    if snapshot.windows.isEmpty { self.error = L10n.text("当前账户没有可用的订阅额度数据。请确认 Codex 使用 ChatGPT 账户登录。", "No subscription quota available. Make sure Codex is signed in with your ChatGPT account.") }
                case let .failure(error):
                    // Errors are intentionally generic; upstream diagnostics may contain account details.
                    self.error = (error as? ClientError)?.localizedDescription ?? L10n.text("无法读取额度，请检查 Codex 路径、登录状态和网络。", "Could not read quota. Check the Codex path, login and connection.")
                }
                self.redraw()
            }
        }
    }

    @objc func refreshLocalTokens() {
        guard !localTokensRefreshing else { return }
        localTokensRefreshing = true; localTokensProgress = (0, 0); localTokensError = nil
        redraw()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.tokenIndexer.scan { done, total in
                    DispatchQueue.main.async { [weak self] in
                        self?.localTokensProgress = (done, total); self?.redraw()
                    }
                }
            }
            DispatchQueue.main.async {
                self.localTokensRefreshing = false
                switch result {
                case let .success(report): self.localTokens = report
                case .failure:
                    self.localTokensError = L10n.text("本地日志索引失败，请检查日志目录与缓存目录权限。", "Local indexing failed. Check permissions for the log and cache folders.")
                }
                self.redraw()
            }
        }
    }

    private func savePreferences() {
        preferences.validate()
        do { try LocalStore.save(preferences, to: preferencesURL) }
        catch { storageError = L10n.text("无法保存设置，请检查本机目录权限。", "Could not save settings. Check local folder permissions.") }
        redraw()
    }

    func showSettings(from button: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, action: Selector? = nil, tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.tag = tag; item.state = on ? .on : .off
            return item
        }
        let refreshMenu = NSMenu()
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let option = item(language.menuLabel, action: #selector(setLanguage(_:)), on: language == (preferences.language ?? .system))
            option.representedObject = language.rawValue
            languageMenu.addItem(option)
        }
        let languageItem = item("语言 / Language")
        languageItem.submenu = languageMenu; menu.addItem(languageItem)
        menu.addItem(.separator())
        let sizeMenu = NSMenu()
        for size in Preferences.dotSizeOptions {
            sizeMenu.addItem(item("\(size) pt", action: #selector(setDotSize(_:)), tag: size, on: preferences.effectiveDotSize == size))
        }
        let sizeItem = item(L10n.text("状态圆点大小", "Status dot size"))
        sizeItem.submenu = sizeMenu; menu.addItem(sizeItem)
        for hasData in [true, false] {
            let colorMenu = NSMenu()
            for color in IndicatorColor.allCases {
                let option = item(color.label, action: #selector(setDotColor(_:)), tag: hasData ? 1 : 0, on: preferences.dotColor(hasData: hasData) == color)
                option.representedObject = color.rawValue
                var swatchPreferences = preferences
                swatchPreferences.dotSize = 10
                swatchPreferences.dataDotColor = color
                option.image = MenuBarBrand.statusDot(hasData: true, preferences: swatchPreferences)
                colorMenu.addItem(option)
            }
            let colorItem = item(hasData ? L10n.text("有数据时的颜色", "Color when data is available") : L10n.text("无数据时的颜色", "Color when data is unavailable"))
            colorItem.submenu = colorMenu; menu.addItem(colorItem)
        }
        menu.addItem(.separator())
        for minutes in Preferences.refreshOptions {
            refreshMenu.addItem(item(L10n.text("每 \(minutes) 分钟", "Every \(minutes) min"), action: #selector(setRefresh(_:)), tag: minutes, on: preferences.refreshMinutes == minutes))
        }
        let refreshItem = item(L10n.text("刷新间隔", "Refresh interval"))
        refreshItem.submenu = refreshMenu; menu.addItem(refreshItem)

        let periodMenu = NSMenu()
        for minutes in Preferences.periodOptions {
            let label = L10n.period(minutes)
            let option = item(label, action: #selector(togglePeriod(_:)), tag: minutes, on: preferences.periods.contains(minutes))
            option.isEnabled = preferences.periods.contains(minutes) || preferences.periods.count < 3
            periodMenu.addItem(option)
        }
        let periodItem = item(L10n.text("括号内的统计时段（最多 3 项）", "Recent periods (up to 3)"))
        periodItem.submenu = periodMenu; menu.addItem(periodItem)

        let windowMenu = NSMenu()
        for window in history.latest?.windows ?? [] {
            let option = item("\(window.name) · \(window.window.label)", action: #selector(selectWindow(_:)), on: window.id == selected?.id)
            option.representedObject = window.id; windowMenu.addItem(option)
        }
        let windowItem = item(L10n.text("菜单栏显示哪项额度", "Quota shown in menu bar"))
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        menu.addItem(item(L10n.text("紧凑显示（仅剩余额度）", "Compact display (remaining quota only)"), action: #selector(toggleCompact), on: preferences.compactMode))
        menu.addItem(.separator())
        let loginState = SMAppService.mainApp.status
        menu.addItem(item(loginState == .requiresApproval ? L10n.text("登录时启动（待系统批准）", "Launch at login (approval pending)") : L10n.text("登录时启动", "Launch at login"),
                          action: #selector(toggleLogin), on: loginState == .enabled))
        menu.addItem(item(L10n.text("指定 Codex 可执行文件…", "Choose Codex executable…"), action: #selector(chooseExecutable)))
        if preferences.executablePath != nil { menu.addItem(item(L10n.text("恢复自动查找 Codex", "Find Codex automatically"), action: #selector(resetExecutable))) }
        menu.addItem(.separator())
        menu.addItem(item(L10n.text("打开本地数据目录", "Open local data folder"), action: #selector(openData)))
        menu.addItem(item(L10n.text("退出 CodexTip", "Quit CodexTip"), action: #selector(quit)))
        optionsMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        optionsMenu = nil
        redraw()
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        preferences.language = language
        L10n.language = language
        savePreferences()
        refresh()
    }

    @objc private func setDotSize(_ sender: NSMenuItem) {
        preferences.dotSize = sender.tag; savePreferences()
    }

    @objc private func setDotColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = IndicatorColor(rawValue: raw) else { return }
        if sender.tag == 1 { preferences.dataDotColor = color }
        else { preferences.noDataDotColor = color }
        savePreferences()
    }

    @objc private func setRefresh(_ sender: NSMenuItem) {
        preferences.refreshMinutes = sender.tag; savePreferences(); schedule(); refresh()
    }
    @objc private func togglePeriod(_ sender: NSMenuItem) {
        if preferences.periods.contains(sender.tag) { preferences.periods.removeAll { $0 == sender.tag } }
        else { preferences.periods.append(sender.tag) }
        savePreferences()
    }
    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.selectedWindowID = id; savePreferences()
    }
    @objc private func toggleCompact() { preferences.compactMode.toggle(); savePreferences() }
    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch { storageError = L10n.text("登录启动设置失败，请将 App 放在 Applications 文件夹后重试。", "Could not set up launch at login. Move the app into Applications and retry."); redraw() }
    }
    @objc private func chooseExecutable() {
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 Codex 可执行文件", "Choose Codex executable")
        panel.message = L10n.text("选择名为 codex 的可执行文件；通常位于 Codex.app/Contents/Resources 中。", "Choose the codex executable, usually inside Codex.app/Contents/Resources.")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if let path = CodexClient.findExecutable(override: preferences.executablePath) {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                self.storageError = L10n.text("所选文件不可执行。", "The selected file is not executable."); self.redraw(); return
            }
            self.preferences.executablePath = url.path; self.savePreferences(); self.refresh()
        }
    }
    @objc private func resetExecutable() { preferences.executablePath = nil; savePreferences(); refresh() }
    @objc private func openData() { NSWorkspace.shared.open(store) }
    @objc private func quit() { NSApp.terminate(nil) }

    // Offscreen visual QA uses the same dashboard, with deterministic demonstration data.
    func loadPreview() {
        let now = Date()
        localTokens = .demo(now: now)
        for i in 0...60 {
            let used = 9 + Double(i) / 10
            let window = RateWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(4 * 86400).timeIntervalSince1970)
            history.append(UsageSnapshot(date: now.addingTimeInterval(Double(i - 60) * 60), interval: 60, accountKey: "preview", windows: [
                WindowSnapshot(id: "codex/primary", bucketID: "codex", name: "Codex", plan: "pro", window: window),
                WindowSnapshot(id: "codex_bengalfox/secondary", bucketID: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", plan: "pro", window: RateWindow(usedPercent: 66, windowDurationMins: 10080, resetsAt: window.resetsAt))
            ]))
        }
    }
}
