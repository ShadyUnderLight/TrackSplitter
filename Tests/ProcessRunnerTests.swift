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
        let cancelled = UnsafeBool(false)

        // Start a task that will flip cancelled=true after 50ms
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            cancelled.value = true
        }

        do {
            _ = try await runner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                isCancelled: { cancelled.value }
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
}

/// A plain mutable bool for test use. Not thread-safe — name reflects that.
private final class UnsafeBool {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}
