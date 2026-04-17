import Foundation
@testable import TrackSplitterLib
import XCTest

/// Tests for PythonMetadataAdapter stdout parsing and EmbedResult construction.
/// Calls the production `PythonMetadataAdapter.parseOutput()` directly to ensure
/// tests exercise the actual production code path.
final class MetadataEmbedderResultTests: XCTestCase {

    // MARK: - EmbedResult computed properties

    func testFullySuccessful_allSucceeded() {
        let result = EmbedResult(
            total: 3, succeeded: 3, failed: 0, failures: [], coverWasSkipped: false
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
    }

    func testFullySuccessful_allSucceededWithSkipped() {
        let result = EmbedResult(
            total: 3, succeeded: 3, failed: 0, failures: [], coverWasSkipped: true
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
        XCTAssertTrue(result.coverWasSkipped)
    }

    func testPartiallySuccessful() {
        let result = EmbedResult(
            total: 3, succeeded: 2, failed: 1, failures: ["file2.flac: encoding error"], coverWasSkipped: false
        )
        XCTAssertFalse(result.isFullySuccessful)
        XCTAssertTrue(result.isPartiallySuccessful)
    }

    func testAllFailed() {
        let result = EmbedResult(
            total: 3, succeeded: 0, failed: 3, failures: ["f1.flac", "f2.flac", "f3.flac"], coverWasSkipped: false
        )
        XCTAssertFalse(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
        XCTAssertEqual(result.failed, 3)
    }

    func testZeroTotals() {
        // With total=0 and no failures, isFullySuccessful is true (failed==0).
        let result = EmbedResult(
            total: 0, succeeded: 0, failed: 0, failures: [], coverWasSkipped: false
        )
        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertFalse(result.isPartiallySuccessful)
    }

    // MARK: - Production parseOutput() — directly tests production code

    func testParseOutput_allDONE() {
        let stdout = "DONE: file1.flac\nDONE: file2.flac\n"
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        XCTAssertEqual(parsed.succeeded, 2)
        XCTAssertEqual(parsed.failed, 0)
        XCTAssertTrue(parsed.failures.isEmpty)
        XCTAssertFalse(parsed.coverWasSkipped)
    }

    func testParseOutput_mixedDONESKIPERROR() {
        let stdout = """
        DONE: file1.flac
        SKIP: file2.wav (cover art skipped)
        ERROR: file3.mp3 invalid tag
        """
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        XCTAssertEqual(parsed.succeeded, 2)
        XCTAssertEqual(parsed.failed, 1)
        XCTAssertEqual(parsed.failures, ["file3.mp3 invalid tag"])
        XCTAssertTrue(parsed.coverWasSkipped)
    }

    func testParseOutput_emptyLinesIgnored() {
        let stdout = "DONE: file1.flac\n\nDONE: file2.flac\n  \n"
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        XCTAssertEqual(parsed.succeeded, 2)
        XCTAssertEqual(parsed.failed, 0)
    }

    func testParseOutput_noMatch() {
        let stdout = "something went wrong\nrandom output"
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        XCTAssertEqual(parsed.succeeded, 0)
        XCTAssertEqual(parsed.failed, 0)
        XCTAssertTrue(parsed.failures.isEmpty)
    }

    func testParseOutput_coverWasSkippedOnly() {
        let stdout = "SKIP: track.wav (unsupported format, cover art skipped)"
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        XCTAssertEqual(parsed.succeeded, 1)
        XCTAssertTrue(parsed.coverWasSkipped)
    }

    func testParseOutput_multipleErrors() {
        let stdout = """
        ERROR: a.flac: permission denied
        ERROR: b.flac: io error
        DONE: c.flac
        """
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        XCTAssertEqual(parsed.succeeded, 1)
        XCTAssertEqual(parsed.failed, 2)
        XCTAssertEqual(parsed.failures, ["a.flac: permission denied", "b.flac: io error"])
    }

    // MARK: - End-to-end EmbedResult via parseOutput()

    func testEmbedResult_roundTripFullySuccessful() {
        let stdout = "DONE: a.flac\nDONE: b.flac\nDONE: c.flac\n"
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        let result = EmbedResult(
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
        let parsed = PythonMetadataAdapter.parseOutput(stdout)
        let result = EmbedResult(
            total: 2,
            succeeded: parsed.succeeded,
            failed: parsed.failed,
            failures: parsed.failures,
            coverWasSkipped: parsed.coverWasSkipped
        )
        XCTAssertTrue(result.isPartiallySuccessful)
        XCTAssertEqual(result.failures, ["bad.flac: permission denied"])
    }

    // MARK: - Runtime script discovery (issue #18 follow-up)

    /// Validates that embed_metadata.py is discoverable at runtime via Bundle.module
    /// (the SwiftPM resource path). This test fails if the script is not correctly
    /// placed in Library/Resources/ and declared in Package.swift.
    func testScriptIsDiscoverableViaBundleResource() {
        let bundleURL = Bundle.module.url(forResource: "embed_metadata", withExtension: "py")
        XCTAssertNotNil(bundleURL, "embed_metadata.py must be in Library/Resources/ and declared as a SwiftPM resource")
        if let url = bundleURL {
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path),
                "embed_metadata.py at \(url.path) must be readable")
        }
    }

}
