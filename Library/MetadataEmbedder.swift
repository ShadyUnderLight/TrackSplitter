import Foundation

/// Bridges to embed_metadata.py to write FLAC tags and cover art.
public actor MetadataEmbedder {

    public enum EmbedError: Error, LocalizedError {
        case pythonNotFound
        case scriptNotFound
        case encodingFailed
        case tempFileFailed
        case scriptFailed(String)

        public var errorDescription: String? {
            switch self {
            case .pythonNotFound: return "Python 3 not found in PATH"
            case .scriptNotFound: return "embed_metadata.py not found"
            case .encodingFailed: return "Failed to encode metadata as JSON"
            case .tempFileFailed: return "Failed to write temp JSON file"
            case .scriptFailed(let msg): return "Metadata script error: \(msg)"
            }
        }
    }

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

    /// Parses the stdout lines emitted by embed_metadata.py.
    /// Exposed for unit testing — call this directly instead of duplicating the logic.
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

    private let pythonPath: String
    private let scriptPath: String
    private let timeoutSeconds: Double?

    public init(timeoutSeconds: Double? = 60) {
        self.pythonPath = Self.findPython()
        self.scriptPath = Self.locateScript()
        self.timeoutSeconds = timeoutSeconds
    }

    private static func findPython() -> String {
        let candidates = ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.14", "/usr/local/bin/python3", "python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"
    }

    /// Walk up from the executable's directory to find embed_metadata.py.
    /// Handles SPM development builds, release builds, and installed layouts.
    private static func locateScript() -> String {
        // Primary: SwiftPM resource bundle (embed_metadata.py is in Library/Resources/)
        if let bundleURL = Bundle.module.url(forResource: "embed_metadata", withExtension: "py"),
           FileManager.default.isReadableFile(atPath: bundleURL.path) {
            return bundleURL.path
        }

        // Fallback: relative-path search for development / installed layouts
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

    /// Embed metadata into multiple FLAC files at once.
    /// Returns a per-file result indicating success/failure for each track.
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
            throw EmbedError.encodingFailed
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("tracksplitter_payload_\(UUID().uuidString).json")
        do {
            try jsonData.write(to: tempFile)
        } catch {
            throw EmbedError.tempFileFailed
        }

        defer { try? FileManager.default.removeItem(at: tempFile) }

        let (stdout, stderr, rc) = try await runScript(jsonFile: tempFile)

        let parsed = Self.parseOutput(stdout)

        if rc != 0 && parsed.succeeded == 0 && parsed.failed == 0 {
            return EmbedResult(
                total: files.count,
                succeeded: 0,
                failed: files.count,
                failures: ["脚本执行失败（RC=\(rc)）：\(stderr.prefix(100))"],
                coverWasSkipped: parsed.coverWasSkipped
            )
        }

        return EmbedResult(
            total: files.count,
            succeeded: parsed.succeeded,
            failed: parsed.failed,
            failures: parsed.failures,
            coverWasSkipped: parsed.coverWasSkipped
        )
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
                throw EmbedError.scriptFailed("Python script timed out after \(Int(timeoutSeconds ?? 0))s")
            }
            throw error
        } catch {
            throw error
        }
    }
}
