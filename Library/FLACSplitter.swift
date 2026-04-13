import Foundation

/// Runs ffmpeg to split a FLAC file into individual tracks.
public actor FLACSplitter {

    public enum SplitError: Error, LocalizedError {
        case ffprobeFailed(String)
        case ffmpegFailed(String, Int32)
        case noDuration

        public var errorDescription: String? {
            switch self {
            case .ffprobeFailed(let msg): return "ffprobe error: \(msg)"
            case .ffmpegFailed(let msg, let code): return "ffmpeg exited with \(code): \(msg)"
            case .noDuration: return "Could not determine total file duration"
            }
        }
    }

    public struct Progress: Sendable {
        public let track: Int
        public let total: Int
        public let trackTitle: String
        public let secondsProcessed: Double
    }

    private let ffmpegPath: String
    private let ffprobePath: String

    public init() {
        self.ffmpegPath = Self.findBinary("ffmpeg") ?? "/usr/local/bin/ffmpeg"
        self.ffprobePath = Self.findBinary("ffprobe") ?? "/usr/local/bin/ffprobe"
    }

    private static func findBinary(_ name: String) -> String? {
        // Hardcode homebrew paths first, then fall back to PATH lookup.
        // GUI apps started via Finder/NSOpenPanel don't inherit a full PATH.
        let homebrewPaths = [
            "/opt/homebrew/bin/\(name)",
            "/opt/homebrew/bin/\(name)3",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        // Try hardcoded paths first
        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fall back to PATH lookup
        return ProcessInfo.processInfo.environment["PATH"]?
            .components(separatedBy: ":")
            .compactMap { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func getDuration(of url: URL) async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = ["-v", "error", "-show_entries", "format=duration",
                                  "-of", "default=noprint_wrappers=1:nokey=1", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let d = Double(output) {
                    cont.resume(returning: d)
                } else {
                    cont.resume(throwing: SplitError.ffprobeFailed("Could not parse duration"))
                }
            } catch {
                cont.resume(throwing: SplitError.ffprobeFailed(error.localizedDescription))
            }
        }
    }

    public func split(
        file inputURL: URL,
        tracks: [CueTrack],
        to outputDir: URL,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> [URL] {
        let totalDuration = try await getDuration(of: inputURL)

        // Fill endSeconds for all tracks
        var filled = tracks
        for i in 0..<filled.count {
            if filled[i].endSeconds == nil {
                filled[i].endSeconds = i + 1 < filled.count ? filled[i + 1].startSeconds : totalDuration
            }
        }

        var outputs: [URL] = []

        for track in filled {
            let duration = track.endSeconds! - track.startSeconds
            let safe = sanitizeFilename(track.title.isEmpty ? "Track_\(track.index)" : track.title)
            let outURL = outputDir.appendingPathComponent("\(track.index). \(safe).flac")

            let progress = Progress(track: track.index, total: filled.count,
                                    trackTitle: track.title, secondsProcessed: track.startSeconds)
            Task { @Sendable in progressHandler(progress) }

            try await runFFmpeg(input: inputURL, start: track.startSeconds,
                                duration: duration, output: outURL)
            outputs.append(outURL)
        }

        return outputs
    }

    private func runFFmpeg(input: URL, start: Double, duration: Double, output: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-y", "-i", input.path,
                "-ss", String(format: "%.3f", start),
                "-t",  String(format: "%.3f", duration),
                "-acodec", "flac", "-compression_level", "8",
                output.path
            ]
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "exit \(process.terminationStatus)"
                    cont.resume(throwing: SplitError.ffmpegFailed(msg, process.terminationStatus))
                }
            } catch {
                cont.resume(throwing: SplitError.ffmpegFailed(error.localizedDescription, -1))
            }
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"'/\\|?*")
        return name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }
}
