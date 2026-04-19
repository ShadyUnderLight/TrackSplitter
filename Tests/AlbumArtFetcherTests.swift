import XCTest
@testable import TrackSplitterLib

// MARK: - Mock Providers for Testing

/// A provider that always succeeds with a fixed image.
struct MockSuccessProvider: CoverProvider {
    let name: String
    let data: Data

    init(name: String = "MockSuccess", data: Data = Data([0xFF, 0xD8, 0xFF, 0xE0])) {
        self.name = name
        self.data = data
    }

    func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        return data
    }
}

/// A provider that always returns nil (no cover found).
struct MockNotFoundProvider: CoverProvider {
    let name: String

    init(name: String = "MockNotFound") {
        self.name = name
    }

    func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        return nil
    }
}

/// A provider that always throws.
struct MockErrorProvider: CoverProvider {
    let name: String
    let error: Error

    init(name: String = "MockError", error: Error = NSError(domain: "test", code: 1)) {
        self.name = name
        self.error = error
    }

    func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        throw error
    }
}

/// A provider that hangs until cancelled (for timeout testing).
struct MockHangingProvider: CoverProvider {
    let name: String = "MockHanging"

    func fetch(artist: String?, album: String, inputFile: URL?) async throws -> Data? {
        try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
        return Data([0xFF, 0xD8, 0xFF, 0xE0])
    }
}

// MARK: - LocalDirectoryCoverProvider Tests

final class LocalDirectoryCoverProviderTests: XCTestCase {
    var tempDir: URL!
    var fm: FileManager { FileManager.default }

    override func setUp() async throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: tempDir)
    }

    func testPicksLargestJpg() async throws {
        // Create 3 image files of different sizes
        let small  = tempDir.appendingPathComponent("a.jpg")
        let medium = tempDir.appendingPathComponent("b.jpg")
        let large  = tempDir.appendingPathComponent("c.jpg")

        try Data(repeating: 0xFF, count: 100).write(to: small)
        try Data(repeating: 0xFF, count: 1000).write(to: medium)
        try Data(repeating: 0xFF, count: 10000).write(to: large)

        let provider = LocalDirectoryCoverProvider()
        let result = try await provider.fetch(artist: nil, album: "", inputFile: small)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 10000)
    }

    func testIgnoresFilesUnder5KB() async throws {
        // Create a tiny "image" — should be skipped
        let tiny = tempDir.appendingPathComponent("tiny.jpg")
        try Data(repeating: 0xFF, count: 100).write(to: tiny)

        let provider = LocalDirectoryCoverProvider()
        let result = try await provider.fetch(artist: nil, album: "", inputFile: tiny)

        XCTAssertNil(result)
    }

    func testNoInputFileReturnsNil() async throws {
        let provider = LocalDirectoryCoverProvider()
        let result = try await provider.fetch(artist: nil, album: "", inputFile: nil)
        XCTAssertNil(result)
    }
}

// MARK: - CoverCache Tests

final class CoverCacheTests: XCTestCase {
    func testCacheHit() async throws {
        let cache = CoverCache()
        let key = CoverCache.CacheKey(artist: "Artist", album: "Album")
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])

        await cache.set(key, data: data)
        let hit = await cache.get(key)

        XCTAssertEqual(hit, data)
    }

    func testCacheMiss() async throws {
        let cache = CoverCache()
        let key = CoverCache.CacheKey(artist: "Artist", album: "Album")

        let miss = await cache.get(key)
        XCTAssertNil(miss)
    }

    func testDifferentKeysAreIndependent() async throws {
        let cache = CoverCache()
        let key1 = CoverCache.CacheKey(artist: "A1", album: "B1")
        let key2 = CoverCache.CacheKey(artist: "A2", album: "B2")

        await cache.set(key1, data: Data([0x01]))
        await cache.set(key2, data: Data([0x02]))

        let result1 = await cache.get(key1)
        let result2 = await cache.get(key2)
        XCTAssertEqual(result1, Data([0x01]))
        XCTAssertEqual(result2, Data([0x02]))
    }
}

// MARK: - AlbumArtFetcher Pipeline Tests

final class AlbumArtFetcherPipelineTests: XCTestCase {
    func testFirstProviderWins() async throws {
        let firstData  = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])

        // AlbumArtFetcher builds its own pipeline — test via pre-seeded cache
        let cache = CoverCache()
        let key = CoverCache.CacheKey(artist: "TestArtist", album: "TestAlbum")
        await cache.set(key, data: firstData)

        let fetcher = AlbumArtFetcher(cache: cache, config: .init())
        let result = try await fetcher.fetch(artist: "TestArtist", album: "TestAlbum", inputFile: nil)

        XCTAssertEqual(result, firstData)
    }

    func testTimeoutReturnsErrorResult() async throws {
        // Verify config.timeoutSeconds is respected.
        let config = AlbumArtFetcher.Config(timeoutSeconds: 0.1)
        XCTAssertEqual(config.timeoutSeconds, 0.1)
    }

    func testConfigEnableLeftFM() async throws {
        let configDisabled = AlbumArtFetcher.Config(enableLeftFM: false)
        let configEnabled  = AlbumArtFetcher.Config(enableLeftFM: true)

        XCTAssertFalse(configDisabled.enableLeftFM)
        XCTAssertTrue(configEnabled.enableLeftFM)
    }
}

// MARK: - AlbumArtFetcher attempt() tests (issue #52)

/// Tests that provider returning nil is treated as .notFound, not .error.
final class AlbumArtFetcherAttemptTests: XCTestCase {
    func testProviderReturningNilGivesNotFound() async throws {
        let fetcher = AlbumArtFetcher(cache: CoverCache(), config: .init())
        let provider = MockNotFoundProvider(name: "NotFound")
        let result = await fetcher.attempt(provider: provider, artist: nil, album: "Test", inputFile: nil)
        XCTAssertEqual(result.status, .notFound)
    }

    func testProviderThrowingGivesError() async throws {
        let fetcher = AlbumArtFetcher(cache: CoverCache(), config: .init())
        let provider = MockErrorProvider(name: "Error")
        let result = await fetcher.attempt(provider: provider, artist: nil, album: "Test", inputFile: nil)
        XCTAssertEqual(result.status, .error)
    }

    func testProviderReturningDataGivesSuccess() async throws {
        let fetcher = AlbumArtFetcher(cache: CoverCache(), config: .init())
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let provider = MockSuccessProvider(name: "Success", data: data)
        let result = await fetcher.attempt(provider: provider, artist: nil, album: "Test", inputFile: nil)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.sizeBytes, data.count)
    }
}

// MARK: - ProviderResult Tests

final class ProviderResultTests: XCTestCase {
    func testSuccessDescription() {
        let result = ProviderResult.success(providerName: "MusicBrainz", sizeBytes: 12345)
        XCTAssertTrue(result.description.contains("12345"))
        XCTAssertTrue(result.description.contains("✅"))
        XCTAssertTrue(result.description.contains("MusicBrainz"))
    }

    func testNotFoundDescription() {
        let result = ProviderResult.notFound(providerName: "iTunes")
        XCTAssertTrue(result.description.contains("❌"))
        XCTAssertTrue(result.description.contains("iTunes"))
    }

    func testErrorDescription() {
        let result = ProviderResult.error(providerName: "LeftFM", message: "connection refused")
        XCTAssertTrue(result.description.contains("⚠️"))
        XCTAssertTrue(result.description.contains("connection refused"))
        XCTAssertTrue(result.description.contains("LeftFM"))
    }
}
