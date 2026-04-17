import Foundation
@testable import TrackSplitterLib
import XCTest

/// Tests for EngineOutcome model and cleanup() behavior.
final class EngineOutcomeTests: XCTestCase {

    // MARK: - Outcome.Status classification

    func testSuccess_hasSuccessStatus() {
        let output = makeOutput(trackCount: 3)
        let outcome = TrackSplitterEngine.EngineOutcome.success(output)
        XCTAssertEqual(outcome.status, .success)
        XCTAssertTrue(outcome.output != nil)
    }

    func testPartialSuccess_hasPartialSuccessStatus() {
        let output = makeOutput(trackCount: 3)
        let outcome = TrackSplitterEngine.EngineOutcome.partialSuccess(output, metadataFailures: ["track2.flac: error"])
        XCTAssertEqual(outcome.status, .partialSuccess)
        XCTAssertTrue(outcome.output != nil)
    }

    func testFailure_hasFailureStatus() {
        let outcome = TrackSplitterEngine.EngineOutcome.failure(message: "no cue file")
        XCTAssertEqual(outcome.status, .failure)
        XCTAssertNil(outcome.output)
    }

    // MARK: - Outcome.summary

    func testSuccessSummary_containsTrackCount() {
        let output = makeOutput(trackCount: 5)
        let outcome = TrackSplitterEngine.EngineOutcome.success(output)
        let summary = outcome.summary
        XCTAssertTrue(summary.contains("5"))
        XCTAssertTrue(summary.contains("成功"))
    }

    func testPartialSuccessSummary_containsTrackCountAndMetadataFailures() {
        let output = makeOutput(trackCount: 4)
        let outcome = TrackSplitterEngine.EngineOutcome.partialSuccess(
            output,
            metadataFailures: ["a.flac: bad tags", "b.flac: io error"]
        )
        let summary = outcome.summary
        XCTAssertTrue(summary.contains("4"))
        XCTAssertTrue(summary.contains("2")) // 2 metadata failures
    }

    func testFailureSummary_containsMessage() {
        let outcome = TrackSplitterEngine.EngineOutcome.failure(message: "splitting cancelled")
        XCTAssertTrue(outcome.summary.contains("splitting cancelled"))
    }

    // MARK: - Outcome.output accessor

    func testOutputAccessor_returnsOutputForSuccess() {
        let output = makeOutput(trackCount: 2)
        let outcome = TrackSplitterEngine.EngineOutcome.success(output)
        XCTAssertEqual(outcome.output?.trackFiles.count, 2)
    }

    func testOutputAccessor_returnsOutputForPartialSuccess() {
        let output = makeOutput(trackCount: 2)
        let outcome = TrackSplitterEngine.EngineOutcome.partialSuccess(output, metadataFailures: [])
        XCTAssertEqual(outcome.output?.trackFiles.count, 2)
    }

    func testOutputAccessor_returnsNilForFailure() {
        let outcome = TrackSplitterEngine.EngineOutcome.failure(message: "boom")
        XCTAssertNil(outcome.output)
    }

    // MARK: - Result.init(from:) deprecated path

    func testLegacyResultInit_fromSuccess() throws {
        let output = makeOutput(trackCount: 3)
        let outcome = TrackSplitterEngine.EngineOutcome.success(output)
        let result = try TrackSplitterEngine.Result(from: outcome)
        XCTAssertEqual(result.trackFiles.count, 3)
        XCTAssertEqual(result.albumTitle, "Test Album")
    }

    func testLegacyResultInit_fromPartialSuccess() throws {
        let output = makeOutput(trackCount: 3)
        let outcome = TrackSplitterEngine.EngineOutcome.partialSuccess(output, metadataFailures: ["err"])
        let result = try TrackSplitterEngine.Result(from: outcome)
        XCTAssertEqual(result.trackFiles.count, 3)
    }

    func testLegacyResultInit_fromFailure_throws() {
        let outcome = TrackSplitterEngine.EngineOutcome.failure(message: "no output")
        do {
            _ = try TrackSplitterEngine.Result(from: outcome)
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected
        }
    }

    // MARK: - cleanup()

    func testCleanup_onEmptyEngine_doesNotCrash() async {
        let engine = TrackSplitterEngine()
        // Should not throw even when _lastOutput is nil
        await engine.cleanup()
    }

    func testStaticCleanup_deletesOutputFilesAndDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let trackFile = tmpDir.appendingPathComponent("track1.flac")
        try "fake audio data".data(using: .utf8)!.write(to: trackFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: trackFile.path))

        let output = TrackSplitterEngine.Output(
            outputDirectory: tmpDir,
            trackFiles: [trackFile],
            albumTitle: nil,
            performer: nil,
            coverEmbedded: false,
            metadataResult: EmbedResult(
                total: 1, succeeded: 1, failed: 0, failures: [], coverWasSkipped: false
            )
        )

        TrackSplitterEngine.cleanup(output: output)

        XCTAssertFalse(FileManager.default.fileExists(atPath: trackFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.path))
    }

    // MARK: - Helpers

    private func makeOutput(trackCount: Int, albumName: String = "Test Album") -> TrackSplitterEngine.Output {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Note: we don't actually create the directory — Output just holds the URL.
        let files = (0..<trackCount).map { tmpDir.appendingPathComponent("track\($0 + 1).flac") }
        return TrackSplitterEngine.Output(
            outputDirectory: tmpDir,
            trackFiles: files,
            albumTitle: albumName,
            performer: "Test Artist",
            coverEmbedded: true,
            metadataResult: EmbedResult(
                total: trackCount,
                succeeded: trackCount,
                failed: 0,
                failures: [],
                coverWasSkipped: false
            )
        )
    }
}
