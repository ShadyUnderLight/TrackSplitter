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

        // Simple argument parsing: first positional arg is the FLAC file
        let flacPath = args.first { !$0.hasPrefix("-") }
        guard let flacPath else {
            print("Error: No FLAC file specified.\n")
            print(helpText)
            exit(1)
        }

        let flacURL = URL(fileURLWithPath: flacPath)

        guard FileManager.default.fileExists(atPath: flacURL.path) else {
            print("Error: File not found: \(flacPath)")
            exit(1)
        }

        guard flacURL.pathExtension.lowercased() == "flac" else {
            print("Error: File is not a FLAC file: \(flacURL.lastPathComponent)")
            exit(1)
        }

        let handler = TrackSplitterEngine.LogHandler { msg in
            print(msg)
        }

        let engine = TrackSplitterEngine(logHandler: handler)

        print("🎧 TrackSplitter v1.0.0\n")

        do {
            let result = try await engine.process(flacURL: flacURL)
            print("\n✅ Done! \(result.trackFiles.count) tracks saved to:")
            print("   \(result.outputDirectory.path)")
        } catch {
            print("\n❌ Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static let helpText = """
    TrackSplitter — Split FLAC+CUE albums into individual tracks with metadata.

    Usage: tracksplitter <file.flac> [options]

    Options:
      --help, -h        Show this help
      --version         Show version

    Example:
      tracksplitter "/Users/music/陈升-别让我哭.flac"

    Requirements:
      • A .cue file with the same base name in the same directory
      • ffmpeg installed (brew install ffmpeg)
      • python3 and mutagen (pip3 install mutagen)
    """
}
