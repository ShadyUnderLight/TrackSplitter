import Foundation
import TrackSplitterLib

@main
struct TrackSplitterCLI {
    static func main() async {
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

        await runCLI(audioPath: audioPath)
    }

    // MARK: - CLI mode

    private static func runCLI(audioPath: String) async {
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

        let outcome = await engine.process(inputURL: audioURL)
        switch outcome.status {
        case .success:
            guard let output = outcome.output else {
                print("\n❌ Internal error: no output")
                exit(1)
            }
            print("\n✅ Done! \(output.trackFiles.count) tracks saved to:")
            print("   \(output.outputDirectory.path)")
        case .partialSuccess:
            guard let output = outcome.output else {
                print("\n❌ Internal error: no output")
                exit(1)
            }
            print("\n⚠️  Partial success — \(output.trackFiles.count) audio files saved to:")
            print("   \(output.outputDirectory.path)")
            if !output.metadataResult.failures.isEmpty {
                print("   Metadata failed for \(output.metadataResult.failed) track(s):")
                for f in output.metadataResult.failures.prefix(5) {
                    print("     • \(f)")
                }
            }
        case .failure:
            print("\n❌ \(outcome.summary)")
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
