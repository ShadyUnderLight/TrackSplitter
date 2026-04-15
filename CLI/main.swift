import Foundation
import TrackSplitterLib

@main
struct TrackSplitterCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            print(helpText)
            return
        }

        if args.contains("--version") {
            print("TrackSplitter 1.0.0")
            return
        }

        // CLI mode: positional audio file path
        let audioPath = args.first { !$0.hasPrefix("-") }
        guard let audioPath else {
            print("Error: No audio file specified. Pass a supported audio file path.")
            print("Run 'tracksplitter --help' for usage.")
            exit(1)
        }

        runCLI(audioPath: audioPath)
    }

    // MARK: - CLI mode

    private static func runCLI(audioPath: String) {
        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            print("Error: File not found: \(audioPath)")
            exit(1)
        }

        let supported: Set<String> = ["flac", "mp3", "wav", "aiff", "alac", "m4a", "aac", "ogg", "opus"]
        guard supported.contains(audioURL.pathExtension.lowercased()) else {
            print("Error: Unsupported file format: \(audioURL.lastPathComponent)")
            print("Supported: FLAC, MP3, WAV, AIFF, M4A, AAC, OGG, Opus")
            exit(1)
        }

        let handler = TrackSplitterEngine.LogHandler { msg in
            print(msg)
        }

        let engine = TrackSplitterEngine(logHandler: handler)

        print("🎧 TrackSplitter v1.0.0\n")

        let semaphore = DispatchSemaphore(value: 0)
        var runError: Error?

        Task {
            do {
                let result = try await engine.process(inputURL: audioURL)
                print("\n✅ Done! \(result.trackFiles.count) tracks saved to:")
                print("   \(result.outputDirectory.path)")
            } catch {
                runError = error
                print("\n❌ Error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let err = runError {
            exit(1)
        }
    }

    // MARK: - Help text

    static let helpText = """
    TrackSplitter — Split audio+CUE albums into individual tracks with metadata.

    Supported formats: FLAC, MP3, WAV, AIFF, M4A, AAC, OGG, Opus

    Usage:
      tracksplitter <file>        Process an audio file from the command line

    Options:
      --help, -h  Show this help
      --version   Show version

    Examples:
      tracksplitter "/Users/music/陈升-别让我哭.flac"
      tracksplitter "/Users/music/album.mp3"

    Requirements:
      • ffmpeg    (brew install ffmpeg)
      • python3 + mutagen  (pip3 install mutagen --break-system-packages)
    """
}
