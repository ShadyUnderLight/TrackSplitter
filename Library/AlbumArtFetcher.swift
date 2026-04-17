import Foundation
import AVFoundation
import AppKit

// MARK: - Provider Protocol

/// A cover-art provider that returns image data or nil if no cover was found.
/// Errors indicate a failure that should be logged; nil means "no cover from this source".
public protocol CoverProvider: Sendable {
    /// Human-readable name for logging.
    var name: String { get }

    /// Fetch a cover image. Returns `nil` if no cover was found at this source;
    /// throws if the source failed in a way that should be logged as an error.
    func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data?
}

// MARK: - Provider Result

/// Result of a single provider attempt — used for structured logging.
/// Result of a single provider attempt — used for structured logging.
/// Carries the provider name so description is always meaningful.
public struct ProviderResult: Sendable {
    public enum Status: Sendable {
        case success
        case notFound
        case error
    }

    public let providerName: String
    public let status: Status
    public let sizeBytes: Int?
    public let errorMessage: String?

    public var description: String {
        switch status {
        case .success:
            return "✅ \(providerName): \(sizeBytes ?? 0) bytes"
        case .notFound:
            return "❌ \(providerName): no cover found"
        case .error:
            return "⚠️  \(providerName): \(errorMessage ?? "unknown error")"
        }
    }

    public static func success(providerName: String, sizeBytes: Int) -> ProviderResult {
        ProviderResult(providerName: providerName, status: .success, sizeBytes: sizeBytes, errorMessage: nil)
    }

    public static func notFound(providerName: String) -> ProviderResult {
        ProviderResult(providerName: providerName, status: .notFound, sizeBytes: nil, errorMessage: nil)
    }

    public static func error(providerName: String, message: String) -> ProviderResult {
        ProviderResult(providerName: providerName, status: .error, sizeBytes: nil, errorMessage: message)
    }
}

// MARK: - Cache

/// Simple in-memory cache keyed by (artist, album).
public actor CoverCache {
    public struct CacheKey: Hashable, Sendable {
        public let artist: String?
        public let album: String
        public init(artist: String?, album: String) {
            self.artist = artist
            self.album = album
        }
    }

    private struct CacheEntry: Sendable {
        let data: Data
        let timestamp: Date
    }

    private var entries: [CacheKey: CacheEntry] = [:]

    public init() {}

    public func get(_ key: CacheKey) -> Data? {
        entries[key]?.data
    }

    public func set(_ key: CacheKey, data: Data) {
        entries[key] = CacheEntry(data: data, timestamp: Date())
    }
}

// MARK: - Album Art Fetcher (Pipeline)

