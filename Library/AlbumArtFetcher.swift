import Foundation

/// Fetches album artwork with multiple source fallbacks.
public actor AlbumArtFetcher {

    public enum FetchError: Error, LocalizedError {
        case networkError(String)
        case parseError
        case notFound

        public var errorDescription: String? {
            switch self {
            case .networkError(let msg): return "Network error: \(msg)"
            case .parseError: return "Could not parse album art URL from page"
            case .notFound: return "No cover art found from any source"
            }
        }
    }

    /// Fetch album art as JPEG Data. Tries multiple sources in order.
    /// Local files (same directory as input) are checked first for offline reliability.
    /// Returns on first successful fetch; throws `notFound` only if all sources fail.
    public func fetch(artist: String?, album: String, inputFile: URL? = nil) async throws -> Data {
        // 1. Local file fallback (same directory as audio input) — pick the largest image
        if let input = inputFile {
            let dir = input.deletingLastPathComponent()
            if let data = largestImage(in: dir) {
                return data
            }
        }

        // 2. Online sources
        let sources: [() async throws -> Data] = [
            { try await self.fetchFromLeftFM(album: album) },
            { try await self.fetchFromMusicBrainz(artist: artist, album: album) },
            { try await self.fetchFromITunes(artist: artist, album: album) },
        ]

        var lastError: Error = FetchError.notFound

        for (i, source) in sources.enumerated() {
            do {
                let data = try await source()
                return data
            } catch {
                lastError = error
                // Continue to next source
            }
        }

        throw lastError
    }

    private func isImageData(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let header = data.prefix(4)
        return header.starts(with: [0xFF, 0xD8, 0xFF]) ||
               header.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// Pick the largest image file from a directory — good heuristic for album art.
    private func largestImage(in dir: URL) -> Data? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }

        let imageExts = Set(["jpg", "jpeg", "png"])
        var candidates: [(name: String, size: Int)] = []

        for entry in entries {
            let ext = (entry as NSString).pathExtension.lowercased()
            guard imageExts.contains(ext) else { continue }
            let fullURL = dir.appendingPathComponent(entry)
            if let attrs = try? fm.attributesOfItem(atPath: fullURL.path),
               let size = attrs[.size] as? Int, size > 5000 {
                candidates.append((entry, size))
            }
        }

        // Pick the largest (cover art is usually the biggest image)
        if let best = candidates.max(by: { $0.size < $1.size }) {
            return try? Data(contentsOf: dir.appendingPathComponent(best.name))
        }
        return nil
    }

    // MARK: - Source 1: leftfm.com (Chinese music album covers)

    private func fetchFromLeftFM(album: String) async throws -> Data {
        guard let url = URL(string: "http://leftfm.com/1535.html") else {
            throw FetchError.networkError("Invalid URL")
        }

        let data = try await fetchData(from: url)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FetchError.parseError
        }

        guard let coverURL = parseLeftFMAlbumURL(in: html, album: album) else {
            throw FetchError.notFound
        }

        guard let resolvedURL = URL(string: coverURL, relativeTo: URL(string: "http://leftfm.com")) else {
            throw FetchError.parseError
        }

        return try await fetchData(from: resolvedURL)
    }

    /// Parse leftfm HTML to find the cover image URL following the album name.
    private func parseLeftFMAlbumURL(in html: String, album: String) -> String? {
        // Try a few alias forms: the album name may differ in simplified/traditional Chinese
        let aliases = [
            album,
            album.replacingOccurrences(of: " ", with: ""),
            // Simplified Chinese aliases for common terms
            album.replacingOccurrences(of: "讓", with: "让"),
            album.replacingOccurrences(of: "讓", with: "让").replacingOccurrences(of: " ", with: ""),
        ]

        for alias in aliases {
            guard let range = html.range(of: alias) else { continue }

            // Scan forward from the album name to find the img tag with lazydata-src
            let snippet = String(html[range.upperBound..<html.endIndex])
            let imgPattern = #"lazydata-src=["']([^"']+)["']"#
            guard let re = try? NSRegularExpression(pattern: imgPattern, options: []),
                  let m = re.firstMatch(in: snippet, range: NSRange(snippet.startIndex..., in: snippet)),
                  m.numberOfRanges >= 2,
                  let uRange = Range(m.range(at: 1), in: snippet) else { continue }

            var path = String(snippet[uRange])
            // fix "../" prefix
            if path.hasPrefix("../") {
                path = String(path.dropFirst(3))
            } else if path.hasPrefix("..") {
                path = String(path.dropFirst(2))
            }
            return "http://leftfm.com/wp-content/uploads/" + path
        }

        return nil
    }

    // MARK: - Source 2: MusicBrainz Cover Art Archive

    private func fetchFromMusicBrainz(artist: String?, album: String) async throws -> Data {
        // Step 1: Search for the release
        let query = [artist, album].compactMap { $0 }.joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json&limit=5")!

        var request = URLRequest(url: searchURL)
        request.setValue("TrackSplitter/1.0 (https://github.com/ShadyUnderLight/TrackSplitter)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.networkError("MusicBrainz search failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]],
              let firstRelease = releases.first,
              let releaseId = firstRelease["id"] as? String else {
            throw FetchError.notFound
        }

        // Step 2: Fetch cover art from coverartarchive.org
        let coverURL = URL(string: "https://coverartarchive.org/release/\(releaseId)/front")!
        return try await fetchData(from: coverURL)
    }

    // MARK: - Source 3: iTunes Search API

    private func fetchFromITunes(artist: String?, album: String) async throws -> Data {
        var queryParts = [album]
        if let artist = artist { queryParts.append(artist) }
        let query = queryParts.joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=album&limit=5")!

        let data = try await fetchData(from: searchURL, skipHTTPSCheck: false)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artworkUrl = first["artworkUrl100"] as? String else {
            throw FetchError.notFound
        }

        // iTunes artwork URL has a fixed pattern: replace the last component (100x100) with 1200x1200
        let hiResUrl = artworkUrl.replacingOccurrences(of: "/100x100bb.jpg", with: "/1200x1200bb.jpg")

        return try await fetchData(from: URL(string: hiResUrl)!, skipHTTPSCheck: false)
    }

    // MARK: - HTTP helper

    private func fetchData(from url: URL, skipHTTPSCheck: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let responseData: Data
        let httpResp: URLResponse

        if skipHTTPSCheck {
            let cfg = URLSessionConfiguration.default
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: cfg)
            (responseData, httpResp) = try await session.data(for: request)
        } else {
            (responseData, httpResp) = try await URLSession.shared.data(for: request)
        }

        guard let http = httpResp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (httpResp as? HTTPURLResponse)?.statusCode ?? -1
            throw FetchError.networkError("HTTP \(code)")
        }

        guard responseData.count > 5000 else {
            throw FetchError.networkError("Response too small (\(responseData.count) bytes)")
        }

        return responseData
    }
}
