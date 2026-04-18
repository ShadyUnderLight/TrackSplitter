import Foundation

/// Main orchestration engine for the TrackSplitter library.
public actor TrackSplitterEngine {

    public enum EngineError: Error, LocalizedError {
        case noCueFile(URL)
        case emptyTracks
        case outputDirCreationFailed
        case splittingFailed(String)
        case splittingCancelled
        case cueFileMismatch(cueDeclaredFile: String, actualAudioFile: String)

        public var errorDescription: String? {
            switch self {
            case .noCueFile(let url): return "No .cue file found for \(url.lastPathComponent)"
            case .emptyTracks: return "CUE file contains no tracks"
            case .outputDirCreationFailed: return "Failed to create output directory"
            case .splittingFailed(let msg): return "Splitting failed: \(msg)"
            case .splittingCancelled: return "Splitting was cancelled"
            case .cueFileMismatch(let cueDeclaredFile, let actualAudioFile):
                return "CUE FILE field mismatch: CUE declares \"\(cueDeclaredFile)\" but input is \"\(actualAudioFile)\". Please ensure the FILE field in the CUE matches the actual audio file."
            }
        }
    }

    /// Explicit outcome model for the entire process.
    /// Distinguishes complete success, partial success (split succeeded but metadata partially/fully failed),
    /// and complete failure (nothing usable was produced).
    public enum EngineOutcome: Sendable {
        public enum Status: String, Sendable {
            case success          /// Split and metadata all succeeded.
            case partialSuccess   /// Split succeeded; metadata partially or fully failed; usable files exist on disk.
            case failure          /// Nothing usable was produced (pre-split failure, or split itself failed).
        }

        case success(Output)
        case partialSuccess(Output, metadataFailures: [String])
        case failure(message: String)

        public var status: Status {
            switch self {
            case .success:        return .success
            case .partialSuccess: return .partialSuccess
            case .failure:        return .failure
            }
        }

        /// The output directory and file list, if any split files exist.
        public var output: Output? {
            switch self {
            case .success(let o):              return o
            case .partialSuccess(let o, _):     return o
            case .failure:                     return nil
            }
        }

        /// Human-readable summary message.
        public var summary: String {
            switch self {
            case .success(let o):
                return "成功：\(o.trackFiles.count) 个曲目已输出到 \(o.outputDirectory.lastPathComponent)"
            case .partialSuccess(let o, let metaFails):
                let metaMsg = metaFails.isEmpty
                    ? "元数据写入全部失败"
                    : "元数据写入失败：\(metaFails.count) 个曲目"
                return "部分成功：\(o.trackFiles.count) 个音频文件已输出（\(metaMsg)）"
            case .failure(let msg):
                return "失败：\(msg)"
            }
        }
    }

    /// The substantive output of a process run — always tied to at least one track file existing.
    public struct Output: Sendable {
        public let outputDirectory: URL
        public let trackFiles: [URL]
        public let albumTitle: String?
        public let performer: String?
        /// Whether cover art was successfully fetched and embedded.
        public let coverEmbedded: Bool
        /// Per-track metadata embedding result.
        public let metadataResult: EmbedResult

        public init(outputDirectory: URL, trackFiles: [URL], albumTitle: String?, performer: String?,
                    coverEmbedded: Bool, metadataResult: EmbedResult) {
            self.outputDirectory = outputDirectory
            self.trackFiles = trackFiles
            self.albumTitle = albumTitle
            self.performer = performer
            self.coverEmbedded = coverEmbedded
            self.metadataResult = metadataResult
        }
    }

    /// Legacy result struct — retained for API compatibility with existing callers.
    /// Internally `process()` now returns `EngineOutcome`; this is constructed from `outcome.output`.
    public struct Result: Sendable {
        public let outputDirectory: URL
        public let trackFiles: [URL]
        public let albumTitle: String?
        public let performer: String?
        public let coverEmbedded: Bool
        public let metadataResult: EmbedResult

        public init(outputDirectory: URL, trackFiles: [URL], albumTitle: String?, performer: String?,
                    coverEmbedded: Bool, metadataResult: EmbedResult) {
            self.outputDirectory = outputDirectory
            self.trackFiles = trackFiles
            self.albumTitle = albumTitle
            self.performer = performer
            self.coverEmbedded = coverEmbedded
            self.metadataResult = metadataResult
        }

        @available(*, deprecated, message: "Use process() → EngineOutcome instead")
        public init(from outcome: EngineOutcome) throws {
            guard let out = outcome.output else {
                throw EngineError.splittingFailed("No output produced")
            }
            self.outputDirectory = out.outputDirectory
            self.trackFiles = out.trackFiles
            self.albumTitle = out.albumTitle
            self.performer = out.performer
            self.coverEmbedded = out.coverEmbedded
            self.metadataResult = out.metadataResult
        }
    }

    public struct LogHandler: @unchecked Sendable {
        public let callback: @Sendable (String) -> Void
        public init(callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
        public func log(_ msg: String) { callback(msg) }
    }

    private let splitter = AudioSplitter()
    private let fetcher  = AlbumArtFetcher()
    private let embedder = MetadataEmbedder()
    private let logHandler: LogHandler?
    /// NonisolatedUnsafe to allow cross-thread cancellation (e.g. MainActor cancel button).
    private nonisolated(unsafe) var _isCancelled = false
    /// Holds the output of the most recent `process()` call, so `cleanup()` knows what to delete.
    private var _lastOutput: Output?

    public init(logHandler: LogHandler? = nil) {
        self.logHandler = logHandler
    }

    /// Set the cancellation flag. Safe to call from any thread/task.
    /// The engine will throw `splittingCancelled` at the next cancellation check point.
    public nonisolated func cancel() {
        _isCancelled = true
    }

    /// Returns true if `cancel()` has been called since the last `process()` call.
    public func isCancelled() -> Bool {
        return _isCancelled
    }

    private func log(_ msg: String) {
        logHandler?.log(msg)
    }

    /// Delete the output files and directory from the last `process()` run.
    /// Call this when the caller chooses not to keep a partial-success result.
    public func cleanup() {
        guard let out = _lastOutput else { return }
        Self.cleanup(output: out)
        _lastOutput = nil
    }

    /// Delete the given output's track files and output directory.
    /// Exposed as a static method so callers who already hold an `Output` can clean up
    /// without going through the engine instance.
    public static func cleanup(output: Output) {
        for file in output.trackFiles {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: output.outputDirectory)
    }

    /// Process an audio file + CUE sheet and produce individual track files with metadata.
    ///
    /// Returns `EngineOutcome` — use `.status` to distinguish:
    /// - `.success`: everything worked
    /// - `.partialSuccess`: split files exist, metadata partially/fully failed — caller decides whether to `cleanup()`
    /// - `.failure`: nothing usable was produced (pre-split error, or split itself failed)
    ///
    /// - Parameters:
    ///   - inputURL: Source audio file
    ///   - outputFormat: Desired output format. nil = same as input (passthrough, no re-encode).
    ///     `.flac` = re-encode to FLAC (lossless, smaller file).
    ///     `.wav` = re-encode to WAV (lossless PCM, larger file).
    public func process(
        inputURL: URL,
        outputFormat: AudioSplitter.AudioFormat? = nil,
        chapterSource: ChapterSource? = nil
    ) async -> EngineOutcome {
        _isCancelled = false  // Reset cancellation for each new process run
        log("📂 Input: \(inputURL.lastPathComponent)")

        // ─── Resolve chapter source ───────────────────────────────────────────────
        typealias ChapterResult = ([CueTrack], String?, String?, CueFile?, CueRem, String)

        func resolve(source: ChapterSource?) async throws -> ChapterResult {
            if let src = source {
                switch src {
                case .cue(let url):
                    log("📋 Chapter source: CUE (\(url.lastPathComponent))")
                    let (t, at, p, cf, cr) = try parseCue(at: url)
                    return (t, at, p, cf, cr, "CUE")

                case .textChapters(let url):
                    log("📋 Chapter source: text chapters (\(url.lastPathComponent))")
                    let entries = try TextChapterParser().parse(at: url)
                    let t = entries.enumerated().map { i, e in
                        CueTrack(index: i + 1, title: e.title,
                                  startSeconds: e.startSeconds, endSeconds: nil)
                    }
                    return (t, nil, nil, nil, CueRem(), "text chapters")

                case .ffmpegChapters(let url):
                    log("📋 Chapter source: FFmpeg chapters (\(url.lastPathComponent))")
                    let entries = try FFmpegChapterParser().parse(at: url)
                    let t = entries.enumerated().map { i, e in
                        CueTrack(index: i + 1, title: e.title,
                                  startSeconds: e.startSeconds, endSeconds: nil)
                    }
                    return (t, nil, nil, nil, CueRem(), "FFmpeg chapters")

                case .embedded(let url):
                    log("📋 Chapter source: embedded (\(url.lastPathComponent))")
                    let entries = try await EmbeddedChapterReader().read(from: url)
                    let t = entries.enumerated().map { i, e in
                        CueTrack(index: i + 1, title: e.title,
                                  startSeconds: e.startSeconds, endSeconds: nil)
                    }
                    return (t, nil, nil, nil, CueRem(), "embedded")
                }
            }

            // No source provided: auto-detect CUE
            guard let cueURL = findCue(for: inputURL) else {
                return ([], nil, nil, nil, CueRem(), "none")
            }
            log("📋 Chapter source: auto-detected CUE (\(cueURL.lastPathComponent))")
            let (t, at, p, cf, cr) = try parseCue(at: cueURL)
            return (t, at, p, cf, cr, "CUE")
        }

        // ─── Execute resolve and handle result ────────────────────────────────────
        var tracks: [CueTrack]          = []
        var albumTitle: String?           = nil
        var performer: String?            = nil
        var cueFile: CueFile?             = nil
        var cueRem: CueRem                = CueRem()
        var sourceLabel: String           = "unknown"

        let result: ChapterResult
        do {
            result = try await resolve(source: chapterSource)
        } catch {
            return .failure(message: "Chapter parse error: \(error.localizedDescription)")
        }
        (tracks, albumTitle, performer, cueFile, cueRem, sourceLabel) = result

        if sourceLabel == "none" && tracks.isEmpty {
            return .failure(message: EngineError.noCueFile(inputURL).localizedDescription)
        }

        guard !tracks.isEmpty else {
            return .failure(message: EngineError.emptyTracks.localizedDescription)
        }

        log("🎵 Tracks: \(tracks.count) | Source: \(sourceLabel)")
        if sourceLabel == "CUE" {
            log("🎵 Album: \(albumTitle ?? "—") | Artist: \(performer ?? "—")")
            log("📋 REM: date=\(cueRem.date ?? "—") genre=\(cueRem.genre ?? "—") comment=\(cueRem.comment ?? "—") composer=\(cueRem.composer ?? "—") discNumber=\(cueRem.discNumber ?? "—")")
        }

        // Cue FILE field validation (CUE path only)
        if sourceLabel == "CUE", let cf = cueFile {
            let cueDeclaredName = cf.resolvedURL.lastPathComponent
            let similarity = stringSimilarity(cueDeclaredName, inputURL.lastPathComponent)
            if similarity < 0.80 {
                let msg = EngineError.cueFileMismatch(cueDeclaredFile: cf.path, actualAudioFile: inputURL.lastPathComponent).localizedDescription
                log("⚠️  \(msg)")
                return .failure(message: msg)
            } else {
                log("📋 CUE FILE field similarity: \(String(format: "%.0f", similarity * 100))% — fuzzy-matched (encoding may differ)")
            }
        }

        // 2. Pre-flight environment check// 2. Pre-flight environment check — after input validation, before any file system operations// 2. Pre-flight environment check — after input validation, before any file system operations
        let envReport = await embedder.checkEnvironment()
        if !envReport.isHealthy {
            let issues = envReport.issues
            let firstIssue = issues.first!
            log("❌ Environment check failed: \(firstIssue.summary)")
            for issue in issues {
                log("   → \(issue.remediation)")
            }
            return .failure(message: "Environment check failed: \(firstIssue.summary)")
        }
        if let ver = envReport.pythonVersion {
            log("🐍 Python \(ver) + mutagen OK | script: \(envReport.scriptPath ?? "unknown")")
        }

        // 3. Create output directory (use sanitized name to avoid filesystem issues)
        let albumDisplayName = albumTitle ?? inputURL.deletingPathExtension().lastPathComponent
        let albumSafeName = splitter.sanitizeDirectoryName(albumDisplayName)
        let parentDir = inputURL.deletingLastPathComponent()
        let outDir = splitter.resolveUniqueOutputDirectory(baseDir: parentDir, safeName: albumSafeName)

        if albumDisplayName != albumSafeName {
            log("🗂  Album display name: \"\(albumDisplayName)\" → filesystem: \"\(outDir.lastPathComponent)\"")
        }

        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            return .failure(message: EngineError.outputDirCreationFailed.localizedDescription)
        }
        log("📁 Output dir: \(outDir.path)")

        // 4. Fetch cover art (non-fatal)
        var coverData: Data? = nil
        do {
            log("🖼  Fetching album cover...")
            coverData = try await fetcher.fetch(artist: performer, album: albumTitle ?? albumDisplayName, inputFile: inputURL)
            log("✅  Cover art: \(coverData.map { "\($0.count) bytes" } ?? "none")")
        } catch {
            log("⚠️  Cover fetch failed (continuing without cover): \(error.localizedDescription)")
        }

        // 5. Split audio — split failure is always fatal (nothing on disk)
        log("✂️  Starting split with ffmpeg...")
        var splitTracks: [URL] = []
        do {
            splitTracks = try await splitter.split(
                file: inputURL,
                tracks: tracks,
                to: outDir,
                outputFormat: outputFormat
            ) { [weak self] progress in
                guard let self else { return }
                let message = "  Splitting track \(progress.track)/\(progress.total): \(progress.trackTitle)..."
                Task { await self.log(message) }
            } isCancelled: { [weak self] in
                self?._isCancelled == true
            }
            log("✅  Split complete: \(splitTracks.count) files")
        } catch let error as AudioSplitter.SplitError {
            let msg = error.localizedDescription.contains("Cancelled")
                ? EngineError.splittingCancelled.localizedDescription
                : EngineError.splittingFailed(error.localizedDescription).localizedDescription
            for file in splitTracks { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: outDir)
            return .failure(message: msg)
        } catch {
            for file in splitTracks { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: outDir)
            return .failure(message: EngineError.splittingFailed(error.localizedDescription).localizedDescription)
        }

        // 6. Embed metadata — partial metadata failure is now partialSuccess, not fatal
        log("🏷  Embedding metadata...")
        let metadataResult: EmbedResult
        do {
            metadataResult = try await embedder.embedBatch(
                files: zip(splitTracks, tracks).map { (url: $0.0, title: $0.1.title, trackNumber: $0.1.index) },
                artist: performer ?? "Unknown Artist",
                album: albumTitle ?? albumDisplayName,
                year: cueRem.date ?? "",
                genre: cueRem.genre ?? "",
                comment: cueRem.comment,
                composer: cueRem.composer,
                discNumber: cueRem.discNumber,
                totalTracks: tracks.count,
                coverData: coverData
            )
        } catch {
            // Metadata script crashed — treat as partial success with no metadata written
            log("⚠️  Metadata embedding threw (treating as partial success): \(error.localizedDescription)")
            metadataResult = EmbedResult(
                total: splitTracks.count,
                succeeded: 0,
                failed: splitTracks.count,
                failures: [error.localizedDescription],
                coverWasSkipped: false
            )
        }

        if metadataResult.isFullySuccessful {
            log("✅  Metadata embedded for all \(metadataResult.succeeded) tracks")
        } else if metadataResult.isPartiallySuccessful {
            log("⚠️  Metadata partially embedded: \(metadataResult.succeeded)/\(metadataResult.total) succeeded, \(metadataResult.failed) failed")
        } else {
            log("⚠️  Metadata embedding failed for all \(metadataResult.failed) tracks — returning partialSuccess with split files intact")
        }

        let output = Output(
            outputDirectory: outDir,
            trackFiles: splitTracks,
            albumTitle: albumTitle,
            performer: performer,
            coverEmbedded: coverData != nil && !metadataResult.coverWasSkipped,
            metadataResult: metadataResult
        )
        _lastOutput = output

        if metadataResult.isFullySuccessful {
            return .success(output)
        } else {
            return .partialSuccess(output, metadataFailures: metadataResult.failures)
        }
    }
}
