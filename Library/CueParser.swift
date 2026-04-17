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

/// Represents REM fields parsed from a CUE sheet (album-level metadata).
public struct CueRem: Sendable {
    public var date: String?     // REM DATE "..."
    public var genre: String?    // REM GENRE "..."
    public var comment: String?  // REM COMMENT "..."
    public var composer: String?  // REM COMPOSER "..."
    public var discNumber: String? // REM DISCNUMBER "..."

    public init(date: String? = nil, genre: String? = nil, comment: String? = nil,
                composer: String? = nil, discNumber: String? = nil) {
        self.date = date
        self.genre = genre
        self.comment = comment
        self.composer = composer
        self.discNumber = discNumber
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
public func parseCue(at url: URL) throws -> (tracks: [CueTrack], albumTitle: String?, performer: String?, file: CueFile?, rem: CueRem) {
    let data = try Data(contentsOf: url)
    let text = decodeCueData(data)

    var albumTitle: String?
    var performer: String?
    var tracks: [CueTrack] = []
    var curIdx: Int = 0
    var curTitle: String = ""
    var curStart: Double = 0
    var cueFile: CueFile?
    var rem = CueRem()

    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)

        if let cap = match(line: line, pattern: #"PERFORMER "([^"]+)""#) {
            // Only update performer at album level; track-level PERFORMER is valid CUE
            // but we return a single performer field (album level) for now.
            if curIdx == 0 {
                performer = cap
            }
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
        // REM DATE "..."
        else if let cap = match(line: line, pattern: #"REM DATE "?(.+)"?$"#) {
            rem.date = cap.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        // REM GENRE "..."
        else if let cap = match(line: line, pattern: #"REM GENRE "?(.+)"?$"#) {
            rem.genre = cap.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        // REM COMMENT "..."
        else if let cap = match(line: line, pattern: #"REM COMMENT "?(.+)"?$"#) {
            rem.comment = cap.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        // REM COMPOSER "..."
        else if let cap = match(line: line, pattern: #"REM COMPOSER "?(.+)"?$"#) {
            rem.composer = cap.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        // REM DISCNUMBER "..."
        else if let cap = match(line: line, pattern: #"REM DISCNUMBER "?(.+)"?$"#) {
            rem.discNumber = cap.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
    }

    if curIdx > 0 {
        tracks.append(CueTrack(index: curIdx, title: curTitle, startSeconds: curStart))
    }

    return (tracks, albumTitle, performer, cueFile, rem)
}

/// Find the .cue file corresponding to an audio URL.
/// Tries filename-based match first; falls back to scanning all .cue files
/// and using fuzzy FILE-field matching (handles Chinese encoding mismatches).
public func findCue(for audioURL: URL) -> URL? {
    let dir = audioURL.deletingLastPathComponent()
    let base = audioURL.deletingPathExtension().lastPathComponent

    // Try filename-based match
    for ext in ["cue", "CUE", "Cue"] {
        let candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }

    // Fallback: scan all .cue files and use fuzzy FILE-field matching
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
        return nil
    }
    var bestCandidate: URL?
    var bestScore: Double = 0

    for entry in entries {
        let ext = (entry as NSString).pathExtension.lowercased()
        if ext != "cue" { continue }
        let cueURL = dir.appendingPathComponent(entry)
        guard let (tracks, _, _, cueFile, _) = try? parseCue(at: cueURL),
              !tracks.isEmpty,
              let cf = cueFile else { continue }

        let score = stringSimilarity(cf.resolvedURL.lastPathComponent,
                                      audioURL.lastPathComponent)
        if score > bestScore {
            bestScore = score
            bestCandidate = cueURL
        }
    }

    // Require at least 80% similarity
    if bestScore >= 0.80 {
        return bestCandidate
    }

    // Fallback: return best candidate if nothing matches 80% but the base names do
    if let best = bestCandidate,
       bestScore >= 0.60,
       cfBaseNameMatches(best, audioURL) {
        return best
    }

    return nil
}

/// Check if the CUE's FILE field base name (without extension) broadly matches the audio file.
/// Allows through cases where encoding garbled only the Chinese characters.
private func cfBaseNameMatches(_ cueURL: URL, _ audioURL: URL) -> Bool {
    guard let (tracks, _, _, cueFile, _) = try? parseCue(at: cueURL),
          !tracks.isEmpty,
          let cf = cueFile else { return false }
    let cueBase = cf.resolvedURL.deletingPathExtension().lastPathComponent
    let audioBase = audioURL.deletingPathExtension().lastPathComponent
    // Strip common Unicode-confusable chars and compare
    let normalizedCue = cueBase.folding(options: .diacriticInsensitive, locale: .current)
    let normalizedAudio = audioBase.folding(options: .diacriticInsensitive, locale: .current)
    return stringSimilarity(normalizedCue, normalizedAudio) >= 0.60
}

/// Levenshtein-distance-based similarity ratio (0.0 – 1.0).
func stringSimilarity(_ s1: String, _ s2: String) -> Double {
    if s1 == s2 { return 1.0 }
    let s1Arr = Array(s1)
    let s2Arr = Array(s2)
    let m = s1Arr.count
    let n = s2Arr.count
    if m == 0 || n == 0 { return 0.0 }

    // Wagner-Fischer DP: O(mn) space → use two rows
    var prev = Array(0...n)
    var curr = [Int](repeating: 0, count: n + 1)

    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            let cost = s1Arr[i-1] == s2Arr[j-1] ? 0 : 1
            curr[j] = min(prev[j] + 1,        // deletion
                          curr[j-1] + 1,       // insertion
                          prev[j-1] + cost)     // substitution
        }
        swap(&prev, &curr)
    }

    let distance = prev[n]
    let maxLen = max(m, n)
    return 1.0 - (Double(distance) / Double(maxLen))
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
