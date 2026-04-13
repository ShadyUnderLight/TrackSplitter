import Foundation

/// Main orchestration engine for the TrackSplitter library.
public actor TrackSplitterEngine {

    public enum EngineError: Error, LocalizedError {
        case noCueFile(URL)
        case emptyTracks
        case outputDirCreationFailed
        case splittingFailed(String)
        case metadataFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noCueFile(let url): return "No .cue file found for \(url.lastPathComponent)"
            case .emptyTracks: return "CUE file contains no tracks"
            case .outputDirCreationFailed: return "Failed to create output directory"
            case .splittingFailed(let msg): return "Splitting failed: \(msg)"
            case .metadataFailed(let msg): return "Metadata embedding failed: \(msg)"
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

    private let splitter = FLACSplitter()
    private let fetcher  = AlbumArtFetcher()
    private let embedder = MetadataEmbedder()
    private let logHandler: LogHandler?

    public init(logHandler: LogHandler? = nil) {
        self.logHandler = logHandler
    }

    private func log(_ msg: String) {
        logHandler?.log(msg)
    }

    /// Process a FLAC+CUE pair and produce individual track FLAC files with metadata.
    public func process(flacURL: URL) async throws -> Result {
        log("📂 Input: \(flacURL.lastPathComponent)")

        // 1. Find CUE
        guard let cueURL = findCue(for: flacURL) else {
            throw EngineError.noCueFile(flacURL)
        }
        log("📋 CUE found: \(cueURL.lastPathComponent)")

        // 2. Parse CUE (handles Chinese encodings via Big5/CP950 detection)
        let (tracks, albumTitle, performer) = try parseCue(at: cueURL)
        log("🎵 Tracks: \(tracks.count) | Album: \(albumTitle ?? "—") | Artist: \(performer ?? "—")")

        guard !tracks.isEmpty else { throw EngineError.emptyTracks }

        // 3. Create output directory
        let albumDirName = albumTitle ?? flacURL.deletingPathExtension().lastPathComponent
        let outDir = flacURL.deletingLastPathComponent().appendingPathComponent(albumDirName)
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
            coverData = try await fetcher.fetch(artist: performer, album: albumTitle ?? albumDirName)
            log("✅  Cover art: \(coverData.map { "\($0.count) bytes" } ?? "none")")
        } catch {
            log("⚠️  Cover fetch failed (continuing without cover): \(error.localizedDescription)")
        }

        // 5. Split FLAC
        log("✂️  Starting split with ffmpeg...")
        let splitTracks: [URL]
        do {
            splitTracks = try await splitter.split(
                file: flacURL,
                tracks: tracks,
                to: outDir
            ) { [weak self] progress in
                Task { await self?.log("  Splitting track \(progress.track)/\(progress.total): \(progress.trackTitle)...") }
            }
            log("✅  Split complete: \(splitTracks.count) files")
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
                album: albumTitle ?? albumDirName,
                year: "1992",
                genre: "流行",
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
                      coverEmbedded: coverData != nil,
                      metadataResult: metadataResult)
    }
}
