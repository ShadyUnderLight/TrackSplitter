import Foundation

/// Represents a source of chapter/track definitions for splitting.
/// Each case carries the URL of the source file plus any parsed metadata.
public enum ChapterSource: Sendable {
    /// Standard CUE sheet (existing path).
    case cue(URL)
    /// Plain text chapter file with one timestamp+title per line.
    case textChapters(URL)
    /// FFmpeg chapter metadata file (INI-style with CHAPTER blocks).
    case ffmpegChapters(URL)
    /// Chapters embedded in the audio file itself (read via ffprobe).
    case embedded(URL)
}

extension ChapterSource {
    /// Human-readable description of this source type.
    public var typeName: String {
        switch self {
        case .cue: return "CUE"
        case .textChapters: return "Text chapters"
        case .ffmpegChapters: return "FFmpeg chapters"
        case .embedded: return "Embedded chapters"
        }
    }

    /// The file URL this source points to.
    public var url: URL {
        switch self {
        case .cue(let u), .textChapters(let u),
             .ffmpegChapters(let u), .embedded(let u):
            return u
        }
    }
}

// MARK: - Text Chapter Parser

/// Parses plain text chapter files with timestamped lines.
///
/// Supported line formats (one track per line):
///   00:00:00 Track 1 Title
///   00:00:00 - Track 2 Title
///   [00:00:00] Track 3 Title
///   00:00:00.500 Track 4 Title  (sub-second precision)
public struct TextChapterParser: Sendable {

    public enum Error: Swift.Error, LocalizedError {
        case fileNotFound(URL)
        case emptyFile(URL)
        case noValidTimestamps(URL)
        case invalidTimestamp(line: String, index: Int)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "Chapter file not found: \(url.lastPathComponent)"
            case .emptyFile(let url):
                return "Chapter file is empty: \(url.lastPathComponent)"
            case .noValidTimestamps(let url):
                return "No valid timestamps found in: \(url.lastPathComponent)"
            case .invalidTimestamp(let line, let index):
                return "Invalid timestamp on line \(index + 1): '\(line)'"
            }
        }
    }

    public init() {}

    /// Parse a text chapter file into an array of CueTrack-compatible entries.
    /// - Parameters:
    ///   - url: URL of the text chapter file
    ///   - defaultTitle: Title to use for tracks that have no title in the file
    /// - Returns: Array of (startSeconds, title) tuples in order
    public func parse(at url: URL, defaultTitle: String = "Track") throws -> [(startSeconds: Double, title: String)] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try Big5 and DOS Latin 1 as fallback encodings
            // swiftlint:disable legacy_objc_type
            if let big5 = try? String(contentsOf: url, encoding: .init(rawValue: UInt(CFStringEncodings.big5.rawValue))) {
                content = big5
            } else if let latin1 = try? String(contentsOf: url, encoding: .init(rawValue: UInt(CFStringEncodings.dosLatin1.rawValue))) {
                content = latin1
            } else {
                // Last resort — try latin1 without caring about errors
                content = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            }
        }

        let lines = content.components(separatedBy: .newlines)
        var entries: [(startSeconds: Double, title: String)] = []
        var lineIndex = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

            // Try various timestamp formats
            if let (seconds, rest) = parseTimestampLine(trimmed) {
                let title = extractTitle(rest, defaultTitle: defaultTitle, index: lineIndex)
                entries.append((seconds, title))
            }
            lineIndex += 1
        }

        guard !entries.isEmpty else {
            throw Error.noValidTimestamps(url)
        }

        // Sort by timestamp
        entries.sort { $0.startSeconds < $1.startSeconds }
        return entries
    }

    /// Parse a timestamp from a line and return the seconds value + remainder of line.
    private func parseTimestampLine(_ line: String) -> (seconds: Double, rest: String)? {
        // Supported formats (semantics are explicit — do not mix):
        //   MM:SS           → minutes:seconds  (e.g. 03:45 = 3 min 45 sec)
        //   HH:MM:SS        → hours:minutes:seconds  (e.g. 1:02:03 = 1h 2m 3s)
        //   HH:MM:SS.mmm    → hours:minutes:seconds.subseconds  (e.g. 00:03:45.500 = 3m 45.5s)
        //   [MM:SS] Title
        //   [HH:MM:SS] Title
        var work = line.trimmingCharacters(in: .whitespaces)

        var rest = ""

        // Strip matched [ ... ] pair and preserve anything after the closing ]
        if work.hasPrefix("[") {
            if let endBracket = work.firstIndex(of: "]") {
                let afterBracket = work.index(after: endBracket)
                rest = String(work[afterBracket...]).trimmingCharacters(in: .whitespaces)
                work = String(work[work.index(after: work.startIndex)..<endBracket])
            }
        }

        // Extract timestamp (first token, before first space)
        let parts = work.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let tsString = String(first)

        let tsComponents = tsString.split(separator: ":")
        guard tsComponents.count == 2 || tsComponents.count == 3 else { return nil }

        var totalSeconds: Double = 0

        if tsComponents.count == 2 {
            // MM:SS format — first component is minutes, second is seconds
            guard let mm = Double(tsComponents[0]),
                  let ss = Double(tsComponents[1]) else { return nil }
            totalSeconds = mm * 60 + ss
        } else {
            // HH:MM:SS[.mmm] format — third component may have subseconds
            guard let hh = Double(tsComponents[0]),
                  let mm = Double(tsComponents[1]) else { return nil }
            let secStr = String(tsComponents[2])
            // Support fractional seconds: split on "." if present
            let secComponents = secStr.split(separator: ".", maxSplits: 1)
            guard let sec = Double(secComponents[0]) else { return nil }
            totalSeconds = hh * 3600 + mm * 60 + sec
            if secComponents.count == 2 {
                // Fractional part: ".500" → 0.5 seconds
                let frac = Double("0." + String(secComponents[1])) ?? 0
                totalSeconds += frac
            }
        }

        // If no rest was extracted from the [bracket] form, use the remainder from work.split
        if rest.isEmpty && parts.count > 1 {
            rest = String(parts[1])
        }

        return (totalSeconds, rest)
    }

    /// Extract a clean title from the remainder of the line.
    private func extractTitle(_ rest: String, defaultTitle: String, index: Int) -> String {
        var title = rest.trimmingCharacters(in: .whitespaces)

        // Strip leading "- " or ": " separator
        if title.hasPrefix("- ") { title = String(title.dropFirst(2)) }
        if title.hasPrefix(": ")  { title = String(title.dropFirst(2)) }

        title = title.trimmingCharacters(in: .whitespaces)

        if title.isEmpty {
            return "\(defaultTitle) \(index + 1)"
        }
        return title
    }
}

