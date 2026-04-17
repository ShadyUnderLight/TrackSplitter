import Foundation

// MARK: - Environment Diagnostics

/// A single environment problem detected during pre-flight checks.
public enum EnvironmentIssue: Sendable {
    case pythonNotFound(searchedPaths: [String])
    case pythonVersionTooOld(version: String, minimum: String)
    case mutagenNotImportable(cause: String)
    case scriptNotFound(searchedPaths: [String])

    public var remediation: String {
        switch self {
        case .pythonNotFound:
            return "Python 3 not found. Install Python 3 from https://www.python.org or `brew install python3`, then ensure it is in your PATH."
        case .pythonVersionTooOld(let version, let minimum):
            return "Python \(version) is too old. Please upgrade to Python \(minimum) or later."
        case .mutagenNotImportable:
            return "Python package 'mutagen' is not installed. Run: python3 -m pip install mutagen --break-system-packages"
        case .scriptNotFound:
            return "embed_metadata.py could not be located. This file should be bundled with the app. Please re-install TrackSplitter."
        }
    }

    public var summary: String {
        switch self {
        case .pythonNotFound: return "Python 3 not found"
        case .pythonVersionTooOld(let version, _): return "Python \(version) too old"
        case .mutagenNotImportable: return "mutagen not importable"
        case .scriptNotFound: return "embed_metadata.py not found"
        }
    }
}

/// Result of a pre-flight environment check.
public struct EnvironmentReport: Sendable {
    /// All issues found. Empty if the environment is fully healthy.
    public let issues: [EnvironmentIssue]
    /// The Python path that will be used, if found.
    public let pythonPath: String?
    /// The script path that will be used, if found.
    public let scriptPath: String?
    /// Python version string, if available.
    public let pythonVersion: String?

    public var isHealthy: Bool { issues.isEmpty }

    public init(issues: [EnvironmentIssue], pythonPath: String?, scriptPath: String?, pythonVersion: String?) {
        self.issues = issues
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.pythonVersion = pythonVersion
    }
}

// MARK: - Errors

/// Errors from the metadata writing layer.
public enum EmbedError: Error, LocalizedError {
    case pythonNotFound
    case scriptNotFound
    case encodingFailed
    case tempFileFailed
    case scriptFailed(String)
    case environmentCheckFailed([EnvironmentIssue])

    public var errorDescription: String? {
        switch self {
        case .pythonNotFound: return "Python 3 not found in PATH"
        case .scriptNotFound: return "embed_metadata.py not found"
        case .encodingFailed: return "Failed to encode metadata as JSON"
        case .tempFileFailed: return "Failed to write temp JSON file"
        case .scriptFailed(let msg): return "Metadata script error: \(msg)"
        case .environmentCheckFailed(let issues):
            let summaries = issues.map { $0.summary }.joined(separator: "; ")
            return "Environment check failed: \(summaries)"
        }
    }
}

// MARK: - Embed Result

public struct EmbedResult: Sendable {
    public let total: Int
    public let succeeded: Int
    public let failed: Int
    public let failures: [String]
    /// True if any file had cover art skipped (e.g., WAV doesn't support embedded cover art).
    public let coverWasSkipped: Bool

    public var isFullySuccessful: Bool { failed == 0 }
    public var isPartiallySuccessful: Bool { succeeded > 0 && failed > 0 }

    public init(total: Int, succeeded: Int, failed: Int, failures: [String], coverWasSkipped: Bool) {
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.failures = failures
        self.coverWasSkipped = coverWasSkipped
    }
}

// MARK: - MetadataWriter Protocol

/// Protocol for metadata writing implementations.
/// Allows swapping the backend (Python/mutagen, ffmpeg, AVFoundation, etc.) without changing the engine.
public protocol MetadataWriter: Sendable {
    /// Write metadata to the given batch of files.
    func embedBatch(
        files: [(url: URL, title: String, trackNumber: Int)],
        artist: String,
        album: String,
        year: String,
        genre: String,
        comment: String?,
        composer: String?,
        discNumber: String?,
        totalTracks: Int,
        coverData: Data?
    ) async throws -> EmbedResult

    /// Perform a pre-flight environment check.
    func checkEnvironment() async -> EnvironmentReport
}

// MARK: - Python/mutagen Adapter

