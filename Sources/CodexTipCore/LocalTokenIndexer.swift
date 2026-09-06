import Foundation
import CryptoKit

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private final class LogDates {
    let fractional = ISO8601DateFormatter()
    let plain = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func parse(_ value: Any?) -> Date? {
        if let s = value as? String { return fractional.date(from: s) ?? plain.date(from: s) }
        if let n = value as? NSNumber {
            let value = n.doubleValue
            guard value.isFinite else { return nil }
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        return nil
    }
}

struct LocalLogState: Codable {
    var offset: UInt64 = 0
    var fileSize: UInt64 = 0
    var modified: Double = 0
    var inode: UInt64 = 0
    var prefixLength = 0
    var prefixDigest = ""
    var ordinal = -1
    var sessionKey = ""
    var parentKey: String?
    var inheritedUntil: Int?
    var created: Date?
    var model = "unknown"
    var previous: TokenCounts?
    var events: [LocalTokenEvent] = []
    var malformed = 0
    var inherited = 0
}

private struct LocalTokenCache: Codable {
    var version = 1
    var root = ""
    var files: [String: LocalLogState] = [:]
}

/// One serial background worker owns this indexer. It reads only usage/metadata records,
/// persists no conversation text, and never consults the signed-in account.
public final class LocalTokenIndexer {
    public let root: URL
    private let cacheURL: URL?
    private var cache: LocalTokenCache?
    private let dates = LogDates()
    public static var defaultRoot: URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public init(root: URL = LocalTokenIndexer.defaultRoot, cacheURL: URL? = LocalStore.directory.appendingPathComponent("local-token-index.json")) {
        self.root = root.standardizedFileURL; self.cacheURL = cacheURL
    }

    public func scan(now: Date = Date(), progress: ((Int, Int) -> Void)? = nil) throws -> LocalTokenReport {
        let rootKey = digest(Data(root.path.utf8))
        if cache == nil {
            if let cacheURL, let loaded = try? LocalStore.read(LocalTokenCache.self, from: cacheURL), loaded.version == 1, loaded.root == rootKey {
                cache = loaded
            } else { cache = LocalTokenCache(root: rootKey) }
        }
        var state = cache!
        let fm = FileManager.default
        var paths: [URL] = []
        var sourceAvailable = false
        var skippedFiles = 0
        var enumerationFailed = false
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            sourceAvailable = true
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                 options: [.skipsHiddenFiles], errorHandler: { _, _ in
                enumerationFailed = true; skippedFiles += 1; return true
            }) else { enumerationFailed = true; skippedFiles += 1; continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true && values?.isSymbolicLink != true { paths.append(url) }
            }
        }
        // Stable traversal keeps scans and progress reproducible.
        paths.sort { $0.path < $1.path }
        var activeKeys = Set<String>()
        var bytesRead: UInt64 = 0
        var changed = false
        var lastProgress = Date.distantPast
        progress?(0, paths.count)
        for (index, path) in paths.enumerated() {
            let key = digest(Data(path.path.utf8))
            activeKeys.insert(key)
            do {
                let attributes = try fm.attributesOfItem(atPath: path.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                var file = state.files[key] ?? LocalLogState(sessionKey: key)
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                let prefix = try handle.read(upToCount: file.prefixLength) ?? Data()
                let invalidated = file.inode != inode || size < file.offset || digest(prefix) != file.prefixDigest
                    || (mtime != file.modified && size == file.fileSize)
                if invalidated { file = LocalLogState(sessionKey: key) }
                if file.offset < size || invalidated {
                    try handle.seek(toOffset: file.offset)
                    bytesRead += try read(handle, limit: size, state: &file)
                    file.inode = inode; file.modified = mtime; file.fileSize = size
                    file.prefixLength = Int(min(4096, file.offset))
                    try handle.seek(toOffset: 0)
                    file.prefixDigest = digest(try handle.read(upToCount: file.prefixLength) ?? Data())
                    state.files[key] = file; changed = true
                }
            } catch { skippedFiles += 1 }
            if Date().timeIntervalSince(lastProgress) > 0.7 {
                progress?(index + 1, paths.count); lastProgress = Date()
            }
        }
        if !enumerationFailed {
            let removed = state.files.keys.filter { !activeKeys.contains($0) }
            for key in removed { state.files.removeValue(forKey: key); changed = true }
        }
        if changed, let cacheURL { try LocalStore.save(state, to: cacheURL) }
        cache = state
        progress?(paths.count, paths.count)
        return makeReport(state, now: now, fileCount: paths.count, skippedFiles: skippedFiles, sourceAvailable: sourceAvailable, bytesRead: bytesRead)
    }

    private func read(_ handle: FileHandle, limit: UInt64, state: inout LocalLogState) throws -> UInt64 {
        let initial = state.offset
        var readPosition = initial
        var pending = Data()
        var discarded = false
        let maximumLine = 16 * 1024 * 1024
        while readPosition < limit {
            // FileHandle also creates autoreleased chunk buffers; bound their lifetime
            // so a cold scan never retains every byte of the user's log history.
            let advanced = try autoreleasepool { () throws -> Bool in
                let chunk = try handle.read(upToCount: Int(min(1024 * 1024, limit - readPosition))) ?? Data()
                guard !chunk.isEmpty else { return false }
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let newline = chunk[start...].firstIndex(of: 0x0a)
                    let end = newline ?? chunk.endIndex
                    if !discarded {
                        if pending.count + end - start <= maximumLine { pending.append(contentsOf: chunk[start..<end]) }
                        else { pending.removeAll(keepingCapacity: false); discarded = true }
                    }
                    guard let newline else { break }
                    state.ordinal += 1
                    // Foundation JSON/date parsing creates autoreleased objects. Drain
                    // each record instead of retaining a whole multi-GB scan's temporaries.
                    if !discarded { autoreleasepool { consume(pending, state: &state) } }
                    // Oversized non-usage records (screenshots etc.) don't consume memory.
                    pending.removeAll(keepingCapacity: true); discarded = false
                    start = newline + 1
                    state.offset = readPosition + UInt64(start)
                }
                readPosition += UInt64(chunk.count)
                return true
            }
            if !advanced { break }
        }
        // A partial trailing JSON record is deliberately not committed; retry next refresh.
        return readPosition - initial
    }

    private func consume(_ line: Data, state: inout LocalLogState) {
        // The top-level type appears at the start of Codex records. Avoid decoding
        // multi-megabyte tool output or message text just to discard it afterwards.
        let prefix = String(decoding: line.prefix(512), as: UTF8.self)
        guard prefix.contains("\"session_meta\"") || prefix.contains("\"turn_context\"") || prefix.contains("\"event_msg\"") else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any], let type = object["type"] as? String else {
            state.malformed += 1; return
        }
        if type == "session_meta" {
            if let id = (payload["id"] ?? payload["session_id"]) as? String { state.sessionKey = digest(Data(id.utf8)) }
            if let id = (payload["forked_from_id"] ?? payload["parent_thread_id"]) as? String { state.parentKey = digest(Data(id.utf8)) }
            state.inheritedUntil = payload["subagent_history_start_ordinal"] as? Int
            state.created = dates.parse(payload["timestamp"]) ?? dates.parse(object["timestamp"])
            return
        }
        if type == "turn_context" {
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        let total = TokenCounts.parse(info["total_token_usage"])
        let last = TokenCounts.parse(info["last_token_usage"])
        let previous = state.previous
        if let total { state.previous = total }
        // Repeated cumulative snapshots often repeat last_token_usage too.
        guard total == nil || total != previous else { return }
        guard let counts = last ?? total.map({ $0.subtracting(previous ?? TokenCounts()) }), counts.total > 0 else { return }
        if let boundary = state.inheritedUntil, state.ordinal < boundary {
            state.inherited += 1; return
        }
        guard let date = dates.parse(object["timestamp"]) else { state.malformed += 1; return }
        let model = (payload["model"] ?? info["model"]) as? String ?? state.model
        state.events.append(LocalTokenEvent(date: date, model: model, counts: counts, cumulative: total))
    }

    private func makeReport(_ cache: LocalTokenCache, now: Date, fileCount: Int, skippedFiles: Int, sourceAvailable: Bool, bytesRead: UInt64) -> LocalTokenReport {
        struct Signature: Hashable { var date: Date; var model: String; var counts: TokenCounts }
        var sessions: [String: LocalLogState] = [:]
        // Copies and archived duplicates of one session must not multiply usage.
        for key in cache.files.keys.sorted() {
            let file = cache.files[key]!
            if let existing = sessions[file.sessionKey], existing.events.count > file.events.count { continue }
            sessions[file.sessionKey] = file
        }
        var seen = Set<Signature>()
        var events: [LocalTokenEvent] = []
        var duplicates = cache.files.values.reduce(0) { $0 + $1.inherited + $1.events.count }
            - sessions.values.reduce(0) { $0 + $1.events.count }
        for key in sessions.keys.sorted() {
            let file = sessions[key]!
            let parent = file.parentKey.flatMap { sessions[$0] }
            var matchingParent = file.inheritedUntil == nil && parent != nil
            var parentIndex = 0
            for event in file.events {
                // Legacy forks may rewrite timestamps while copying the parent's prefix.
                if matchingParent, let parent, parent.events.indices.contains(parentIndex) {
                    let inherited = parent.events[parentIndex]
                    if event.counts == inherited.counts && event.cumulative == inherited.cumulative {
                        parentIndex += 1; duplicates += 1; continue
                    }
                    matchingParent = false
                }
                if file.inheritedUntil == nil, file.parentKey != nil, let created = file.created, event.date < created {
                    duplicates += 1; continue
                }
                let signature = Signature(date: event.date, model: event.model, counts: event.counts)
                if seen.insert(signature).inserted {
                    var pricedEvent = event
                    pricedEvent.pricingSession = file.sessionKey
                    events.append(pricedEvent)
                } else { duplicates += 1 }
            }
        }
        events.sort { $0.date < $1.date }
        var report = LocalTokenReport(events: events, scannedAt: now, fileCount: fileCount, skippedFiles: skippedFiles,
                                malformedRecords: cache.files.values.reduce(0) { $0 + $1.malformed }, duplicates: duplicates,
                                sourceAvailable: sourceAvailable, bytesRead: bytesRead)
        report.unresolvedForks = sessions.values.filter { file in
            file.inheritedUntil == nil && file.parentKey.map { sessions[$0] == nil } == true
        }.count
        return report
    }
}
