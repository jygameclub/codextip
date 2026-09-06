import AppKit
import CodexTipCore
import Darwin

// A closed app-server pipe must surface as a recoverable error, not kill the menu app.
signal(SIGPIPE, SIG_IGN)
let args = CommandLine.arguments
// CLI language override is process-local; previews/checks never change saved preferences.
if let index = args.firstIndex(of: "--language"), index + 1 < args.count {
    switch args[index + 1] {
    case "en": L10n.language = .english
    case "zh", "zh-Hans": L10n.language = .chinese
    default: fputs("Usage: --language en|zh\n", stderr); exit(2)
    }
}
if args.contains("--check") {
    do {
        let snapshot = try CodexClient.fetch(interval: 60)
        let report = snapshot.windows.map { window in
            "\(window.name) · \(window.window.label): \(window.window.remaining.map { percent($0) + "%" } ?? L10n.text("不可用", "unavailable")) \(L10n.text("剩余", "remaining"))"
        }
        print(report.isEmpty ? L10n.text("没有可用的订阅额度数据", "No subscription quota data available") : report.joined(separator: "\n"))
        print("\(L10n.text("账户隔离", "Account isolation")): \(snapshot.accountKey == nil ? L10n.text("不可用，禁用历史比较", "unavailable; history comparison disabled") : L10n.text("已启用", "enabled"))")
        exit(report.isEmpty ? 1 : 0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = args.firstIndex(of: "--render-menu-preview"), index + 1 < args.count {
    do { try renderMenuPreview(to: args[index + 1], dotOptions: args.contains("--dot-options")) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = args.firstIndex(of: "--render-preview"), index + 1 < args.count {
    do { try renderPreview(to: args[index + 1], dark: args.contains("--dark")) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.run()
}
