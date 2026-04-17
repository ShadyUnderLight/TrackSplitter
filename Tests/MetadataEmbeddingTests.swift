import Foundation
@testable import TrackSplitterLib
import XCTest

/// End-to-end metadata embedding tests for FLAC, MP3, and M4A.
/// Uses Python's mutagen to read back written tags and verify correctness.
///
/// These tests validate the actual field mapping described in docs/METADATA_MATRIX.md.
/// Note: albumArtist is not yet plumbed through the Swift embedBatch API; that is
/// tracked separately. These tests focus on fields that ARE currently supported.
final class MetadataEmbeddingTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!
    private var embedder: MetadataEmbedder!

    private func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func pythonPath() -> String? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracksplitter_meta_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        embedder = MetadataEmbedder(timeoutSeconds: 30)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - FLAC

    func testEmbedFLAC_allFields() async throws {
        guard let ffmpeg = ffmpegPath() else { throw XCTSkip("ffmpeg not found") }

        let input = tempDir.appendingPathComponent("test.flac")
        try createAudio(at: input, ext: "flac", ffmpegPath: ffmpeg, duration: 1.0)

        try await embedder.embedBatch(
            files: [(url: input, title: "Nightflight", trackNumber: 3)],
            artist: "David Bowie",
            album: "Heroes",
            year: "1977",
            genre: "Rock",
            comment: nil,
            composer: "Bowie",
            discNumber: "1",
            totalTracks: 14,
            coverData: nil
        )

        let tags = try readFLACTags(at: input)
        // Vorbis comment keys are case-insensitive; mutagen returns lowercase keys
        XCTAssertEqual(tags["title"], "Nightflight")
        XCTAssertEqual(tags["artist"], "David Bowie")
        XCTAssertEqual(tags["album"], "Heroes")
        XCTAssertEqual(tags["date"], "1977")
        XCTAssertEqual(tags["genre"], "Rock")
        XCTAssertEqual(tags["tracknumber"], "3")
        XCTAssertEqual(tags["totaltracks"], "14")
        XCTAssertEqual(tags["composer"], "Bowie")
        XCTAssertEqual(tags["discnumber"], "1")
        // YEAR must NOT be written (DATE is the canonical year field in Vorbis)
        XCTAssertNil(tags["year"],
                     "YEAR must not be written — DATE is the canonical Vorbis year field")
        // ALBUMARTIST requires Swift protocol change; not asserted here
    }

    func testEmbedFLAC_duplicateYearNotWritten() async throws {
        guard let ffmpeg = ffmpegPath() else { throw XCTSkip("ffmpeg not found") }

        let input = tempDir.appendingPathComponent("test.flac")
        try createAudio(at: input, ext: "flac", ffmpegPath: ffmpeg, duration: 1.0)

        try await embedder.embedBatch(
            files: [(url: input, title: "Track", trackNumber: 1)],
            artist: "Artist",
            album: "Album",
            year: "1985",
            genre: "Pop",
            comment: nil,
            composer: nil,
            discNumber: nil,
            totalTracks: 1,
            coverData: nil
        )

        let tags = try readFLACTags(at: input)
        XCTAssertEqual(tags["date"], "1985")
        XCTAssertNil(tags["year"], "Only DATE should be written; YEAR must not be set")
    }

    // MARK: - MP3

    func testEmbedMP3_allFields() async throws {
        guard let ffmpeg = ffmpegPath() else { throw XCTSkip("ffmpeg not found") }

        let input = tempDir.appendingPathComponent("test.mp3")
        try createAudio(at: input, ext: "mp3", ffmpegPath: ffmpeg, duration: 1.0)

        try await embedder.embedBatch(
            files: [(url: input, title: "Albatross", trackNumber: 2)],
            artist: "Fleetwood Mac",
            album: "Rumours",
            year: "1977",
            genre: "Rock",
            comment: "Classic",
            composer: "Lindsey Buckingham",
            discNumber: "1",
            totalTracks: 11,
            coverData: nil
        )

        let tags = try readMP3Tags(at: input)
        XCTAssertEqual(tags["TIT2"], "Albatross")
        XCTAssertEqual(tags["TPE1"], "Fleetwood Mac")
        XCTAssertEqual(tags["TALB"], "Rumours")
        XCTAssertEqual(tags["TDRC"], "1977")
        XCTAssertEqual(tags["TCON"], "Rock")
        XCTAssertEqual(tags["TRCK"], "2")
        XCTAssertEqual(tags["TPOS"], "1")             // disc number via TPOS
        XCTAssertEqual(tags["TCOM"], "Lindsey Buckingham") // composer
        XCTAssertEqual(tags["COMM::eng"], "Classic")
        // TPE2 (album artist) and TCOM (composer) require Swift protocol change
    }

    func testEmbedMP3_discNumberWrittenAsTPOS() async throws {
        guard let ffmpeg = ffmpegPath() else { throw XCTSkip("ffmpeg not found") }

        let input = tempDir.appendingPathComponent("test.mp3")
        try createAudio(at: input, ext: "mp3", ffmpegPath: ffmpeg, duration: 1.0)

        try await embedder.embedBatch(
            files: [(url: input, title: "Side-A", trackNumber: 1)],
            artist: "Artist",
            album: "Album",
            year: "2020",
            genre: "Jazz",
            comment: nil,
            composer: nil,
            discNumber: "2",
            totalTracks: 6,
            coverData: nil
        )

        let tags = try readMP3Tags(at: input)
        XCTAssertEqual(tags["TPOS"], "2", "Disc number must be written as TPOS (ID3v2)")
    }

    // MARK: - M4A

    func testEmbedM4A_allFields() async throws {
        guard let ffmpeg = ffmpegPath() else { throw XCTSkip("ffmpeg not found") }

        let input = tempDir.appendingPathComponent("test.m4a")
        try createAudio(at: input, ext: "m4a", ffmpegPath: ffmpeg, duration: 1.0)

        try await embedder.embedBatch(
            files: [(url: input, title: "Overture", trackNumber: 1)],
            artist: "Test Artist",
            album: "Test Album",
            year: "2023",
            genre: "Classical",
            comment: "Note",
            composer: "Composer Name",
            discNumber: nil,
            totalTracks: 5,
            coverData: nil
        )

        let tags = try readM4ATags(at: input)
        // M4A keys are parsed as actual unicode strings from JSON (© = U+00A9)
        let nam = "\u{00A9}nam"
        let art = "\u{00A9}ART"
        let alb = "\u{00A9}alb"
        let day = "\u{00A9}day"
        let gen = "\u{00A9}gen"
        let wrt = "\u{00A9}wrt"
        let cmt = "\u{00A9}cmt"
        XCTAssertEqual(tags[nam], "Overture")
        XCTAssertEqual(tags[art], "Test Artist")
        XCTAssertEqual(tags[alb], "Test Album")
        XCTAssertEqual(tags[day], "2023")
        XCTAssertEqual(tags[gen], "Classical")
        XCTAssertEqual(tags[wrt], "Composer Name")
        XCTAssertEqual(tags[cmt], "Note")
        // trkn: (track, total) — encoded as list of (track, total) tuples
        XCTAssertEqual(tags["trkn"], "(1, 5)")
        // album artist (©aART) and disc number require Swift protocol change
    }

    // MARK: - Environment check

    func testCheckEnvironment_healthy() async throws {
        guard pythonPath() != nil else { throw XCTSkip("python3 not found") }
        let report = await embedder.checkEnvironment()
        XCTAssertTrue(report.isHealthy, "Environment must be healthy; issues: \(report.issues)")
    }

    // MARK: - Audio file creation

    private func createAudio(at url: URL, ext: String, ffmpegPath: String, duration: Double) throws {
        let codec: String
        switch ext {
        case "flac": codec = "flac"
        case "mp3":  codec = "libmp3lame"
        case "m4a":  codec = "aac"
        default:     codec = "pcm_s16le"
        }
        let args = ["-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                    "-t", String(duration), "-acodec", codec, url.path]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            throw NSError(domain: "MetadataEmbeddingTests", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create \(ext) test file"])
        }
    }
}

