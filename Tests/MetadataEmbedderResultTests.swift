import Foundation
@testable import TrackSplitterLib
import XCTest

/// Tests for MetadataEmbedder.EmbedResult parsing logic and computed properties.
/// The result-parsing logic mirrors what embedBatch() does when consuming Python stdout.
final class MetadataEmbedderResultTests: XCTestCase {

    // MARK: - EmbedResult computed properties

    func testFullySuccessful_allSucceeded() {
        let result = MetadataEmbedder.EmbedResult(
            total: 3, succeeded: 3, failed: 0, failures: [], coverWasSkipped: false
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
    }

    func testFullySuccessful_allSucceededWithSkipped() {
        // SKIP: cover art skipped still counts as succeeded
        let result = MetadataEmbedder.EmbedResult(
            total: 3, succeeded: 3, failed: 0, failures: [], coverWasSkipped: true
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
        XCTAssertTrue(result.coverWasSkipped)
    }

    func testPartiallySuccessful() {
        let result = MetadataEmbedder.EmbedResult(
            total: 3, succeeded: 2, failed: 1, failures: ["file2.flac: encoding error"], coverWasSkipped: false
        )
        XCTAssertFalse(result.isFullySuccessful)
        XCTAssertTrue(result.isPartiallySuccessful)
    }

    func testAllFailed() {
        let result = MetadataEmbedder.EmbedResult(
            total: 3, succeeded: 0, failed: 3, failures: ["f1.flac", "f2.flac", "f3.flac"], coverWasSkipped: false
        )
        XCTAssertFalse(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
        XCTAssertEqual(result.failed, 3)
    }

    func testZeroTotals() {
        // With total=0 and no failures, isFullySuccessful is true (failed==0).
        // isPartiallySuccessful is false (succeeded==0 && failed==0).
        let result = MetadataEmbedder.EmbedResult(
            total: 0, succeeded: 0, failed: 0, failures: [], coverWasSkipped: false
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
    }

    // MARK: - Python stdout line parsing

    /// Mirrors the parsing logic in MetadataEmbedder.embedBatch.
    func parsePythonStdout(_ stdout: String) -> (succeeded: Int, failed: Int, failures: [String], coverWasSkipped: Bool) {
        var succeeded = 0
        var failed = 0
        var failures: [String] = []
        var coverWasSkipped = false

        for line in stdout.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
            if line.hasPrefix("DONE: ") {
                succeeded += 1
            } else if line.hasPrefix("SKIP: ") {
                succeeded += 1
                if line.contains("cover art skipped") {
                    coverWasSkipped = true
                }
            } else if line.hasPrefix("ERROR: ") {
                failed += 1
                failures.append(String(line.dropFirst(7)))
            }
        }

        return (succeeded, failed, failures, coverWasSkipped)
    }

    func testParseStdout_allDONE() {
        let stdout = "DONE: file1.flac\nDONE: file2.flac\n"
        let (succeeded, failed, failures, coverWasSkipped) = parsePythonStdout(stdout)
        XCTAssertEqual(succeeded, 2)
        XCTAssertEqual(failed, 0)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(coverWasSkipped)
    }

    func testParseStdout_mixedDONESKIPERROR() {
        let stdout = """
        DONE: file1.flac
        SKIP: file2.wav (cover art skipped)
        ERROR: file3.mp3 invalid tag
        """
        let (succeeded, failed, failures, coverWasSkipped) = parsePythonStdout(stdout)
        XCTAssertEqual(succeeded, 2)
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(failures, ["file3.mp3 invalid tag"])
        XCTAssertTrue(coverWasSkipped)
    }

    func testParseStdout_emptyLinesIgnored() {
        let stdout = "DONE: file1.flac\n\nDONE: file2.flac\n  \n"
        let (succeeded, failed, _, _) = parsePythonStdout(stdout)
        XCTAssertEqual(succeeded, 2)
        XCTAssertEqual(failed, 0)
    }

    func testParseStdout_noMatch() {
        let stdout = "something went wrong\nrandom output"
        let (succeeded, failed, failures, _) = parsePythonStdout(stdout)
        XCTAssertEqual(succeeded, 0)
        XCTAssertEqual(failed, 0)
        XCTAssertTrue(failures.isEmpty)
    }

    func testParseStdout_coverWasSkippedOnly() {
        let stdout = "SKIP: track.wav (unsupported format, cover art skipped)"
        let (_, _, _, coverWasSkipped) = parsePythonStdout(stdout)
        XCTAssertTrue(coverWasSkipped)
    }

    // MARK: - EmbedResult round-trip

    func testEmbedResult_roundTripFullySuccessful() {
        let stdout = "DONE: a.flac\nDONE: b.flac\nDONE: c.flac\n"
        let parsed = parsePythonStdout(stdout)
        let result = MetadataEmbedder.EmbedResult(
            total: 3,
            succeeded: parsed.succeeded,
            failed: parsed.failed,
            failures: parsed.failures,
            coverWasSkipped: parsed.coverWasSkipped
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertEqual(result.succeeded, 3)
        XCTAssertEqual(result.failed, 0)
    }

    func testEmbedResult_roundTripPartial() {
        let stdout = """
        DONE: good.flac
        ERROR: bad.flac: permission denied
        """
        let parsed = parsePythonStdout(stdout)
        let result = MetadataEmbedder.EmbedResult(
            total: 2,
            succeeded: parsed.succeeded,
            failed: parsed.failed,
            failures: parsed.failures,
            coverWasSkipped: parsed.coverWasSkipped
        )
        XCTAssertTrue(result.isPartiallySuccessful)
        XCTAssertEqual(result.failures, ["bad.flac: permission denied"])
    }
}
