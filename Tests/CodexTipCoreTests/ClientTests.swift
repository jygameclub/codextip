import XCTest
@testable import CodexTipCore

final class ClientTests: XCTestCase {
    private func withExecutable(_ script: String, body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codextip-test-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }

    func testHandshakeReadOnlyRequestsAndSplitMessages() throws {
        let script = #"""
        IFS= read -r init
        case "$init" in *initialize*) ;; *) exit 7;; esac
        printf '{"id":1,"res'
        printf 'ult":{}}\n'
        IFS= read -r initialized
        case "$initialized" in *initialized*) ;; *) exit 8;; esac
        IFS= read -r request
        case "$request" in *account*rateLimits*read*) ;; *) exit 9;; esac
        printf '{"method":"account/updated","params":{}}\n'
        printf '{"id":2,"method":"unsupported/serverRequest","params":{}}\n'
        IFS= read -r rejected
        case "$rejected" in *-32601*) ;; *) exit 10;; esac
        printf '{"id":2,"result":{"accountId":"test","rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1790000000}}}}\n'
        IFS= read -r end
        """#
        try withExecutable(script) { path in
            let snapshot = try CodexClient.fetch(executable: path, interval: 60, timeout: 3)
            XCTAssertEqual(snapshot.windows[0].window.remaining, 75)
        }
    }

    func testTimeoutIsBounded() throws {
        try withExecutable("exec /bin/sleep 10\n") { path in
            let start = Date()
            XCTAssertThrowsError(try CodexClient.fetch(executable: path, interval: 60, timeout: 0.2)) { error in
                guard case ClientError.timeout = error else { return XCTFail("Expected timeout: \(error)") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testExitedServerDoesNotHang() throws {
        try withExecutable("IFS= read -r init\nexit 0\n") { path in
            XCTAssertThrowsError(try CodexClient.fetch(executable: path, interval: 60, timeout: 2))
        }
    }

    func testServerErrorsDoNotExposeMessage() throws {
        let script = #"""
        IFS= read -r init
        printf '{"id":1,"error":{"code":401,"message":"secret-account-diagnostic"}}\n'
        IFS= read -r end
        """#
        try withExecutable(script) { path in
            XCTAssertThrowsError(try CodexClient.fetch(executable: path, interval: 60, timeout: 2)) { error in
                XCTAssertTrue(error.localizedDescription.contains("401"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testInvalidOverrideDoesNotSilentlySelectDifferentClient() {
        XCTAssertNil(CodexClient.findExecutable(override: "/missing/codex"))
    }
}
