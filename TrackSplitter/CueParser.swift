import Foundation

struct CueParser {
    func parse(cueURL: URL) throws -> CueSheet {
        let content = try String(contentsOf: cueURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var albumTitle = cueURL.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var year = ""
        var genre = ""
        var pageURL: String?

        struct DraftTrack {
            let index: Int
            var title: String
            var index00: Double?
            var index01: Double?
        }

        var drafts: [DraftTrack] = []
        var currentTrack: DraftTrack?

        func flushCurrentTrack() {
            guard let currentTrack else { return }
            drafts.append(currentTrack)
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("REM DATE ") {
                year = line.replacingOccurrences(of: "REM DATE ", with: "")
                continue
            }
            if line.hasPrefix("REM GENRE ") {
                genre = line.replacingOccurrences(of: "REM GENRE ", with: "")
                continue
            }
            if line.hasPrefix("REM COMMENT "), pageURL == nil {
                pageURL = firstURL(in: line)
                continue
            }
            if line.hasPrefix("TITLE ") {
                let value = parseQuotedValue(from: line) ?? ""
                if currentTrack == nil {
                    albumTitle = value.isEmpty ? albumTitle : value
                } else {
                    let currentTitle = currentTrack?.title ?? "Untitled"
                    currentTrack?.title = value.isEmpty ? currentTitle : value
                }
                continue
            }
            if line.hasPrefix("PERFORMER ") {
                let value = parseQuotedValue(from: line) ?? ""
                if currentTrack == nil, !value.isEmpty {
                    artist = value
                }
                continue
            }
            if line.hasPrefix("TRACK ") {
                flushCurrentTrack()
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let number = Int(parts[1]) else { continue }
                currentTrack = DraftTrack(index: number, title: "Track \(number)", index00: nil, index01: nil)
                continue
            }
            if line.hasPrefix("INDEX 00 ") {
                let parts = line.split(separator: " ")
                if let stamp = parts.last {
                    currentTrack?.index00 = try parseCueTime(String(stamp))
                }
                continue
            }
            if line.hasPrefix("INDEX 01 ") {
                let parts = line.split(separator: " ")
                if let stamp = parts.last {
                    currentTrack?.index01 = try parseCueTime(String(stamp))
                }
                continue
            }
        }

        flushCurrentTrack()

        let sortedDrafts = drafts.sorted { $0.index < $1.index }
        var resolved: [CueTrack] = []
        for (offset, item) in sortedDrafts.enumerated() {
            guard let start = item.index01 ?? item.index00 else {
                throw TrackSplitterError.cueParse("Track \(item.index) is missing INDEX 01 and INDEX 00.")
            }
            let end = offset + 1 < sortedDrafts.count ? (sortedDrafts[offset + 1].index01 ?? sortedDrafts[offset + 1].index00) : nil
            resolved.append(CueTrack(index: item.index, title: item.title, startSeconds: start, endSeconds: end))
        }

        guard !resolved.isEmpty else {
            throw TrackSplitterError.cueParse("No tracks found in CUE file.")
        }

        return CueSheet(albumTitle: albumTitle, artist: artist, year: year, genre: genre, pageURL: pageURL, tracks: resolved)
    }

    private func parseQuotedValue(from line: String) -> String? {
        guard let firstQuote = line.firstIndex(of: "\"") else { return nil }
        guard let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote else { return nil }
        return String(line[line.index(after: firstQuote)..<lastQuote])
    }

    private func parseCueTime(_ value: String) throws -> Double {
        let components = value.split(separator: ":")
        guard components.count == 3,
              let minutes = Double(components[0]),
              let seconds = Double(components[1]),
              let frames = Double(components[2]) else {
            throw TrackSplitterError.cueParse("Invalid time code: \(value)")
        }

        return (minutes * 60) + seconds + (frames / 75)
    }

    private func firstURL(in line: String) -> String? {
        let pattern = #"https?://\S+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), let matchRange = Range(match.range, in: line) else {
            return nil
        }
        return String(line[matchRange])
    }
}
