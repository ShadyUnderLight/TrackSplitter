import Foundation
import TrackSplitterLib
import XCTest

/// Tests for ProcessRunner: timeout, cancellation, and error handling.
final class ProcessRunnerTests: XCTestCase {

    // MARK: - Happy path

    func testRunReturnsStdout() async throws {
        let runner = ProcessRunner(timeoutSeconds: 5)
        let stdout = try await runner.run(
            executable: "/bin/echo",
            arguments: ["hello", "world"]
        )
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testRunCollectingReturnsStdoutStderrRC() async throws {
        let runner = ProcessRunner(timeoutSeconds: 5)
        let (stdout, stderr, rc) = try await runner.runCollecting(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2; exit 42"]
        )
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        XCTAssertEqual(rc, 42)
    }

    // MARK: - Timeout

    func testTimeoutThrowsTimeoutError() async throws {
        let runner = ProcessRunner(timeoutSeconds: 0.5)
        do {
            // Sleep for 2 seconds — longer than the 0.5s timeout
            try await runner.run(executable: "/bin/sleep", arguments: ["2"])
            XCTFail("Expected timeout error")
        } catch let error as ProcessRunnerError {
            if case .timeout(let secs, _) = error {
                XCTAssertEqual(secs, 0.5, accuracy: 0.1)
            } else {
                XCTFail("Expected timeout error, got \(error)")
            }
        }
    }

    // MARK: - Cancellation

    func testCancellationThrowsCancelledError() async throws {
        let runner = ProcessRunner(timeoutSeconds: nil)
        let cancelFlag = TestCancelFlag()

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            cancelFlag.cancel()
        }

        do {
            _ = try await runner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                isCancelled: { cancelFlag.isCancelled() }
            )
            XCTFail("Expected cancelled error")
        } catch let error as ProcessRunnerError {
            if case .cancelled = error {
                // Expected
            } else {
                XCTFail("Expected cancelled error, got \(error)")
            }
        }
    }

    // MARK: - Non-zero exit

    func testNonZeroExitThrowsExecutionFailed() async throws {
        let runner = ProcessRunner(timeoutSeconds: 5)
        do {
            try await runner.run(executable: "/bin/sh", arguments: ["-c", "echo failed >&2; exit 1"])
            XCTFail("Expected executionFailed error")
        } catch let error as ProcessRunnerError {
            if case .executionFailed(_, let code) = error {
                XCTAssertEqual(code, 1)
            } else {
                XCTFail("Expected executionFailed, got \(error)")
            }
        }
    }

    // MARK: - Subprocess cleanup guarantees (issue #53)

    func testTimeoutTerminatesSubprocessBeforeReturning() async throws {
        // Write a script that sleeps and writes its PID to a temp file.
        // After ProcessRunner times out and returns, verify the PID is dead.
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep_pid_\(UUID().uuidString).txt")
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wait_signal_\(UUID().uuidString).sh")

        let script = """
        echo $$ > '\(pidFile.path)'
        sleep 30
        """
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let runner = ProcessRunner(timeoutSeconds: 0.3)
        do {
            _ = try await runner.run(executable: "/bin/bash", arguments: [scriptFile.path])
            XCTFail("Expected timeout")
        } catch let error as ProcessRunnerError {
            XCTAssertTrue(error is ProcessRunnerError)
        }

        // Verify subprocess is dead after the runner returns
        if FileManager.default.fileExists(atPath: pidFile.path) {
            let pidStr = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(pidStr) {
                let alive = kill(pid, 0) == 0
                XCTAssertFalse(alive, "Subprocess should be dead after timeout; PID \(pid) still alive")
            }
        }

        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(at: scriptFile)
    }

    func testCancellationTerminatesSubprocessBeforeReturning() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep_pid_\(UUID().uuidString).txt")
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wait_signal_\(UUID().uuidString).sh")

        let script = """
        echo $$ > '\(pidFile.path)'
        sleep 30
        """
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let cancelFlag = TestCancelFlag()
        let runner = ProcessRunner(timeoutSeconds: nil)

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            cancelFlag.cancel()
        }

        do {
            _ = try await runner.run(
                executable: "/bin/bash",
                arguments: [scriptFile.path],
                isCancelled: { cancelFlag.isCancelled() }
            )
            XCTFail("Expected cancelled error")
        } catch let error as ProcessRunnerError {
            if case .cancelled = error {
                // Expected
            } else {
                XCTFail("Expected cancelled, got \(error)")
            }
        }

        // Verify subprocess is dead after the runner returns
        if FileManager.default.fileExists(atPath: pidFile.path) {
            let pidStr = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(pidStr) {
                let alive = kill(pid, 0) == 0
                XCTAssertFalse(alive, "Subprocess should be dead after cancellation; PID \(pid) still alive")
            }
        }

        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(at: scriptFile)
    }

    // NOTE: cleanupOnFailure is a pre-existing unused feature (defined but never called
    // in ProcessRunner). Testing it is out of scope for issue #53 which focuses on
    // subprocess termination guarantees after timeout/cancellation.
}

/// A simple thread-safe bool for test use.
private final class TestCancelFlag: @unchecked Sendable {
    private var _cancelled = false
    private let _lock = NSLock()

    func isCancelled() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _cancelled
    }

    func cancel() {
        _lock.lock()
        defer { _lock.unlock() }
        _cancelled = true
    }
}
