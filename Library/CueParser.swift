import Foundation

/// Represents the FILE field in a CUE sheet.
public struct CueFile: Sendable {
    /// Raw path string as declared in CUE FILE "..." WAVE
    public let path: String
    /// Resolved URL relative to the CUE file's directory
    public let resolvedURL: URL

    public init(path: String, resolvedURL: URL) {
        self.path = path
        self.resolvedURL = resolvedURL
    }
}

/// Represents a single track parsed from a CUE sheet.
public struct CueTrack: Sendable {
    public let index: Int
    public let title: String
    public let startSeconds: Double
    public var endSeconds: Double?

    public init(index: Int, title: String, startSeconds: Double, endSeconds: Double? = nil) {
        self.index = index
        self.title = title
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Attempt to decode CUE data, trying UTF-8 → Big5 via iconv → ISO Latin 1 fallback.
private func decodeCueData(_ data: Data) -> String {
    // Try UTF-8 first
    if let s = String(data: data, encoding: .utf8), !s.contains("\u{FFFD}") {
        return s
    }

    // Try iconv BIG5→UTF-8 (reliable on macOS)
    let tmpPath = NSTemporaryDirectory() + "tracksplitter_cue_\(UUID().uuidString).cue"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }
    try? data.write(to: URL(fileURLWithPath: tmpPath))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconv")
    process.arguments = ["-f", "BIG5", "-t", "UTF-8", tmpPath]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()

    if let outData = try? pipe.fileHandleForReading.readToEnd(),
       let s = String(data: outData, encoding: .utf8), !s.contains("\u{FFFD}") {
        return s
    }

    // Fall back to ISO Latin 1 (lossy for non-ASCII)
    return String(data: data, encoding: .isoLatin1) ?? ""
}

/// Parse a CUE file, trying multiple encodings for Chinese filename compatibility.
public func parseCue(at url: URL) throws -> (tracks: [CueTrack], albumTitle: String?, performer: String?, file: CueFile?) {
    let data = try Data(contentsOf: url)
    let text = decodeCueData(data)

    var albumTitle: String?
    var performer: String?
    var tracks: [CueTrack] = []
    var curIdx: Int = 0
    var curTitle: String = ""
    var curStart: Double = 0
    var cueFile: CueFile?

    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)

        if let cap = match(line: line, pattern: #"PERFORMER "([^"]+)""#) {
            performer = cap
        }
        else if let cap = match(line: line, pattern: #"TITLE "([^"]+)""#) {
            if curIdx > 0 {
                curTitle = cap
            } else {
                albumTitle = cap
            }
        }
        // FILE "..." WAVE — parse audio file reference
        else if let filePath = match(line: line, pattern: #"FILE "([^"]+)""#) {
            let fileName = filePath.trimmingCharacters(in: .whitespaces)
            let cueDir = url.deletingLastPathComponent()
            let resolvedURL = cueDir.appendingPathComponent(fileName)
            cueFile = CueFile(path: filePath, resolvedURL: resolvedURL)
        }
        // TRACK nn AUDIO
        else if let numStr = match(line: line, pattern: #"TRACK (\d+) AUDIO"#) {
            if curIdx > 0 {
                tracks.append(CueTrack(index: curIdx, title: curTitle, startSeconds: curStart))
            }
            curIdx = Int(numStr) ?? 0
            curTitle = ""
            curStart = 0
        }
        // INDEX 01 mm:ss:ff
        else if let ts = parseTimestamp(line: line, pattern: "INDEX 01 (\\d+):(\\d+):(\\d+)$") {
            curStart = ts
        }
    }

    if curIdx > 0 {
        tracks.append(CueTrack(index: curIdx, title: curTitle, startSeconds: curStart))
    }

    return (tracks, albumTitle, performer, cueFile)
}

/// Find the .cue file corresponding to a FLAC URL.
public func findCue(for flacURL: URL) -> URL? {
    let dir = flacURL.deletingLastPathComponent()
    let base = flacURL.deletingPathExtension().lastPathComponent
    for ext in ["cue", "CUE", "Cue"] {
        let candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

// MARK: - Private helpers

/// Match a capturing group from a line using basic regex (no NSRegularExpression needed for simple patterns).
private func match(line: String, pattern: String) -> String? {
    // Convert BRE-style pattern to case-insensitive search
    // Pattern format: "TOKEN \"%([^\"]+)\"" — capture group 1 is what we want
    // We implement a simple parser instead of NSRegularExpression to avoid Foundation overhead
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          m.numberOfRanges >= 2,
          let r = Range(m.range(at: 1), in: line) else { return nil }
    return String(line[r])
}

/// Parse MM:SS:FF timestamp from a line.
private func parseTimestamp(line: String, pattern: String) -> Double? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          m.numberOfRanges == 4,
          let r1 = Range(m.range(at: 1), in: line),
          let r2 = Range(m.range(at: 2), in: line),
          let r3 = Range(m.range(at: 3), in: line),
          let mins = Double(line[r1]),
          let secs = Double(line[r2]),
          let frames = Double(line[r3]) else { return nil }
    return mins * 60 + secs + frames / 75.0
}

extension Data {
    func decoded(as encoding: String.Encoding) throws -> String {
        guard let s = String(data: self, encoding: encoding) else {
            throw NSError(domain: "CueParser", code: 1, userInfo: nil)
        }
        return s
    }
}