/// Fetches album artwork through a ordered pipeline of providers.
/// Providers are tried in order; the first non-nil result wins.
/// Each provider has an independent timeout; failures are logged and do not block subsequent providers.
public actor AlbumArtFetcher {

    public enum FetchError: Error, LocalizedError {
        case notFound
        case allProvidersFailed([ProviderResult])

        public var errorDescription: String? {
            switch self {
            case .notFound: return "No cover art found"
            case .allProvidersFailed: return "All cover providers failed"
            }
        }
    }

    /// Configuration for the fetcher pipeline.
    public struct Config: Sendable {
        /// Provider timeout in seconds (per provider). Default: 8s.
        public var timeoutSeconds: Double = 8
        /// Explicit list of provider types to enable. nil = all.
        public var enabledProviders: [String]? = nil
        /// LeftFM is fragile and uses HTTP; set to false to disable it. Default: false.
        public var enableLeftFM: Bool = false

        public init(
            timeoutSeconds: Double = 8,
            enabledProviders: [String]? = nil,
            enableLeftFM: Bool = false
        ) {
            self.timeoutSeconds = timeoutSeconds
            self.enabledProviders = enabledProviders
            self.enableLeftFM = enableLeftFM
        }
    }

    private let cache: CoverCache
    private let config: Config

    public init(cache: CoverCache = CoverCache(), config: Config = Config()) {
        self.cache = cache
        self.config = config
    }

    /// Fetch album art as JPEG Data. Tries providers in order; results are cached.
    /// Returns on first successful fetch; throws `notFound` only if all sources are exhausted.
    public func fetch(artist: String?, album: String, inputFile: URL? = nil) async throws -> Data {
        let key = CoverCache.CacheKey(artist: artist, album: album)

        // Check cache first
        if let cached = await cache.get(key) {
            return cached
        }

        let providers = buildPipeline()
        var allResults: [ProviderResult] = []

        for provider in providers {
            let result = await attempt(provider: provider, artist: artist, album: album, inputFile: inputFile)
            allResults.append(result)

            switch result.status {
            case .success:
                // Provider stores in cache before returning result
                if let data = await cache.get(key) {
                    return data
                }
            case .notFound, .error:
                continue
            }
        }

        // Only throw allProvidersFailed if at least one provider reported an error.
        // If every provider returned .notFound, the clean answer is "no cover found".
        let hadError = allResults.contains { $0.status == .error }
        if hadError {
            throw FetchError.allProvidersFailed(allResults)
        } else {
            throw FetchError.notFound
        }
    }

    /// Wrapper that runs a provider with timeout and returns a structured result.
    /// On success, the data is stored in cache before the result is returned.
    private func attempt(
        provider: any CoverProvider,
        artist: String?,
        album: String,
        inputFile: URL?
    ) async -> ProviderResult {
        do {
            let timeoutNanos = UInt64(self.config.timeoutSeconds * 1_000_000_000)

            struct TimeoutError: Error {}

            let fetchedData: Data? = try await withThrowingTaskGroup(of: Data?.self) { group in
                // Timeout task — throws to stop the group
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    throw TimeoutError()
                }
                // Provider task
                group.addTask {
                    try await provider.fetch(artist: artist, album: album, inputFile: inputFile)
                }

                // Return first non-nil result; propagate nil as "not found"
                for try await result in group {
                    if let d = result {
                        return d
                    }
                }
                return nil
            }

            if let data = fetchedData {
                let key = CoverCache.CacheKey(artist: artist, album: album)
                await cache.set(key, data: data)
                return .success(providerName: provider.name, sizeBytes: data.count)
            } else {
                return .notFound(providerName: provider.name)
            }
        } catch {
            // Timeout or provider error
            return .error(providerName: provider.name, message: error.localizedDescription)
        }
    }

    /// Builds the ordered provider list based on config.
    private func buildPipeline() -> [any CoverProvider] {
        var providers: [any CoverProvider] = []

        // 1. Local directory image (always first — no network, deterministic)
        providers.append(LocalDirectoryCoverProvider())

        // 2. Embedded album art in the input audio file
        providers.append(EmbeddedCoverProvider())

        // 3. MusicBrainz / Cover Art Archive (reliable API)
        providers.append(MusicBrainzCoverProvider())

        // 4. iTunes Search API (reliable)
        providers.append(ITunesCoverProvider())

        // 5. LeftFM web scraping (fragile, HTTP, best-effort — opt-in only)
        if config.enableLeftFM {
            providers.append(LeftFMCoverProvider())
        }

        // Filter by enabledProviders if specified
        if let enabled = config.enabledProviders {
            providers = providers.filter { enabled.contains($0.name) }
        }

        return providers
    }
}

// MARK: - Provider: Local Directory Image

/// Picks the largest image file from the directory of the input audio file.
/// This is always checked first — no network required.
public struct LocalDirectoryCoverProvider: CoverProvider {
    public let name = "LocalDirectory"

    public init() {}

    public func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        guard let input = inputFile else { return nil }
        return largestImage(in: input.deletingLastPathComponent())
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

        if let best = candidates.max(by: { $0.size < $1.size }) {
            return try? Data(contentsOf: dir.appendingPathComponent(best.name))
        }
        return nil
    }
}

// MARK: - Provider: Embedded Cover Art

/// Extracts embedded album art directly from the input audio file via AVFoundation.
public struct EmbeddedCoverProvider: CoverProvider {
    public let name = "Embedded"

    public init() {}

    public func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        guard let input = inputFile else { return nil }

        let asset = AVAsset(url: input)
        let metadata = try await asset.load(.metadata)

        for item in metadata {
            guard let commonKey = item.commonKey,
                  commonKey == .commonKeyArtwork else { continue }

            // artwork may be stored as data directly (M4A/AAC) or as a dictionary (MP3 ID3)
            if let data = try? await item.load(.dataValue), data.count > 1000 {
                return normalizeToJPEG(data)
            }
        }

        return nil
    }

    /// Normalize various image formats to JPEG Data for consistency.
    private func normalizeToJPEG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        guard let tiffRep = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRep) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

// MARK: - Provider: MusicBrainz Cover Art Archive

/// Fetches cover art via the MusicBrainz / Cover Art Archive API.
/// Reliable, API-based, no HTML parsing required.
public struct MusicBrainzCoverProvider: CoverProvider {
    public let name = "MusicBrainz"

    private let userAgent = "TrackSplitter/1.0 (https://github.com/ShadyUnderLight/TrackSplitter)"

    public init() {}

    public func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        // Step 1: Search for the release
        let query = [artist, album].compactMap { $0 }.joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json&limit=5")!

        var request = URLRequest(url: searchURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: request)

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.networkError("MusicBrainz search failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]],
              let firstRelease = releases.first,
              let releaseId = firstRelease["id"] as? String else {
            return nil  // No match — not an error
        }

        // Step 2: Fetch cover art from coverartarchive.org
        let coverURL = URL(string: "https://coverartarchive.org/release/\(releaseId)/front")!
        return try await fetchCoverArt(from: coverURL)
    }

