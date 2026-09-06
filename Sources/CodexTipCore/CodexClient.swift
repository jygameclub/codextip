import Foundation
import Darwin

public enum ClientError: LocalizedError {
    case notInstalled, timeout, disconnected, protocolError, server(Int)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: return L10n.text("未找到 Codex。请安装并登录 Codex，或在设置中指定可执行文件。", "Codex not found. Install and sign in to Codex, or choose its executable in Settings.")
        case .timeout: return L10n.text("读取额度超时，请检查网络后重试。", "Quota request timed out. Check your connection and retry.")
        case .disconnected: return L10n.text("Codex 连接中断，请确认已登录，并尝试重新刷新。", "Codex disconnected. Check that you are signed in and refresh again.")
        case .protocolError: return L10n.text("无法识别额度数据，请更新 Codex 后重试。", "Unrecognized quota data. Update Codex and retry.")
        case let .server(code): return L10n.text("额度读取失败（\(code)），请检查 Codex 登录状态和网络。", "Quota request failed (\(code)). Check your Codex login and connection.")
        }
    }
}

/// A read-only app-server connection. No model turns, browser, TCP listener or auth-file reads.
public final class CodexClient {
    public static func findExecutable(override: String? = nil) -> String? {
        let fm = FileManager.default
        if let override, !override.isEmpty { return fm.isExecutableFile(atPath: override) ? override : nil }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static func fetch(executable: String? = nil, interval: TimeInterval, timeout: TimeInterval = 25) throws -> UsageSnapshot {
        guard let path = findExecutable(override: executable) else { throw ClientError.notInstalled }
        let connection = try Connection(path: path, timeout: timeout)
        defer { connection.close() }
        _ = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "codextip", "title": "CodexTip", "version": "1.6.2"],
            "capabilities": [:] as [String: Any]
        ])
        try connection.send(["method": "initialized", "params": [:] as [String: Any]])
        let result = try connection.request(id: 2, method: "account/rateLimits/read")
        let response: RateResponse
        do { response = try JSONDecoder().decode(RateResponse.self, from: JSONSerialization.data(withJSONObject: result)) }
        catch { throw ClientError.protocolError }
        return response.snapshot(interval: interval)
    }
}

private final class Connection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let deadline: TimeInterval
    private var closed = false

    init(path: String, timeout: TimeInterval) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        // Avoid loading the current project's settings or starting any task.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
    }

    func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let end = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }

    deinit { close() }

    func send(_ object: [String: Any]) throws {
        guard process.isRunning else { throw ClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(id: Int, method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        while true {
            let object = try nextMessage()
            // Request IDs are independent in each direction; a server request can
            // have the same numeric ID as our pending request.
            if object["method"] != nil {
                if let requestID = object["id"] {
                    try send(["id": requestID, "error": ["code": -32601, "message": "Read-only usage client"]])
                }
                continue
            }
            if (object["id"] as? Int) == id {
                if let error = object["error"] as? [String: Any] { throw ClientError.server(error["code"] as? Int ?? -1) }
                guard let result = object["result"] as? [String: Any] else { throw ClientError.protocolError }
                return result
            }
        }
    }

    private func nextMessage() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                return obj
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ClientError.timeout }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let count = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if count < 0 { if errno == EINTR { continue }; throw ClientError.disconnected }
            if count == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let received = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard received > 0 else { throw ClientError.disconnected }
            buffer.append(contentsOf: bytes.prefix(received))
            guard buffer.count <= 4 * 1024 * 1024 else { throw ClientError.protocolError }
        }
    }
}
