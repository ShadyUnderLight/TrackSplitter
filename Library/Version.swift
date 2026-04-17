import Foundation

/// Single source of truth for TrackSplitter version information.
public enum Version {
    /// Semantic version string shown in CLI and used as CFBundleShortVersionString.
    public static let currentVersion = "1.0.0"

    /// Build counter. Resets to 1 on each new release tag.
    /// CI overrides this via the `TS_BUILD_NUMBER` environment variable.
    public static var buildNumber: Int {
        if let raw = getenv("TS_BUILD_NUMBER"), let num = Int(String(cString: raw)), num > 0 {
            return num
        }
        return Git.commitCount
    }

    /// Short git SHA shown in CLI banner for bug reports.
    public static var commitSHA: String {
        Git.shortSHA ?? "unknown"
    }

    /// CLI `--version` output string.
    public static var cliVersion: String {
        "\(currentVersion) (build \(buildNumber))"
    }
}

// MARK: - Private helpers

private enum Git {
    static var commitCount: Int {
        let output = run(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 1
    }

    static var shortSHA: String? {
        run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit() } catch { return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