    private func fetchCoverArt(from url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: request)

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 404 { return nil }  // No front cover uploaded
            throw FetchError.networkError("Cover Art Archive HTTP \(code)")
        }

        guard data.count > 5000 else {
            throw FetchError.networkError("Response too small (\(data.count) bytes)")
        }

        return data
    }

    enum FetchError: Error {
        case networkError(String)
    }
}

// MARK: - Provider: iTunes Search API

/// Fetches cover art via the iTunes Search API.
/// Reliable, HTTPS, API-based.
public struct ITunesCoverProvider: CoverProvider {
    public let name = "iTunes"

    public init() {}

    public func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        var queryParts = [album]
        if let artist = artist { queryParts.append(artist) }
        let query = queryParts.joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=album&limit=5")!

        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: searchURL))

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.networkError("iTunes search failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artworkUrl = first["artworkUrl100"] as? String else {
            return nil  // No match
        }

        // iTunes artwork URL pattern: replace 100x100 with 1200x1200 for hi-res
        let hiResUrl = artworkUrl.replacingOccurrences(of: "/100x100bb.jpg", with: "/1200x1200bb.jpg")

        guard let url = URL(string: hiResUrl) else { return nil }
        return try await fetchCoverArt(from: url)
    }

    private func fetchCoverArt(from url: URL) async throws -> Data? {
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url))

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 404 { return nil }
            throw FetchError.networkError("iTunes artwork HTTP \(code)")
        }

        guard data.count > 5000 else {
            throw FetchError.networkError("iTunes artwork response too small (\(data.count) bytes)")
        }

        return data
    }

    enum FetchError: Error {
        case networkError(String)
    }
}

// MARK: - Provider: LeftFM (Best-Effort, Opt-In)

/// Scrapes album cover from leftfm.com via HTML parsing.
/// ⚠️ Fragile: depends on page structure, uses HTTP, Chinese-encoding aliases.
/// Disabled by default — set `config.enableLeftFM = true` to activate.
public struct LeftFMCoverProvider: CoverProvider {
    public let name = "LeftFM"

    public init() {}

    public func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        // Attempt to find album URL via site search
        let encoded = album.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? album
        guard let searchURL = URL(string: "https://leftfm.com/?s=\(encoded)") else { return nil }

        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: searchURL))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let page = html else { return nil }

        guard let albumURL = parseAlbumURL(from: page, album: album) else { return nil }

        // Fetch the album page
        let (albumPageData, albumResp) = try await URLSession.shared.data(for: URLRequest(url: albumURL))
        guard let albumHttp = albumResp as? HTTPURLResponse, albumHttp.statusCode == 200 else { return nil }

        let albumPage = String(data: albumPageData, encoding: .utf8)
            ?? String(data: albumPageData, encoding: .isoLatin1)
        guard let pageHTML = albumPage else { return nil }

        guard let coverPath = parseCoverPath(from: pageHTML) else { return nil }

        guard let coverURL = URL(string: coverPath, relativeTo: URL(string: "https://leftfm.com")) else {
            return nil
        }

        let (coverData, coverResp) = try await URLSession.shared.data(for: URLRequest(url: coverURL))
        guard let coverHttp = coverResp as? HTTPURLResponse, coverHttp.statusCode == 200 else {
            return nil
        }

        return coverData
    }

    /// Parse the search results page to extract the first album URL.
    private func parseAlbumURL(from html: String, album: String) -> URL? {
        let aliases = [
            album,
            album.replacingOccurrences(of: " ", with: ""),
            album.replacingOccurrences(of: "讓", with: "让"),
            album.replacingOccurrences(of: "讓", with: "让").replacingOccurrences(of: " ", with: ""),
        ]

        for alias in aliases {
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            let pattern = #"<a[^>]+href=["'](/[0-9]+\.html)["'][^>]*>.*?"\#(escaped).*?</a>"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(m.range(at: 1), in: html) else { continue }

            let relative = String(html[range])
            return URL(string: "https://leftfm.com" + relative)
        }
        return nil
    }

    /// Parse the album page HTML to find the cover image path.
    private func parseCoverPath(from html: String) -> String? {
        // Look for lazydata-src img tag following any known alias
        let imgPattern = #"lazydata-src=["']([^"']+)["']"#
        guard let re = try? NSRegularExpression(pattern: imgPattern, options: []),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              m.numberOfRanges >= 2,
              let uRange = Range(m.range(at: 1), in: html) else { return nil }

        var path = String(html[uRange])
        // Fix "../" prefix
        if path.hasPrefix("../") {
            path = String(path.dropFirst(3))
        } else if path.hasPrefix("..") {
            path = String(path.dropFirst(2))
        }
        return "https://leftfm.com/wp-content/uploads/" + path
    }
}
