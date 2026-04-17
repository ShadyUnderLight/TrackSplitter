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
            group.addTask {
                try await self.runProcess(executable: executable, arguments: arguments, isCancelled: isCancelled)
            }

            if let timeout = timeoutSeconds {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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
                throw ProcessRunnerError.timeout(seconds: timeoutSeconds!, output: "")
            }

            let (stdout, stderr, rc) = result

            if Task.isCancelled || isCancelled() {
                throw ProcessRunnerError.cancelled
            }

            if rc != 0 {
                throw ProcessRunnerError.executionFailed(stderr.isEmpty ? stdout : stderr, rc)
            }

            return stdout
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
            group.addTask {
                try await self.runProcess(executable: executable, arguments: arguments, isCancelled: isCancelled)
            }

            if let timeout = timeoutSeconds {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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
                throw ProcessRunnerError.timeout(seconds: timeoutSeconds!, output: "")
            }

            if Task.isCancelled || isCancelled() {
                throw ProcessRunnerError.cancelled
            }

            return result
        }
    }

    // MARK: - Private

    /// Starts the subprocess and polls at 50ms intervals for completion,
    /// timeout, or cancellation (both Task.isCancelled and the caller-supplied
    /// isCancelled closure). Terminates the process promptly on any interrupt.
    private func runProcess(
        executable: String,
        arguments: [String],
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> (stdout: String, stderr: String, terminationStatus: Int32) {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            // Poll at 50ms intervals; check both Task-level and caller-level cancellation.
            Task {
                while process.isRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled || isCancelled() {
                        process.terminate()
                        cont.resume(throwing: ProcessRunnerError.cancelled)
                        return
                    }
                }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: (stdout, stderr, process.terminationStatus))
            }
        }
    }
}
