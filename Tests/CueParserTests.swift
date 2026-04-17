import Foundation
@testable import TrackSplitterLib
import XCTest

/// Tests for CueParser: CUE sheet parsing, string similarity, and findCue fallback logic.
final class CueParserTests: XCTestCase {

    // MARK: - stringSimilarity

    func testStringSimilarity_identical() {
        XCTAssertEqual(stringSimilarity("track 1", "track 1"), 1.0)
    }

    func testStringSimilarity_empty() {
        XCTAssertEqual(stringSimilarity("", ""), 1.0)
        XCTAssertEqual(stringSimilarity("abc", ""), 0.0)
        XCTAssertEqual(stringSimilarity("", "abc"), 0.0)
    }

    func testStringSimilarity_substitution() {
        // "track 1" vs "track 2" — one char diff out of 7
        let ratio = stringSimilarity("track 1", "track 2")
        XCTAssertGreaterThan(ratio, 0.8)
        XCTAssertLessThan(ratio, 1.0)
    }

    func testStringSimilarity_deletion() {
        let ratio = stringSimilarity("track one", "track on")
        XCTAssertGreaterThan(ratio, 0.8)
    }

    func testStringSimilarity_chinese() {
        // Chinese chars differ significantly from ASCII
        let ratio = stringSimilarity("整轨音频", "整軌音頻")
        XCTAssertGreaterThanOrEqual(ratio, 0.5)
    }

    // MARK: - parseCue: basic structure

    func testParseCue_singleTrack() throws {
        let cue = """
        TITLE "Album Title"
        PERFORMER "Album Artist"
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track One"
            PERFORMER "Track Artist"
            INDEX 01 00:00:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.albumTitle, "Album Title")
        XCTAssertEqual(result.performer, "Album Artist")
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks[0].index, 1)
        XCTAssertEqual(result.tracks[0].title, "Track One")
        XCTAssertEqual(result.tracks[0].startSeconds, 0.0, accuracy: 0.01)
        XCTAssertEqual(result.file?.path, "audio.flac")
    }

    func testParseCue_multipleTracks() throws {
        let cue = """
        TITLE "Album Title"
        PERFORMER "Album Artist"
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Track Two"
            INDEX 01 03:00:00
          TRACK 03 AUDIO
            TITLE "Track Three"
            INDEX 01 07:30:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.tracks.count, 3)
        XCTAssertEqual(result.tracks[0].title, "Track One")
        XCTAssertEqual(result.tracks[1].title, "Track Two")
        XCTAssertEqual(result.tracks[2].title, "Track Three")
        // 3 min = 180 sec
        XCTAssertEqual(result.tracks[1].startSeconds, 180.0, accuracy: 0.01)
        // 7:30 = 7*60+30 = 450 sec
        XCTAssertEqual(result.tracks[2].startSeconds, 450.0, accuracy: 0.01)
    }

    // MARK: - parseCue: timestamps (including frames)

    func testParseCue_timestampWithFrames() throws {
        // INDEX 01 01:02:50 → 1*60 + 2 + 50/75 = 62.67s
        let cue = """
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track"
            INDEX 01 01:02:50
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.tracks[0].startSeconds, 62.0 + 50.0/75.0, accuracy: 0.01)
    }

    func testParseCue_timestampNoFrames() throws {
        // Some CUE writers emit INDEX 01 00:00:00 (no frames, always 00)
        let cue = """
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track"
            INDEX 01 00:00:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.tracks[0].startSeconds, 0.0, accuracy: 0.01)
    }

    // MARK: - parseCue: REM fields

    func testParseCue_remFields() throws {
        let cue = """
        REM DATE "2024"
        REM GENRE "Classical"
        REM COMMENT "Live recording"
        REM COMPOSER "Beethoven"
        REM DISCNUMBER "1/2"
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Symphony No.5"
            INDEX 01 00:00:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.rem.date, "2024")
        XCTAssertEqual(result.rem.genre, "Classical")
        XCTAssertEqual(result.rem.comment, "Live recording")
        XCTAssertEqual(result.rem.composer, "Beethoven")
        XCTAssertEqual(result.rem.discNumber, "1/2")
    }

    // MARK: - parseCue: Chinese encoding (iconv fallback)

    func testParseCue_utf8() throws {
        let cue = "FILE \"测试音频.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"测试曲目\"\n    INDEX 01 00:00:00\n"
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.tracks[0].title, "测试曲目")
    }

    // MARK: - parseCue: edge cases

    func testParseCue_missingTrackTitle() throws {
        // Track with no TITLE field — title should be empty string
        let cue = """
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.tracks[0].title, "")
    }

    func testParseCue_performerOnlyOnAlbumLevel() throws {
        // PERFORMER before any TRACK = album performer; per-track performer not always present
        let cue = """
        PERFORMER "Album Artist"
        FILE "audio.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Track Two"
            INDEX 01 03:00:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.performer, "Album Artist")
        XCTAssertEqual(result.tracks.count, 2)
    }

    func testParseCue_filePathWithSpaces() throws {
        let cue = """
        FILE "my audio file.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track"
            INDEX 01 00:00:00
        """
        let url = writeCue(cue)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try parseCue(at: url)
        XCTAssertEqual(result.file?.path, "my audio file.flac")
        XCTAssertEqual(result.file?.resolvedURL.lastPathComponent, "my audio file.flac")
    }

    // MARK: - findCue: exact match

    func testFindCue_exactMatch() throws {
        let dir = tempDir()
        let audioURL = dir.appendingPathComponent("test.flac")
        let cueURL = dir.appendingPathComponent("test.cue")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        FileManager.default.createFile(atPath: cueURL.path, contents: nil)

        let result = findCue(for: audioURL)
        XCTAssertEqual(result, cueURL)
    }

    func testFindCue_exactMatchCaseVariants() throws {
        // Use lowercase throughout — APFS is case-insensitive so test.FLAC matches test.Flac etc.
        let dir = tempDir()
        let audioURL = dir.appendingPathComponent("test.flac")
        let cueURL = dir.appendingPathComponent("test.cue")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        FileManager.default.createFile(atPath: cueURL.path, contents: nil)

        let result = findCue(for: audioURL)
        XCTAssertEqual(result, cueURL)
    }

    // MARK: - findCue: no match

    func testFindCue_noMatchBelowThreshold() throws {
        let dir = tempDir()
        let audioURL = dir.appendingPathComponent("completelydifferent.flac")
        let cueURL = dir.appendingPathComponent("xxx.cue")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        // CUE references "xxx.flac" which is very different from "completelydifferent.flac"
        try """
        FILE "xxx.flac" WAVE
          TRACK 01 AUDIO
            TITLE "X"
            INDEX 01 00:00:00
        """.write(to: cueURL, atomically: true, encoding: .utf8)

        let result = findCue(for: audioURL)
        XCTAssertNil(result)
    }

    // MARK: - findCue: fuzzy fallback

    func testFindCue_fuzzyMatchAbove80Percent() throws {
        let dir = tempDir()
        let audioURL = dir.appendingPathComponent("整轨音频文件.flac")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)

        // CUE references same base name (different extension) — should be high similarity
        let cueURL = dir.appendingPathComponent("整轨音频文件.cue")
        try """
        FILE "整轨音频文件.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Track"
            INDEX 01 00:00:00
        """.write(to: cueURL, atomically: true, encoding: .utf8)

        let result = findCue(for: audioURL)
        XCTAssertEqual(result, cueURL)
    }

    // MARK: - Helpers

    private func writeCue(_ content: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.cue")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
