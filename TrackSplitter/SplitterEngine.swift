import AppKit
import Foundation

@MainActor
final class SplitterEngine: ObservableObject {
    @Published var log: [String] = []
    @Published var isProcessing = false
    @Published var finishedTracks: [String] = []
    @Published var outputDir: URL?

    private let cueParser = CueParser()
    private let albumArtFetcher = AlbumArtFetcher()
    private let fileManager = FileManager.default

    func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("[\(formatter.string(from: Date()))] \(line)")
    }

    func process(flacURL: URL) async throws -> URL {
        guard !isProcessing else { throw TrackSplitterError.processFailed("Processing is already running.") }
        guard flacURL.pathExtension.lowercased() == "flac" else { throw TrackSplitterError.invalidDrop }

        let cueURL = flacURL.deletingPathExtension().appendingPathExtension("cue")
        guard fileManager.fileExists(atPath: cueURL.path) else { throw TrackSplitterError.missingCue(cueURL) }

        isProcessing = true
        log.removeAll()
        finishedTracks.removeAll()
        outputDir = nil
        defer { isProcessing = false }

        appendLog("Found FLAC: \(flacURL.lastPathComponent)")
        appendLog("Found CUE: \(cueURL.lastPathComponent)")

        let cue = try cueParser.parse(cueURL: cueURL)
        appendLog("Parsed album: \(cue.albumTitle)")
        appendLog("Parsed \(cue.tracks.count) tracks from the CUE sheet")

        let outputDirectory = try makeOutputDirectory(nextTo: flacURL, albumTitle: cue.albumTitle)
        outputDir = outputDirectory
        appendLog("Output directory: \(outputDirectory.path)")

        let totalDuration = try await audioDuration(for: flacURL)
        appendLog(String(format: "Total source duration: %.2f seconds", totalDuration))

        let coverData = await fetchCoverData(for: cue)

        var metadataItems: [[String: String]] = []
        for (offset, track) in cue.tracks.enumerated() {
            let end = track.endSeconds ?? totalDuration
            let duration = max(0, end - track.startSeconds)
            let outputName = String(format: "%02d", track.index) + " - " + safeFilename(track.title) + ".flac"
            let outputURL = outputDirectory.appendingPathComponent(outputName)

            appendLog("Splitting track \(track.index): \(track.title)")
            _ = try await runFFmpeg(args: [
                "-y",
                "-i", flacURL.path,
                "-ss", timeString(track.startSeconds),
                "-t", timeString(duration),
                "-acodec", "flac",
                outputURL.path
            ])

            finishedTracks.append(outputURL.lastPathComponent)
            metadataItems.append([
                "path": outputURL.path,
                "title": track.title,
                "artist": cue.artist,
                "album": cue.albumTitle,
                "year": cue.year,
                "genre": cue.genre,
                "tracknum": String(track.index),
                "total": String(cue.tracks.count)
            ])
            appendLog("Created \(outputURL.lastPathComponent)")

            if offset == cue.tracks.count - 1 {
                appendLog("Audio splitting complete")
            }
        }

        try await embedMetadata(files: metadataItems, coverData: coverData)
        appendLog("Metadata embedding complete")
        return outputDirectory
    }

    private func makeOutputDirectory(nextTo flacURL: URL, albumTitle: String) throws -> URL {
        let folder = flacURL.deletingLastPathComponent().appendingPathComponent(safeFilename(albumTitle), isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private func audioDuration(for flacURL: URL) async throws -> Double {
        guard let ffprobe = ExecutableLocator.find("ffprobe") else {
            throw TrackSplitterError.executableNotFound("ffprobe")
        }
        let output = try await runProcess(program: ffprobe, args: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            flacURL.path
        ])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Double(trimmed) else {
            throw TrackSplitterError.processFailed("Unable to parse ffprobe output: \(trimmed)")
        }
        return duration
    }

    private func fetchCoverData(for cue: CueSheet) async -> Data? {
        let pageURL = cue.pageURL ?? "https://www.leftfm.com/music/\(cue.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cue.artist)/\(cue.albumTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cue.albumTitle)"
        appendLog("Looking for album art on leftfm.com")
        let data = await albumArtFetcher.fetchAlbumArt(from: pageURL, albumName: cue.albumTitle, logger: { message in
            self.appendLog(message)
        })
        if data != nil {
            appendLog("Album art downloaded")
        } else {
            appendLog("Continuing without album art")
        }
        return data
    }

    private func embedMetadata(files: [[String: String]], coverData: Data?) async throws {
        let scriptPath = Bundle.main.path(forResource: "embed_metadata", ofType: "py")
        guard let scriptPath else {
            throw TrackSplitterError.resourceMissing("embed_metadata.py")
        }
        guard let python = ExecutableLocator.find("python3") else {
            throw TrackSplitterError.executableNotFound("python3")
        }

        let payload: [String: Any] = [
            "files": files,
            "coverData": coverData?.base64EncodedString() as Any
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw TrackSplitterError.processFailed("Failed to serialize metadata payload")
        }

        appendLog("Embedding metadata via Python/mutagen")
        _ = try await runProcess(program: python, args: [scriptPath, json])
    }

    private func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Album" : cleaned
    }

    private func timeString(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private func runFFmpeg(args: [String]) async throws -> String {
        guard let ffmpeg = ExecutableLocator.find("ffmpeg") else {
            throw TrackSplitterError.executableNotFound("ffmpeg")
        }
        return try await runProcess(program: ffmpeg, args: args)
    }

    private func runProcess(program: URL, args: [String]) async throws -> String {
        appendLog("Running \(program.lastPathComponent) \(args.prefix(4).joined(separator: " "))…")
        return try await ProcessRunner.run(program: program, args: args, logLine: { line in
            if program.lastPathComponent == "ffmpeg" || program.lastPathComponent == "ffprobe" {
                return
            }
            self.appendLog(line)
        })
    }
}
