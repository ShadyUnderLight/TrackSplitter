import Foundation

/// Unified subprocess runner with timeout, cancellation, and cleanup support.
/// All external process calls (ffprobe, ffmpeg, python) flow through this type.
public enum ProcessRunnerError: Error, LocalizedError {
    case timeout(seconds: Double, output: String)
    case cancelled
    case executionFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .timeout(let secs, _): return "Process timed out after \(Int(secs))s"
        case .cancelled: return "Task was cancelled"
        case .executionFailed(let msg, let code): return "Process exited with \(code): \(msg)"
        }
    }
}

/// Shared state between the poll loop and the timeout/cancellation handlers.
/// Guards against double-resumption of the continuation and holds the active Process.
private final class ProcessShared: @unchecked Sendable {
    enum State: Sendable {
        case running      // normal: poll loop drives to completion
        case terminating  // timeout won: poll loop should exit without resuming
        case cancelled    // cancellation won: poll loop already resumed; do nothing
        case done         // normal completion: already resumed; do nothing
    }

    var process: Process?
    var state: State = .running
    let lock = NSLock()

    /// Attempt to transition from `running` to `newState`.
    /// Returns true if the transition succeeded (caller owns the resume).
    /// Returns false if already moved to a terminal state (another path won).
    @discardableResult
    func tryTransition(to newState: State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .running = state else { return false }
        state = newState
        return true
    }

    /// Returns the current state. Thread-safe.
    func currentState() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

/// A non-isolated subprocess execution context.
/// Instances are lightweight value types — create one per logical subprocess batch.
public struct ProcessRunner: Sendable {
    /// Optional timeout in seconds. Nil = no timeout.
    public var timeoutSeconds: Double?

    /// Optional cleanup to run when a subprocess fails or times out.
    /// Receives the list of files that may have been partially written.
    public var cleanupOnFailure: (@Sendable ([URL]) -> Void)?

    public init(
        timeoutSeconds: Double? = nil,
        cleanupOnFailure: (@Sendable ([URL]) -> Void)? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.cleanupOnFailure = cleanupOnFailure
    }

    /// Run a subprocess and return its stdout.
    /// - Parameters:
    ///   - executable: Path to the binary.
    ///   - arguments: Command-line arguments.
    ///   - isCancelled: Checked at 50ms intervals during subprocess execution;
    ///     return true to terminate the subprocess and throw cancelled.
    /// - Returns: The full stdout as a string.
    public func run(
        executable: String,
        arguments: [String],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> String {
        try await withThrowingTaskGroup(of: (String, String, Int32).self) { group -> String in
            let shared = ProcessShared()

            group.addTask {
                try await self.runProcess(shared: shared, executable: executable, arguments: arguments, isCancelled: isCancelled)
            }

            if let timeout = timeoutSeconds {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    // Timeout won: transition to .terminating, terminate process.
                    Self.terminateProcess(shared: shared)
                    return ("", "", -1)  // sentinel: timeout
                }
            }

            let result: (String, String, Int32)
            do {
                result = try await group.next()!
            } catch {
                group.cancelAll()
                throw error
            }

            group.cancelAll()

            if result.2 == -1 {
                throw ProcessRunnerError.timeout(seconds: timeoutSeconds!, output: result.0)
            }

            if Task.isCancelled || isCancelled() {
                throw ProcessRunnerError.cancelled
            }

            if result.2 != 0 {
                throw ProcessRunnerError.executionFailed(result.1.isEmpty ? result.0 : result.1, result.2)
            }

            return result.0
        }
    }

    /// Low-level run that returns (stdout, stderr, terminationStatus).
    /// Exposed for cases that need to inspect stderr even on success.
    public func runCollecting(
        executable: String,
        arguments: [String],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> (stdout: String, stderr: String, terminationStatus: Int32) {
        try await withThrowingTaskGroup(of: (String, String, Int32).self) { group -> (String, String, Int32) in
            let shared = ProcessShared()

            group.addTask {
                try await self.runProcess(shared: shared, executable: executable, arguments: arguments, isCancelled: isCancelled)
            }

            if let timeout = timeoutSeconds {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    // Timeout won: transition to .terminating, terminate process.
                    Self.terminateProcess(shared: shared)
                    return ("", "", -1)
                }
            }

            let result: (String, String, Int32)
            do {
                result = try await group.next()!
            } catch {
                group.cancelAll()
                throw error
            }

            group.cancelAll()

            if result.2 == -1 {
                throw ProcessRunnerError.timeout(seconds: timeoutSeconds!, output: result.0)
            }

            if Task.isCancelled || isCancelled() {
                throw ProcessRunnerError.cancelled
            }

            return result
        }
    }

    // MARK: - Private

    /// Shared process termination helper. Called by both the timeout handler
    /// and the cancellation path to ensure the OS process is dead before we return.
    private static func terminateProcess(shared: ProcessShared) {
        shared.lock.lock()
        let proc = shared.process
        shared.lock.unlock()

        proc?.terminate()

        // Give the process a brief window to exit cleanly; if it doesn't, escalate.
        if let p = proc, p.isRunning {
            let deadline = Date().addingTimeInterval(0.2)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if p.isRunning {
                p.interrupt()  // SIGINT — more graceful than SIGKILL
            }
            if p.isRunning {
                p.terminate()  // one final attempt after interrupt
            }
        }
    }

    /// Starts the subprocess and polls at 50ms intervals for completion,
    /// timeout, or cancellation. Shares state via `shared` so the timeout
    /// handler can transition to .terminating and the cancellation path can
    /// transition to .cancelled, ensuring only one path resumes the
    /// continuation.
    private func runProcess(
        shared: ProcessShared,
        executable: String,
        arguments: [String],
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> (stdout: String, stderr: String, terminationStatus: Int32) {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            shared.lock.lock()
            shared.process = proc
            shared.lock.unlock()

            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            // Poll at 50ms intervals; check both Task-level and caller-level cancellation.
            Task {
                while proc.isRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)

                    // Check timeout transition first: if timeout won, exit without resuming.
                    if case .terminating = shared.currentState() {
                        return
                    }

                    if Task.isCancelled || isCancelled() {
                        // Cancellation won: terminate and resume with cancelled.
                        if shared.tryTransition(to: .cancelled) {
                            Self.terminateProcess(shared: shared)
                            cont.resume(throwing: ProcessRunnerError.cancelled)
                        }
                        return
                    }
                }

                // Process finished normally. Only resume if we are still in .running state.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if shared.tryTransition(to: .done) {
                    cont.resume(returning: (stdout, stderr, proc.terminationStatus))
                }
                // If transition failed, another path already won — do nothing.
            }
        }
    }
}