// MARK: - FFmpeg Chapter Parser

/// Parses FFmpeg chapter metadata files (INI-style with CHAPTER BEGIN/END/TITLE).
public struct FFmpegChapterParser: Sendable {

    public enum Error: Swift.Error, LocalizedError {
        case fileNotFound(URL)
        case emptyFile(URL)
        case noValidChapters(URL)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let url): return "Chapter file not found: \(url.lastPathComponent)"
            case .emptyFile(let url):    return "Chapter file is empty: \(url.lastPathComponent)"
            case .noValidChapters(let url): return "No valid chapters found in: \(url.lastPathComponent)"
            }
        }
    }

    public init() {}

    /// Parse an FFmpeg chapter metadata file.
    /// Format:
    ///   ;FFMETADATA1
    ///   title=Album Title
    ///   artist=Artist
    ///   CHAPTER0000=00:00:00.000
    ///   CHAPTER0000NAME=Track 1
    ///   CHAPTER0001=00:03:45.000
    ///   CHAPTER0001NAME=Track 2
    public func parse(at url: URL) throws -> [(startSeconds: Double, title: String)] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        guard !content.isEmpty else { throw Error.emptyFile(url) }

        var chapters: [(startSeconds: Double, title: String)] = []

        // Match CHAPTERXXXX=HH:MM:SS.mmm
        let chapterPattern = #"CHAPTER\d+=\s*(\d+):(\d{2}):(\d{2})\.(\d+)"#
        let namePattern  = #"CHAPTER\d+NAME=\s*(.+)"#

        let chapterRegex = try! NSRegularExpression(pattern: chapterPattern, options: [])
        let nameRegex    = try! NSRegularExpression(pattern: namePattern,  options: [])

        let lines = content.components(separatedBy: .newlines)

        var currentChapter: (startSeconds: Double, title: String)?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }

            // Check for CHAPTER timestamp line
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = chapterRegex.firstMatch(in: trimmed, options: [], range: range) {
                // Flush previous chapter
                if let ch = currentChapter {
                    chapters.append(ch)
                }

                // Parse HH:MM:SS.mmm
                let h  = Double(trimmed[( Range(match.range(at: 1), in: trimmed) )!])!
                let m  = Double(trimmed[( Range(match.range(at: 2), in: trimmed) )!])!
                let s  = Double(trimmed[( Range(match.range(at: 3), in: trimmed) )!])!
                let ms = Double(trimmed[( Range(match.range(at: 4), in: trimmed) )!])! / 1000.0

                let seconds = h * 3600 + m * 60 + s + ms
                currentChapter = (seconds, "Chapter \(chapters.count + 1)")
            }

            // Check for CHAPTER NAME line
            if let match = nameRegex.firstMatch(in: trimmed, options: [], range: range),
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                var title = String(trimmed[nameRange]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, var ch = currentChapter {
                    ch.title = title
                    currentChapter = ch
                }
            }
        }

        // Flush last chapter
        if let ch = currentChapter {
            chapters.append(ch)
        }

        guard !chapters.isEmpty else { throw Error.noValidChapters(url) }

        chapters.sort { $0.startSeconds < $1.startSeconds }
        return chapters
    }
}