// MARK: - Python mutagen readers

extension MetadataEmbeddingTests {

    private func readFLACTags(at url: URL) throws -> [String: String] {
        guard let python = pythonPath() else { throw XCTSkip("python3 not found") }
        let escapedPath = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        import json
        from mutagen.flac import FLAC
        audio = FLAC("\(escapedPath)")
        result = {k: str(v[0]) for k, v in audio.items()}
        print(json.dumps(result))
        """
        return try runPythonRead(python: python, script: script)
    }

    private func readMP3Tags(at url: URL) throws -> [String: String] {
        guard let python = pythonPath() else { throw XCTSkip("python3 not found") }
        let escapedPath = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        import json
        from mutagen.mp3 import MP3
        audio = MP3("\(escapedPath)")
        result = {}
        if audio.tags:
            for k in audio.tags.keys():
                result[str(k)] = str(audio.tags[k])
        print(json.dumps(result))
        """
        return try runPythonRead(python: python, script: script)
    }

    private func readM4ATags(at url: URL) throws -> [String: String] {
        guard let python = pythonPath() else { throw XCTSkip("python3 not found") }
        let escapedPath = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        import json
        from mutagen.mp4 import MP4
        audio = MP4("\(escapedPath)")
        result = {}
        for k, v in audio.items():
            key = k.hex() if isinstance(k, bytes) else str(k)
            val = str(v[0]) if hasattr(v[0], '__str__') else str(v)
            result[key] = val
        print(json.dumps(result))
        """
        return try runPythonRead(python: python, script: script)
    }

    private func runPythonRead(python: String, script: String) throws -> [String: String] {
        let result = try runPython(python: python, script: script)
        guard let data = result.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw NSError(domain: "MetadataEmbeddingTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to parse Python output: \(result)"])
        }
        return tags
    }

    private func runPython(python: String, script: String) throws -> String {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", script]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
