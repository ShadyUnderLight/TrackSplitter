import Foundation
@testable import TrackSplitterLib
import XCTest

/// Tests for AudioSplitter, focused on the passthrough-failure fallback path (issue #16).
final class AudioSplitterTests: XCTestCase {

    // MARK: - Passthrough-failure fallback: extension matches actual codec

    /// When stream-copy passthrough fails, the fallback must produce a file whose extension
    /// matches its actual codec (WAV), not rename it back to the original non-WAV extension.
    func testPassthroughFailureFallbackExtensionMatchesActualCodec() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.flac")
        try createMinimalFLAC(at: inputURL, durationSeconds: 10.0)

        // Fake ffmpeg: exits 1 when "-acodec copy" is in args; writes a valid WAV otherwise.
        let fakeFFmpegPath = try writeFakeFFmpegScript(failPassthrough: true)
        let splitter = AudioSplitter(ffmpegPath: fakeFFmpegPath, ffprobePath: ffprobePath())

        let tracks = [
            CueTrack(index: 1, title: "Track One", startSeconds: 0, endSeconds: 10)
        ]

        let progressCalled = ThreadSafe(false)
        let outputs = try await splitter.split(
            file: inputURL,
            tracks: tracks,
            to: tempDir,
            outputFormat: nil,
            progressHandler: { _ in progressCalled.value = true }
        )

        XCTAssertEqual(outputs.count, 1)
        let actualURL = outputs[0]

        // The fallback extension must be .wav (matches PCM codec), not .flac (the original ext)
        XCTAssertEqual(actualURL.pathExtension, "wav",
            "Fallback output URL must have .wav extension to match actual PCM codec")

        // The file must actually exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: actualURL.path),
            "Fallback output file must exist at \(actualURL.path)")

        // Verify ffprobe reports WAV
        let format = try probeFormat(of: actualURL)
        XCTAssertTrue(format.lowercased().contains("wav"),
            "ffprobe must report fallback file as WAV, got: \(format)")

        XCTAssertTrue(progressCalled.value, "Progress handler should have been called")
    }

    /// When passthrough succeeds, the output URL must retain the original input extension.
    func testPassthroughSuccessPreservesOriginalExtension() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.mp3")
        try createMinimalMP3(at: inputURL, durationSeconds: 10.0)

        // Fake ffmpeg: always succeeds, writes a valid WAV file.
        let fakeFFmpegPath = try writeFakeFFmpegScript(failPassthrough: false)
        let splitter = AudioSplitter(ffmpegPath: fakeFFmpegPath, ffprobePath: ffprobePath())

        let tracks = [
            CueTrack(index: 1, title: "Track One", startSeconds: 0, endSeconds: 10)
        ]

        let outputs = try await splitter.split(
            file: inputURL,
            tracks: tracks,
            to: tempDir,
            outputFormat: nil,
            progressHandler: { _ in }
        )

        XCTAssertEqual(outputs.count, 1)
        // On success, extension must match input (passthrough)
        XCTAssertEqual(outputs[0].pathExtension, "mp3",
            "Passthrough output must preserve original input extension")
    }

    // MARK: - Helpers

    private func ffprobePath() -> String {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffprobe"
    }

    /// Writes a standalone Python script that acts as a fake ffmpeg binary.
    /// failPassthrough=true  → exits 1 if "-acodec copy" appears in args
    /// failPassthrough=false → always exits 0
    /// In both cases writes a minimal valid WAV to the output path (last arg).
    private func writeFakeFFmpegScript(failPassthrough: Bool) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptPath = dir.appendingPathComponent("ffmpeg")

        let pyBool = failPassthrough ? "True" : "False"
        let pythonSrc = """
        #!/usr/bin/env python3
        import sys
        args = sys.argv[1:]
        if \(pyBool):
            for i, a in enumerate(args):
                if a == '-acodec' and i+1 < len(args) and args[i+1] == 'copy':
                    sys.exit(1)
        out = args[-1]
        hdr = b'RIFF' + b'\\x24\\x02\\x00\\x00' + b'WAVEfmt \\x10\\x00\\x00\\x00\\x01\\x00\\x01\\x00@\\x1f\\x00\\x00@\\x1f\\x00\\x00\\x01\\x00\\x08\\x00' + b'data\\x00\\x02\\x00\\x00'
        with open(out, 'wb') as f:
            f.write(hdr)
        sys.exit(0)
        """

        try pythonSrc.write(toFile: scriptPath.path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath.path
    }

    private func createMinimalFLAC(at url: URL, durationSeconds: Double) throws {
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ffmpeg.arguments = [
            "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
            "-t", String(durationSeconds), "-acodec", "flac", url.path
        ]
        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        if !FileManager.default.fileExists(atPath: url.path) {
            throw NSError(domain: "Test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create FLAC test file (exit: \(ffmpeg.terminationStatus))"])
        }
    }

    private func createMinimalMP3(at url: URL, durationSeconds: Double) throws {
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ffmpeg.arguments = [
            "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
            "-t", String(durationSeconds), "-acodec", "libmp3lame", url.path
        ]
        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        if !FileManager.default.fileExists(atPath: url.path) {
            throw NSError(domain: "Test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create MP3 test file (exit: \(ffmpeg.terminationStatus))"])
        }
    }

    private func probeFormat(of url: URL) throws -> String {
        let ffprobe = ffprobePath()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = [
            "-v", "error", "-show_entries", "format=format_name",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Thread-safe bool wrapper for capturing progress callback state.
private final class ThreadSafe {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}
