import Foundation

enum ExecutableLocator {
    static func find(_ name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]

        let manager = FileManager.default
        for path in candidates where manager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

enum ProcessRunner {
    static func run(program: URL, args: [String], logLine: (@MainActor (String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = program
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw TrackSplitterError.processFailed("Failed to launch \(program.lastPathComponent): \(error.localizedDescription)")
        }

        async let stdoutTask: String = collectText(from: stdout.fileHandleForReading, logLine: logLine, mirrorToLog: false)
        async let stderrTask: String = collectText(from: stderr.fileHandleForReading, logLine: logLine, mirrorToLog: true)

        process.waitUntilExit()
        let output = try await stdoutTask
        _ = try await stderrTask

        guard process.terminationStatus == 0 else {
            throw TrackSplitterError.processFailed("\(program.lastPathComponent) exited with status \(process.terminationStatus)")
        }

        return output
    }

    private static func collectText(from handle: FileHandle, logLine: (@MainActor (String) -> Void)?, mirrorToLog: Bool) async throws -> String {
        var data = Data()
        for try await line in handle.bytes.lines {
            let string = String(line)
            if mirrorToLog, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await logLine?(string)
            }
            if let lineData = (string + "\n").data(using: .utf8) {
                data.append(lineData)
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
