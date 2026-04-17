import Foundation

/// Runs ffmpeg to split an audio file into individual tracks.
/// Supports any format ffmpeg can read: FLAC, MP3, WAV, AIFF, ALAC, AAC, OGG, etc.
public actor AudioSplitter {

    public enum SplitError: Error, LocalizedError {
        case ffprobeFailed(String)
        case ffmpegFailed(String, Int32)
        case noDuration
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case .ffprobeFailed(let msg): return "ffprobe error: \(msg)"
            case .ffmpegFailed(let msg, let code): return "ffmpeg exited with \(code): \(msg)"
            case .noDuration: return "Could not determine total file duration"
            case .unsupportedFormat(let ext): return "Unsupported file format: \(ext)"
            }
        }
    }

    /// Supported input audio formats.
    public enum AudioFormat: String, CaseIterable, Sendable {
        case flac = "flac"
        case mp3  = "mp3"
        case wav  = "wav"
        case aiff = "aiff"
        case alac = "alac"
        case m4a  = "m4a"
        case aac  = "aac"
        case ogg  = "ogg"
        case opus = "opus"

        public var isSupported: Bool {
            // All formats listed here are natively supported by ffmpeg.
            true
        }

        /// Infer format from file extension.
        public static func fromExtension(_ ext: String) -> AudioFormat? {
            let lower = ext.lowercased()
            return Self.allCases.first { $0.rawValue == lower }
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

    /// - Parameters:
    ///   - ffmpegPath: Optional override for the ffmpeg binary path (useful for testing).
    ///   - ffprobePath: Optional override for the ffprobe binary path (useful for testing).
    public init(ffmpegPath: String? = nil, ffprobePath: String? = nil) {
        self.ffmpegPath = ffmpegPath ?? Self.findBinary("ffmpeg") ?? "/usr/local/bin/ffmpeg"
        self.ffprobePath = ffprobePath ?? Self.findBinary("ffprobe") ?? "/usr/local/bin/ffprobe"
    }

    private static func findBinary(_ name: String) -> String? {
        let homebrewPaths = [
            "/opt/homebrew/bin/\(name)",
            "/opt/homebrew/bin/\(name)3",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return ProcessInfo.processInfo.environment["PATH"]?
            .components(separatedBy: ":")
            .compactMap { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func getDuration(of url: URL) async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", url.path
            ]
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

    /// Split an audio file into tracks using ffmpeg.
    /// - Parameters:
    ///   - inputURL: Source audio file
    ///   - tracks: Cue track definitions
    ///   - outputDir: Destination directory
    ///   - outputFormat: Desired output format. nil = same as input (passthrough, no re-encode).
    ///     Pass `.flac` to re-encode any input to FLAC (lossless, smaller file).
    ///     Pass `.wav` to re-encode to WAV (lossless PCM, larger file).
    public func split(
        file inputURL: URL,
        tracks: [CueTrack],
        to outputDir: URL,
        outputFormat: AudioFormat? = nil,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> [URL] {
        let inputExt = inputURL.pathExtension.lowercased()
        guard AudioFormat.fromExtension(inputExt) != nil else {
            throw SplitError.unsupportedFormat(inputExt)
        }

        // Determine output extension
        let outExt: String
        let acodecArg: [String]
        if let fmt = outputFormat {
            outExt = fmt.rawValue
            switch fmt {
            case .flac:
                acodecArg = ["-acodec", "flac"]
            case .wav:
                acodecArg = ["-acodec", "pcm_s16le"]
            case .mp3:
                acodecArg = ["-acodec", "libmp3lame"]
            case .alac:
                acodecArg = ["-acodec", "alac"]
            default:
                acodecArg = ["-acodec", "copy"]
            }
        } else {
            outExt = inputExt
            acodecArg = ["-acodec", "copy"]
        }

        let totalDuration = try await getDuration(of: inputURL)

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
            let outURL = outputDir.appendingPathComponent("\(track.index). \(safe).\(outExt)")

            let progress = Progress(track: track.index, total: filled.count,
                                    trackTitle: track.title, secondsProcessed: track.startSeconds)
            Task { @Sendable in progressHandler(progress) }

            // runFFmpeg returns the actual URL written (may differ if passthrough fell back to WAV)
            let actualURL = try await runFFmpeg(input: inputURL, start: track.startSeconds,
                                duration: duration, output: outURL, acodecArgs: acodecArg)
            outputs.append(actualURL)
        }

        return outputs
    }

    /// Runs ffmpeg and returns the actual URL that was written.
    /// If passthrough fails, falls back to PCM WAV — extension stays .wav to match actual codec.
    private func runFFmpeg(input: URL, start: Double, duration: Double,
                           output: URL, acodecArgs: [String]) async throws -> URL {
        let isPassthrough = acodecArgs.first == "-acodec" && acodecArgs.last == "copy"

        if isPassthrough {
            // Try stream copy first (no re-encode)
            do {
                try await runFFmpegOnce(input: input, start: start, duration: duration,
                                        output: output, extraArgs: acodecArgs)
                return output
            } catch {
                // Stream copy failed — fall back to PCM WAV.
                // Extension stays .wav to match actual codec; no rename back to original ext.
                try? FileManager.default.removeItem(at: output)
                let fallbackURL = output.deletingPathExtension().appendingPathExtension("wav")
                try await runFFmpegOnce(input: input, start: start, duration: duration,
                                        output: fallbackURL, extraArgs: ["-acodec", "pcm_s16le"])
                return fallbackURL
            }
        } else {
            // Explicit codec requested (FLAC/WAV/MP3 etc.) — no stream copy fallback
            try await runFFmpegOnce(input: input, start: start, duration: duration,
                                    output: output, extraArgs: acodecArgs)
            return output
        }
    }

    /// Run ffmpeg once with given arguments; throws on failure.
    private func runFFmpegOnce(input: URL, start: Double, duration: Double,
                               output: URL, extraArgs: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-y", "-i", input.path,
                "-ss", String(format: "%.3f", start),
                "-t",  String(format: "%.3f", duration)
            ] + extraArgs + [output.path]
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
        let invalid = CharacterSet(charactersIn: "<>:\"/'\\|?*")
        return name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }
}
