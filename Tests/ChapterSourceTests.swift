import Foundation
@testable import TrackSplitterLib
import XCTest

final class ChapterSourceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracksplitter_chapter_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - TextChapterParser

    func testTextChapterParser_basicFormat() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        try """
        00:00:00 Track 1
        00:03:45 Track 2
        00:07:30 Track 3
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].title, "Track 1")
        XCTAssertEqual(entries[0].startSeconds, 0)
        XCTAssertEqual(entries[1].title, "Track 2")
        XCTAssertEqual(entries[1].startSeconds, 225)
        XCTAssertEqual(entries[2].title, "Track 3")
        XCTAssertEqual(entries[2].startSeconds, 450)
    }

    func testTextChapterParser_MMSS_semantics() throws {
        // Issue #55: 03:45 must be interpreted as 3 minutes 45 seconds (=225s),
        // NOT 3 hours 45 minutes (=13500s).
        let file = tempDir.appendingPathComponent("chapters.txt")
        try "03:45 Title\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].startSeconds, 225)  // 3*60 + 45 = 225
        XCTAssertEqual(entries[0].title, "Title")
    }

    func testTextChapterParser_HHMMSSSemantics() throws {
        // 1:02:03 = 1h 02m 03s = 3723s
        let file = tempDir.appendingPathComponent("chapters.txt")
        try "1:02:03 Title\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].startSeconds, 3723)  // 1*3600 + 2*60 + 3
    }

    func testTextChapterParser_bracketMMSS() throws {
        // [03:45] = 3 minutes 45 seconds = 225s (MM:SS inside brackets)
        let file = tempDir.appendingPathComponent("chapters.txt")
        try "[03:45] Title\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].startSeconds, 225)
    }

    func testTextChapterParser_subseconds() throws {
        // 00:03:45.500 = 3m 45.5s = 225.5s
        let file = tempDir.appendingPathComponent("chapters.txt")
        try "00:03:45.500 Title\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].startSeconds, 225.5, accuracy: 0.001)
    }

    func testTextChapterParser_dashSeparator() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        try """
        00:00:00 - Opening
        00:02:30 - Main Track
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries[0].title, "Opening")
        XCTAssertEqual(entries[1].title, "Main Track")
    }

    func testTextChapterParser_bracketsFormat() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        try """
        [00:00:00] First
        [00:05:00] Second
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "First")
        XCTAssertEqual(entries[0].startSeconds, 0)
        XCTAssertEqual(entries[1].startSeconds, 300)
    }

    func testTextChapterParser_withSubseconds() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        try "00:00:00.500 First Track\n00:01:00.000 Second Track\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries[0].startSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(entries[1].startSeconds, 60.0, accuracy: 0.001)
    }

    func testTextChapterParser_commentsSkipped() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        try """
        # This is a comment
        00:00:00 Track 1
        // Another comment
        00:02:00 Track 2
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "Track 1")
        XCTAssertEqual(entries[1].title, "Track 2")
    }

    func testTextChapterParser_emptyLinesSkipped() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        try "\n\n00:00:00 Track 1\n\n\n00:02:00 Track 2\n\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 2)
    }

    func testTextChapterParser_missingTitle() throws {
        let file = tempDir.appendingPathComponent("chapters.txt")
        // Title-only line with no text after timestamp → default title used
        try "00:00:00\n00:03:00\n".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file, defaultTitle: "Track")

        XCTAssertEqual(entries[0].title, "Track 1")
        XCTAssertEqual(entries[1].title, "Track 2")
    }

    func testTextChapterParser_unsortedEntries() throws {
        // Parser should sort by timestamp even if file is out of order
        let file = tempDir.appendingPathComponent("chapters.txt")
        try """
        00:05:00 Track 3
        00:00:00 Track 1
        00:02:30 Track 2
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries[0].startSeconds, 0)
        XCTAssertEqual(entries[1].startSeconds, 150)
        XCTAssertEqual(entries[2].startSeconds, 300)
    }

    func testTextChapterParser_fileNotFound() throws {
        let file = tempDir.appendingPathComponent("nonexistent.txt")
        let parser = TextChapterParser()
        do {
            _ = try parser.parse(at: file)
            XCTFail("Expected Error.fileNotFound")
        } catch let error as TextChapterParser.Error {
            if case .fileNotFound = error { /* expected */ } else { XCTFail("Wrong error type: \(error)") }
        }
    }

    func testTextChapterParser_noValidTimestamps() throws {
        let file = tempDir.appendingPathComponent("no_ts.txt")
        try "This file has no timestamps\nJust plain text".write(to: file, atomically: true, encoding: .utf8)

        let parser = TextChapterParser()
        do {
            _ = try parser.parse(at: file)
            XCTFail("Expected Error.noValidTimestamps")
        } catch let error as TextChapterParser.Error {
            if case .noValidTimestamps = error { /* expected */ } else { XCTFail("Wrong error type: \(error)") }
        }
    }

    // MARK: - FFmpegChapterParser

    func testFFmpegChapterParser_basic() throws {
        let file = tempDir.appendingPathComponent("chapters.meta")
        try """
        ;FFMETADATA1
        title=Album Title
        artist=Album Artist
        CHAPTER0000=00:00:00.000
        CHAPTER0000NAME=First Track
        CHAPTER0001=00:03:45.000
        CHAPTER0001NAME=Second Track
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = FFmpegChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "First Track")
        XCTAssertEqual(entries[0].startSeconds, 0)
        XCTAssertEqual(entries[1].title, "Second Track")
        XCTAssertEqual(entries[1].startSeconds, 225)
    }

    func testFFmpegChapterParser_noTimestampTitle() throws {
        let file = tempDir.appendingPathComponent("chapters.meta")
        try """
        ;FFMETADATA1
        CHAPTER0000=00:00:00.000
        CHAPTER0000NAME=
        CHAPTER0001=00:02:00.000
        CHAPTER0001NAME=Named Track
        """.write(to: file, atomically: true, encoding: .utf8)

        let parser = FFmpegChapterParser()
        let entries = try parser.parse(at: file)

        XCTAssertEqual(entries[0].title, "Chapter 1")   // empty name → default
        XCTAssertEqual(entries[1].title, "Named Track")
    }

    func testFFmpegChapterParser_fileNotFound() throws {
        let file = tempDir.appendingPathComponent("nonexistent.meta")
        let parser = FFmpegChapterParser()
        do {
            _ = try parser.parse(at: file)
            XCTFail("Expected Error.fileNotFound")
        } catch let error as FFmpegChapterParser.Error {
            if case .fileNotFound = error { /* expected */ } else { XCTFail("Wrong error: \(error)") }
        }
    }

    // MARK: - ChapterSource

    func testChapterSource_typeName() {
        XCTAssertEqual(ChapterSource.cue(URL(fileURLWithPath: "/a")).typeName, "CUE")
        XCTAssertEqual(ChapterSource.textChapters(URL(fileURLWithPath: "/a")).typeName, "Text chapters")
        XCTAssertEqual(ChapterSource.ffmpegChapters(URL(fileURLWithPath: "/a")).typeName, "FFmpeg chapters")
        XCTAssertEqual(ChapterSource.embedded(URL(fileURLWithPath: "/a")).typeName, "Embedded chapters")
    }

    func testChapterSource_url() {
        let url = URL(fileURLWithPath: "/path/to/file.txt")
        XCTAssertEqual(ChapterSource.cue(url).url, url)
        XCTAssertEqual(ChapterSource.textChapters(url).url, url)
        XCTAssertEqual(ChapterSource.ffmpegChapters(url).url, url)
        XCTAssertEqual(ChapterSource.embedded(url).url, url)
    }
}
