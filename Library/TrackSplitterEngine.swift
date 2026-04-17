import Foundation

/// Main orchestration engine for the TrackSplitter library.
public actor TrackSplitterEngine {

    public enum EngineError: Error, LocalizedError {
        case noCueFile(URL)
        case emptyTracks
        case outputDirCreationFailed
        case splittingFailed(String)
        case splittingCancelled
        case metadataFailed(String)
        case cueFileMismatch(cueDeclaredFile: String, actualAudioFile: String)

        public var errorDescription: String? {
            switch self {
            case .noCueFile(let url): return "No .cue file found for \(url.lastPathComponent)"
            case .emptyTracks: return "CUE file contains no tracks"
            case .outputDirCreationFailed: return "Failed to create output directory"
            case .splittingFailed(let msg): return "Splitting failed: \(msg)"
            case .splittingCancelled: return "Splitting was cancelled"
            case .metadataFailed(let msg): return "Metadata embedding failed: \(msg)"
            case .cueFileMismatch(let cueDeclaredFile, let actualAudioFile):
                return "CUE FILE field mismatch: CUE declares \"\(cueDeclaredFile)\" but input is \"\(actualAudioFile)\". Please ensure the FILE field in the CUE matches the actual audio file."
            }
        }
    }

    public struct Result: Sendable {
        public let outputDirectory: URL
        public let trackFiles: [URL]
        public let albumTitle: String?
        public let performer: String?
        /// Whether cover art was successfully fetched and embedded.
        public let coverEmbedded: Bool
        /// Per-track metadata embedding result.
        public let metadataResult: MetadataEmbedder.EmbedResult
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

    /// Process an audio file + CUE sheet and produce individual track files with metadata.
    /// - Parameters:
    ///   - inputURL: Source audio file
    ///   - outputFormat: Desired output format. nil = same as input (passthrough, no re-encode).
    ///     `.flac` = re-encode to FLAC (lossless, smaller file).
    ///     `.wav` = re-encode to WAV (lossless PCM, larger file).
    public func process(inputURL: URL, outputFormat: AudioSplitter.AudioFormat? = nil) async throws -> Result {
        _isCancelled = false  // Reset cancellation for each new process run
        log("📂 Input: \(inputURL.lastPathComponent)")

        // 1. Find CUE — scan all .cue files in the same directory and validate via FILE field
        guard let cueURL = findCue(for: inputURL) else {
            throw EngineError.noCueFile(inputURL)
        }
        log("📋 CUE found: \(cueURL.lastPathComponent)")

        // 2. Parse CUE (handles Chinese encodings via Big5/CP950 detection)
        let (tracks, albumTitle, performer, cueFile, cueRem) = try parseCue(at: cueURL)
        log("🎵 Tracks: \(tracks.count) | Album: \(albumTitle ?? "—") | Artist: \(performer ?? "—")")
        log("📋 REM: date=\(cueRem.date ?? "—") genre=\(cueRem.genre ?? "—") comment=\(cueRem.comment ?? "—") composer=\(cueRem.composer ?? "—") discNumber=\(cueRem.discNumber ?? "—")")

        // 2b. Validate FILE field if present — use fuzzy match to handle encoding mismatches
        if let cf = cueFile {
            let cueDeclaredName = cf.resolvedURL.lastPathComponent
            let similarity = stringSimilarity(cueDeclaredName, inputURL.lastPathComponent)
            if similarity < 0.80 {
                log("⚠️  CUE FILE mismatch — CUE: \"\(cf.path)\", actual: \"\(inputURL.lastPathComponent)\" (similarity: \(String(format: "%.0f", similarity * 100))%)")
                throw EngineError.cueFileMismatch(cueDeclaredFile: cf.path, actualAudioFile: inputURL.lastPathComponent)
            } else {
                log("📋 CUE FILE field similarity: \(String(format: "%.0f", similarity * 100))% — fuzzy-matched (encoding may differ)")
            }
        }

        guard !tracks.isEmpty else { throw EngineError.emptyTracks }

        // 3. Create output directory (use sanitized name to avoid filesystem issues)
        let albumDisplayName = albumTitle ?? inputURL.deletingPathExtension().lastPathComponent
        let albumSafeName = splitter.sanitizeDirectoryName(albumDisplayName)
        let parentDir = inputURL.deletingLastPathComponent()
        let outDir = splitter.resolveUniqueOutputDirectory(baseDir: parentDir, safeName: albumSafeName)

        // Report actual directory used if it diverges from display name
        if albumDisplayName != albumSafeName {
            log("🗂  Album display name: \"\(albumDisplayName)\" → filesystem: \"\(outDir.lastPathComponent)\"")
        }

        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            throw EngineError.outputDirCreationFailed
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

        // 5. Split audio
        log("✂️  Starting split with ffmpeg...")
        let splitTracks: [URL]
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
            if error.localizedDescription.contains("Cancelled") {
                throw EngineError.splittingCancelled
            }
            throw EngineError.splittingFailed(error.localizedDescription)
        } catch {
            throw EngineError.splittingFailed(error.localizedDescription)
        }

        // 6. Embed metadata (fatal on failure)
        let metadataResult: MetadataEmbedder.EmbedResult
        log("🏷  Embedding metadata...")
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
            if metadataResult.isFullySuccessful {
                log("✅  Metadata embedded for all \(metadataResult.succeeded) tracks")
            } else if metadataResult.isPartiallySuccessful {
                log("⚠️  Metadata partially embedded: \(metadataResult.succeeded)/\(metadataResult.total) succeeded, \(metadataResult.failed) failed")
            } else {
                log("❌  Metadata embedding failed for all \(metadataResult.failed) tracks")
                throw EngineError.metadataFailed(
                    metadataResult.failures.joined(separator: "; ")
                )
            }
        } catch {
            log("❌  Metadata embedding failed: \(error.localizedDescription)")
            throw EngineError.metadataFailed(error.localizedDescription)
        }

        return Result(outputDirectory: outDir, trackFiles: splitTracks,
                      albumTitle: albumTitle, performer: performer,
                      coverEmbedded: coverData != nil && !metadataResult.coverWasSkipped,
                      metadataResult: metadataResult)
    }
}
