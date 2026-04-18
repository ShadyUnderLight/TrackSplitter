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

    /// Policy for when an output file already exists.
    public enum OverwritePolicy: String, Sendable {
        case rename     // 重命名：已存在则加数字后缀（-1, -2, …）
        case overwrite  // 直接覆盖
        case skip       // 跳过（保留原文件，不调用 ffmpeg）
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
    /// Subprocess timeout in seconds. nil = no timeout.
    private let timeoutSeconds: Double?

    /// - Parameters:
    ///   - ffmpegPath: Optional override for the ffmpeg binary path (useful for testing).
    ///   - ffprobePath: Optional override for the ffprobe binary path (useful for testing).
    ///   - timeoutSeconds: Optional subprocess timeout. Defaults to 300s (5 min) for ffmpeg/ffprobe.
    public init(
        ffmpegPath: String? = nil,
        ffprobePath: String? = nil,
        timeoutSeconds: Double? = 300
    ) {
        self.ffmpegPath = ffmpegPath ?? Self.findBinary("ffmpeg") ?? "/usr/local/bin/ffmpeg"
        self.ffprobePath = ffprobePath ?? Self.findBinary("ffprobe") ?? "/usr/local/bin/ffprobe"
        self.timeoutSeconds = timeoutSeconds
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
        let runner = ProcessRunner(timeoutSeconds: timeoutSeconds)
        let stdout = try await runner.run(executable: ffprobePath, arguments: [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path
        ])
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(trimmed) else {
            throw SplitError.ffprobeFailed("Could not parse duration from: \(trimmed)")
        }
        return d
    }

    /// Split an audio file into tracks using ffmpeg.
    /// - Parameters:
    ///   - inputURL: Source audio file
    ///   - tracks: Cue track definitions
    ///   - outputDir: Destination directory
    ///   - outputFormat: Desired output format. nil = same as input (passthrough, no re-encode).
    ///     Pass `.flac` to re-encode any input to FLAC (lossless, smaller file).
    ///     Pass `.wav` to re-encode to WAV (lossless PCM, larger file).
    ///   - progressHandler: Called on each track start with current progress.
    ///   - isCancelled: Checked between tracks and during subprocess execution;
    ///     return true to abort. Defaults to always false.
    public func split(
        file inputURL: URL,
        tracks: [CueTrack],
        to outputDir: URL,
        outputFormat: AudioFormat? = nil,
        nameTemplate: String = "{index}. {title}.{ext}",
        albumTitle: String = "",
        artist: String = "",
        overwritePolicy: OverwritePolicy = .rename,
        progressHandler: @escaping @Sendable (Progress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool = { false }
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
            if isCancelled() {
                // Clean up any partial outputs already written before bailing out
                for url in outputs { try? FileManager.default.removeItem(at: url) }
                throw SplitError.ffmpegFailed("Cancelled by user", -999)
            }

            let duration = track.endSeconds! - track.startSeconds
            let rawName = applyNameTemplate(nameTemplate, track: track, albumTitle: albumTitle, artist: artist, ext: outExt)
            let outURL = resolveOutputURL(outputDir: outputDir, baseName: rawName, policy: overwritePolicy)

            // Handle skip: if file already exists, skip ffmpeg entirely
            if overwritePolicy == .skip && FileManager.default.fileExists(atPath: outURL.path) {
                outputs.append(outURL)
                continue
            }

            let progress = Progress(track: track.index, total: filled.count,
                                    trackTitle: track.title, secondsProcessed: track.startSeconds)
            Task { @Sendable in progressHandler(progress) }

            // runFFmpeg returns the actual URL written (may differ if passthrough fell back to WAV)
            let actualURL = try await runFFmpeg(input: inputURL, start: track.startSeconds,
                                duration: duration, output: outURL, acodecArgs: acodecArg,
                                overwritePolicy: overwritePolicy,
                                isCancelled: isCancelled, onFailureCleanup: {
                try? FileManager.default.removeItem(at: outURL)
            })
            outputs.append(actualURL)
        }

        return outputs
    }

    /// Runs ffmpeg and returns the actual URL that was written.
    /// If passthrough fails, falls back to PCM WAV — extension stays .wav to match actual codec.
    private func runFFmpeg(
        input: URL,
        start: Double,
        duration: Double,
        output: URL,
        acodecArgs: [String],
        overwritePolicy: OverwritePolicy,
        isCancelled: @escaping @Sendable () -> Bool,
        onFailureCleanup: @escaping @Sendable () -> Void
    ) async throws -> URL {
        let isPassthrough = acodecArgs.first == "-acodec" && acodecArgs.last == "copy"
        // .rename: file guaranteed absent by resolveOutputURL → safe to use -n
        // .overwrite: user wants replacement → -y
        // .skip: handled before calling runFFmpeg, never reaches here
        let overwriteFlag = (overwritePolicy == .overwrite) ? "-y" : "-n"

        if isPassthrough {
            do {
                try await runFFmpegOnce(input: input, start: start, duration: duration,
                                        output: output, extraArgs: acodecArgs,
                                        overwriteFlag: overwriteFlag,
                                        isCancelled: isCancelled, onFailureCleanup: {})
                return output
            } catch {
                onFailureCleanup()
                // Stream copy failed — fall back to PCM WAV.
                // Extension stays .wav to match actual codec; no rename back to original ext.
                let fallbackURL = output.deletingPathExtension().appendingPathExtension("wav")
                try await runFFmpegOnce(input: input, start: start, duration: duration,
                                        output: fallbackURL, extraArgs: ["-acodec", "pcm_s16le"],
                                        overwriteFlag: overwriteFlag,
                                        isCancelled: isCancelled, onFailureCleanup: {})
                return fallbackURL
            }
        } else {
            do {
                try await runFFmpegOnce(input: input, start: start, duration: duration,
                                        output: output, extraArgs: acodecArgs,
                                        overwriteFlag: overwriteFlag,
                                        isCancelled: isCancelled, onFailureCleanup: {})
                return output
            } catch {
                onFailureCleanup()
                throw error
            }
        }
    }

    /// Run ffmpeg once with given arguments; throws on failure.
    /// Checks `isCancelled` during execution and applies `onFailureCleanup` on error.
    private func runFFmpegOnce(
        input: URL,
        start: Double,
        duration: Double,
        output: URL,
        extraArgs: [String],
        overwriteFlag: String = "-y",
        isCancelled: @escaping @Sendable () -> Bool,
        onFailureCleanup: @escaping @Sendable () -> Void
    ) async throws {
        let runner = ProcessRunner(timeoutSeconds: timeoutSeconds)
        do {
            let (stdout, stderr, rc) = try await runner.runCollecting(
                executable: ffmpegPath,
                arguments: [
                    overwriteFlag, "-i", input.path,
                    "-ss", String(format: "%.3f", start),
                    "-t",  String(format: "%.3f", duration)
                ] + extraArgs + [output.path],
                isCancelled: isCancelled
            )
            if rc != 0 {
                let msg = (stderr.isEmpty ? stdout : stderr).prefix(300)
                throw SplitError.ffmpegFailed(String(msg), rc)
            }
        } catch let error as ProcessRunnerError {
            onFailureCleanup()
            if case .cancelled = error { throw SplitError.ffmpegFailed("Cancelled", -999) }
            if case .timeout(let secs, _) = error { throw SplitError.ffmpegFailed("Timed out after \(Int(secs))s", -1) }
            throw error
        } catch let error as SplitError {
            onFailureCleanup()
            throw error
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/'\\|?*")
        return name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

    /// Sanitizes a string for use as a directory name.
    /// Removes characters unsafe for filesystems and trims trailing spaces.
    /// Returns the cleaned name or "Untitled" if the result is empty.
    package nonisolated func sanitizeDirectoryName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/'\\|?*")
        var sanitized = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        // Remove trailing dots (Windows reserved)
        while sanitized.hasSuffix(".") { sanitized.removeLast() }
        // Directory names cannot be empty after sanitization
        if sanitized.isEmpty { sanitized = "Untitled" }
        return sanitized
    }

    /// Resolves a unique output directory by appending a numeric suffix if the path already exists.
    /// - Parameters:
    ///   - baseDir:  Parent directory (e.g. the folder containing the input file).
    ///   - safeName: Filesystem-safe directory name (already sanitized).
    /// - Returns: A URL that does not yet exist on disk.
    package nonisolated func resolveUniqueOutputDirectory(baseDir: URL, safeName: String) -> URL {
        // safeName is already sanitized by the caller; only check filesystem.
        var candidate = baseDir.appendingPathComponent(safeName)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        var counter = 1
        repeat {
            candidate = baseDir.appendingPathComponent("\(safeName) (\(counter))")
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Expand a filename template by replacing placeholders with track metadata.
    /// Placeholders: {index}, {title}, {artist}, {album}, {ext}
    private func applyNameTemplate(
        _ template: String,
        track: CueTrack,
        albumTitle: String,
        artist: String,
        ext: String
    ) -> String {
        let title = sanitizeFilename(track.title.isEmpty ? "Track_\(track.index)" : track.title)
        return template
            .replacingOccurrences(of: "{index}", with: String(track.index))
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{artist}", with: sanitizeFilename(artist))
            .replacingOccurrences(of: "{album}", with: sanitizeFilename(albumTitle))
            .replacingOccurrences(of: "{ext}", with: ext)
    }

    /// Resolve the output URL by applying the overwrite policy.
    /// - For `.rename`: appends -1, -2, … if the file already exists.
    /// - For `.overwrite` / `.skip`: returns the base URL unchanged.
    private func resolveOutputURL(
        outputDir: URL,
        baseName: String,
        policy: OverwritePolicy
    ) -> URL {
        var candidate = outputDir.appendingPathComponent(baseName)
        if policy == .rename {
            var counter = 1
            let nameWithoutExt = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = outputDir.appendingPathComponent("\(nameWithoutExt)-\(counter).\(ext)")
                counter += 1
            }
        }
        return candidate
    }
}