// MARK: - Embedded Chapter Reader

/// Reads embedded chapter markers from an audio file using ffprobe.
public struct EmbeddedChapterReader: Sendable {

    public enum Error: Swift.Error, LocalizedError {
        case ffprobeNotFound
        case noChaptersFound(URL)
        case parseError(URL, String)

        public var errorDescription: String? {
            switch self {
            case .ffprobeNotFound:
                return "ffprobe not found — cannot read embedded chapters"
            case .noChaptersFound(let url):
                return "No embedded chapters found in: \(url.lastPathComponent)"
            case .parseError(let url, let detail):
                return "Failed to parse chapters from \(url.lastPathComponent): \(detail)"
            }
        }
    }

    public init() {}

    /// Read embedded chapters from an audio file using ffprobe.
    /// Returns an array of (startSeconds, title) tuples.
    public func read(from url: URL) async throws -> [(startSeconds: Double, title: String)] {
        let ffprobePath = try Self.ffprobePath()

        let args = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_chapters",
            url.path
        ]

        let runner = ProcessRunner(timeoutSeconds: 5.0)
        let output = try await runner.run(executable: ffprobePath, arguments: args)

        return try parseFfprobeJSON(output, url: url)
    }

    private func parseFfprobeJSON(_ json: String, url: URL) throws -> [(startSeconds: Double, title: String)] {
        guard let data = json.data(using: .utf8) else {
            throw Error.parseError(url, "invalid UTF-8 in ffprobe output")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chapters = json["chapters"] as? [[String: Any]] else {
            throw Error.noChaptersFound(url)
        }

        var entries: [(startSeconds: Double, title: String)] = []

        for (index, ch) in chapters.enumerated() {
            guard let startMs = ch["start_time"] as? String,
                  let endMs   = ch["end_time"]   as? String,
                  let start    = Double(startMs),
                  let end      = Double(endMs) else { continue }

            var title = "Chapter \(index + 1)"
            if let tags = ch["tags"] as? [String: Any],
               let t = tags["title"] as? String, !t.isEmpty {
                title = t
            }

            entries.append((startSeconds: start, title: title))
        }

        guard !entries.isEmpty else { throw Error.noChaptersFound(url) }
        entries.sort { $0.startSeconds < $1.startSeconds }
        return entries
    }

    /// Locate ffprobe on the filesystem and return its absolute path.
    /// Throws ffprobeNotFound if ffprobe is not found in any expected location.
    private static func ffprobePath() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
            "/bin/ffprobe"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try PATH lookup — find ffprobe via explicit path search
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = pathEnv.components(separatedBy: ":")
        for dir in pathDirs {
            let fullPath = (dir as NSString).appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        throw Error.ffprobeNotFound
    }
}