/// Default adapter using Python + mutagen via embed_metadata.py.
public actor PythonMetadataAdapter: MetadataWriter {

    public enum AdapterError: Error {
        case pythonNotFound
        case scriptNotFound
        case encodingFailed
        case tempFileFailed
        case scriptFailed(String)
    }

    public struct AdapterEmbedResult: Sendable {
        public let total: Int
        public let succeeded: Int
        public let failed: Int
        public let failures: [String]
        public let coverWasSkipped: Bool

        public var isFullySuccessful: Bool { failed == 0 }
        public var isPartiallySuccessful: Bool { succeeded > 0 && failed > 0 }

        public init(total: Int, succeeded: Int, failed: Int, failures: [String], coverWasSkipped: Bool) {
            self.total = total
            self.succeeded = succeeded
            self.failed = failed
            self.failures = failures
            self.coverWasSkipped = coverWasSkipped
        }

        public func toEmbedResult() -> EmbedResult {
            EmbedResult(total: total, succeeded: succeeded, failed: failed,
                        failures: failures, coverWasSkipped: coverWasSkipped)
        }
    }

    private let pythonPath: String
    private let scriptPath: String
    private let timeoutSeconds: Double?
    private var _cachedReport: EnvironmentReport?

    public init(timeoutSeconds: Double? = 60) {
        self.pythonPath = Self.findPython()
        self.scriptPath = Self.locateScript()
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Environment

    private static func findPython() -> String {
        let candidates = ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.14", "/usr/local/bin/python3", "python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"
    }

    private static func locateScript() -> String {
        if let bundleURL = Bundle.module.url(forResource: "embed_metadata", withExtension: "py"),
           FileManager.default.isReadableFile(atPath: bundleURL.path) {
            return bundleURL.path
        }

        let exeDir = (CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? FileManager.default.currentDirectoryPath)
        let exeURL = URL(fileURLWithPath: exeDir)

        let searchPaths: [URL] = [
            exeURL.appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("Library/Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("..").appendingPathComponent("Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("..").appendingPathComponent("Library/Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("..").appendingPathComponent("..").appendingPathComponent("Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("..").appendingPathComponent("..").appendingPathComponent("Library/Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("..").appendingPathComponent("..").appendingPathComponent("..").appendingPathComponent("Resources").appendingPathComponent("embed_metadata.py"),
            exeURL.appendingPathComponent("..").appendingPathComponent("..").appendingPathComponent("..").appendingPathComponent("Library/Resources").appendingPathComponent("embed_metadata.py"),
        ]

        for url in searchPaths {
            if FileManager.default.isReadableFile(atPath: url.path) {
                return url.path
            }
        }

        return "embed_metadata.py"
    }

    /// Returns the Python version string, or nil if python was not found.
    private func pythonVersion() async -> String? {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return nil }
        let runner = ProcessRunner(timeoutSeconds: 5)
        do {
            let (stdout, _, rc) = try await runner.runCollecting(executable: pythonPath, arguments: ["-c", "import sys; print(sys.version_info.major + '.' + sys.version_info.minor)"])
            guard rc == 0 else { return nil }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Checks whether mutagen can be imported by the python at pythonPath.
    private func checkMutagenImport() async -> String? {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return "Python not found" }
        let runner = ProcessRunner(timeoutSeconds: 10)
        do {
            let (stdout, stderr, rc) = try await runner.runCollecting(
                executable: pythonPath,
                arguments: ["-c", "import mutagen; print('OK')"]
            )
            if rc == 0 && stdout.contains("OK") { return nil }
            return rc != 0 ? "python exit \(rc): \(stderr.prefix(80))" : "mutagen not importable"
        } catch {
            return "failed to run: \(error.localizedDescription)"
        }
    }

    public func checkEnvironment() async -> EnvironmentReport {
        if let cached = _cachedReport { return cached }

        var issues: [EnvironmentIssue] = []
        var version: String? = nil
        let scriptPaths = Self.allScriptSearchPaths()

        if !FileManager.default.isExecutableFile(atPath: pythonPath) {
            issues.append(.pythonNotFound(searchedPaths: Self.pythonSearchPaths()))
        } else {
            version = await pythonVersion()
            if let v = version, v.hasPrefix("2.") || v.hasPrefix("3.0") || v.hasPrefix("3.1") || v.hasPrefix("3.2") || v.hasPrefix("3.3") || v.hasPrefix("3.4") || v.hasPrefix("3.5") {
                issues.append(.pythonVersionTooOld(version: v, minimum: "3.6"))
            }

            if let mutagenErr = await checkMutagenImport() {
                issues.append(.mutagenNotImportable(cause: mutagenErr))
            }
        }

        if !FileManager.default.isReadableFile(atPath: scriptPath) {
            issues.append(.scriptNotFound(searchedPaths: scriptPaths))
        }

        let report = EnvironmentReport(
            issues: issues,
            pythonPath: FileManager.default.isExecutableFile(atPath: pythonPath) ? pythonPath : nil,
            scriptPath: FileManager.default.isReadableFile(atPath: scriptPath) ? scriptPath : nil,
            pythonVersion: version
        )
        _cachedReport = report
        return report
    }

    private static func pythonSearchPaths() -> [String] {
        ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.14", "/usr/local/bin/python3", "python3"]
    }

    private static func allScriptSearchPaths() -> [String] {
        let exeDir = (CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? FileManager.default.currentDirectoryPath)
        let exeURL = URL(fileURLWithPath: exeDir)
        return [
            exeURL.appendingPathComponent("embed_metadata.py").path,
            exeURL.appendingPathComponent("Resources").appendingPathComponent("embed_metadata.py").path,
            exeURL.appendingPathComponent("Library/Resources").appendingPathComponent("embed_metadata.py").path,
        ]
    }

    // MARK: - Embed

    public func embedBatch(
        files: [(url: URL, title: String, trackNumber: Int)],
        artist: String,
        album: String,
        year: String,
        genre: String,
        comment: String?,
        composer: String?,
        discNumber: String?,
        totalTracks: Int,
        coverData: Data?
    ) async throws -> EmbedResult {
        struct Item: Encodable {
            let path: String; let title: String; let artist: String
            let album: String; let year: String; let genre: String
            let tracknum: String; let total: String
            let comment: String?
            let composer: String?
            let discNumber: String?
        }

        let items = files.map { f in
            Item(path: f.url.path, title: f.title, artist: artist, album: album,
                 year: year, genre: genre, tracknum: String(f.trackNumber), total: String(totalTracks),
                 comment: comment, composer: composer, discNumber: discNumber)
        }

        let coverB64: String? = coverData.map { Data($0).base64EncodedString() }
        struct Payload: Encodable { let files: [Item]; let coverData: String? }
        let payload = Payload(files: items, coverData: coverB64)

        guard let jsonData = try? JSONEncoder().encode(payload) else {
            throw AdapterError.encodingFailed
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("tracksplitter_payload_\(UUID().uuidString).json")
        do {
            try jsonData.write(to: tempFile)
        } catch {
            throw AdapterError.tempFileFailed
        }

        defer { try? FileManager.default.removeItem(at: tempFile) }

        let (stdout, stderr, rc) = try await runScript(jsonFile: tempFile)

        let parsed = Self.parseOutput(stdout)

        if rc != 0 && parsed.succeeded == 0 && parsed.failed == 0 {
            return AdapterEmbedResult(
                total: files.count,
                succeeded: 0,
                failed: files.count,
                failures: ["脚本执行失败（RC=\(rc)）：\(stderr.prefix(100))"],
                coverWasSkipped: parsed.coverWasSkipped
            ).toEmbedResult()
        }

        return AdapterEmbedResult(
            total: files.count,
            succeeded: parsed.succeeded,
            failed: parsed.failed,
            failures: parsed.failures,
            coverWasSkipped: parsed.coverWasSkipped
        ).toEmbedResult()
    }

    private func runScript(jsonFile: URL) async throws -> (stdout: String, stderr: String, rc: Int32) {
        let runner = ProcessRunner(timeoutSeconds: timeoutSeconds)
        do {
            let (stdout, stderr, rc) = try await runner.runCollecting(
                executable: pythonPath,
                arguments: [scriptPath, jsonFile.path]
            )
            return (stdout, stderr, rc)
        } catch let error as ProcessRunnerError {
            if case .timeout = error {
                throw AdapterError.scriptFailed("Python script timed out after \(Int(timeoutSeconds ?? 0))s")
            }
            throw error
        } catch {
            throw error
        }
    }

    /// Parses the stdout lines emitted by embed_metadata.py.
    static func parseOutput(_ stdout: String) -> (succeeded: Int, failed: Int, failures: [String], coverWasSkipped: Bool) {
        var succeeded = 0
        var failed = 0
        var failures: [String] = []
        var coverWasSkipped = false

        for line in stdout.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
            if line.hasPrefix("DONE: ") {
                succeeded += 1
            } else if line.hasPrefix("SKIP: ") {
                succeeded += 1
                if line.contains("cover art skipped") {
                    coverWasSkipped = true
                }
            } else if line.hasPrefix("ERROR: ") {
                failed += 1
                failures.append(String(line.dropFirst(7)))
            }
        }

        return (succeeded, failed, failures, coverWasSkipped)
    }
}

// MARK: - MetadataEmbedder (adapter-based wrapper)

/// Bridges to a metadata writing backend.
///
/// Defaults to `PythonMetadataAdapter` but accepts any `MetadataWriter` implementation.
public actor MetadataEmbedder {

    private let writer: any MetadataWriter

    /// Creates a MetadataEmbedder using the default Python/mutagen backend.
    public init(timeoutSeconds: Double? = 60) {
        self.writer = PythonMetadataAdapter(timeoutSeconds: timeoutSeconds)
    }

    /// Creates a MetadataEmbedder with a custom writer (useful for testing or alternative backends).
    public init(writer: any MetadataWriter) {
        self.writer = writer
    }

    /// Perform a pre-flight environment check.
    /// Call this before processing to fail fast with a clear diagnosis.
    public func checkEnvironment() async -> EnvironmentReport {
        await writer.checkEnvironment()
    }

    /// Embed metadata into multiple audio files at once.
    public func embedBatch(
        files: [(url: URL, title: String, trackNumber: Int)],
        artist: String,
        album: String,
        year: String,
        genre: String,
        comment: String?,
        composer: String?,
        discNumber: String?,
        totalTracks: Int,
        coverData: Data?
    ) async throws -> EmbedResult {
        // Pre-flight check — fail fast with a clear diagnosis
        let report = await checkEnvironment()
        if !report.isHealthy {
            throw EmbedError.environmentCheckFailed(report.issues)
        }

        return try await writer.embedBatch(
            files: files, artist: artist, album: album, year: year, genre: genre,
            comment: comment, composer: composer, discNumber: discNumber,
            totalTracks: totalTracks, coverData: coverData
        )
    }
}
