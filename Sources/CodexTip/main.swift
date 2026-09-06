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
if args.contains("--local-tokens") {
    do {
        // Offline diagnostic. No Codex process, network request, or quota-account lookup.
        let indexer = LocalTokenIndexer(cacheURL: nil)
        let start = Date()
        let report = try indexer.scan()
        let seconds = Date().timeIntervalSince(start)
        let summary = report.summary(period: .all)
        var output: [String: Any] = ["files": report.fileCount, "events": summary.events,
            "input": summary.counts.input, "cached": summary.counts.cached, "output": summary.counts.output,
            "reasoning": summary.counts.reasoning, "total": summary.counts.total,
            "skippedFiles": report.skippedFiles, "malformedRecords": report.malformedRecords,
            "unresolvedForks": report.unresolvedForks,
            "estimatedKnownUSD": summary.cost.knownUSD, "unpricedTokens": summary.cost.unpricedTokens,
            "unpricedModels": summary.cost.unpricedModels.sorted(), "pricingCheckedOn": TokenPricing.checkedOn,
            "pricingBasis": "Standard API equivalent, not actual charges",
            "deduplicated": report.duplicates, "seconds": seconds,
            "models": summary.models.map { ["model": $0.name, "tokens": $0.counts.total, "estimatedKnownUSD": $0.cost.knownUSD, "unpricedTokens": $0.cost.unpricedTokens] as [String: Any] }]
        if args.contains("--benchmark") {
            let warmStart = Date()
            let warm = try indexer.scan()
            output["warmSeconds"] = Date().timeIntervalSince(warmStart)
            output["warmBytesRead"] = warm.bytesRead
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    } catch { fputs("Local token indexing failed.\n", stderr); exit(1) }
} else if args.contains("--check") {
    do {
        let snapshot = try CodexClient.fetch(interval: 60)
        let report = snapshot.windows.map { window in
            "\(window.name) · \(window.window.label): \(window.window.remaining.map { percent($0) + "%" } ?? L10n.text("不可用", "unavailable")) \(L10n.text("剩余", "remaining"))"
        }
        print(report.isEmpty ? L10n.text("没有可用的订阅额度数据", "No subscription quota data available") : report.joined(separator: "\n"))
        print("\(L10n.text("账户隔离", "Account isolation")): \(snapshot.accountKey == nil ? L10n.text("不可用，禁用历史比较", "unavailable; history comparison disabled") : L10n.text("已启用", "enabled"))")
        exit(report.isEmpty ? 1 : 0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = args.firstIndex(of: "--render-animation-preview"), index + 1 < args.count {
    do { try renderAnimationPreview(to: args[index + 1]) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = args.firstIndex(of: "--render-menu-preview"), index + 1 < args.count {
    do { try renderMenuPreview(to: args[index + 1], dotOptions: args.contains("--dot-options"), emojiOptions: args.contains("--emoji-options")) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = args.firstIndex(of: "--render-preview"), index + 1 < args.count {
    do { try renderPreview(to: args[index + 1], dark: args.contains("--dark"), localTokens: args.contains("--local-preview"), pricingPartial: args.contains("--partial-pricing"), scrollEnd: args.contains("--preview-scroll-end")) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.run()
}
