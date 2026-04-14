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

        // CLI mode: positional FLAC path
        let flacPath = args.first { !$0.hasPrefix("-") }
        guard let flacPath else {
            print("Error: No FLAC file specified. Pass a .flac file path.")
            print("Run 'tracksplitter --help' for usage.")
            exit(1)
        }

        runCLI(flacPath: flacPath)
    }

    // MARK: - CLI mode

    private static func runCLI(flacPath: String) {
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

        let semaphore = DispatchSemaphore(value: 0)
        var runError: Error?

        Task {
            do {
                let result = try await engine.process(flacURL: flacURL)
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
    TrackSplitter — Split FLAC+CUE albums into individual tracks with metadata.

    Usage:
      tracksplitter <file.flac>        Process a FLAC file from the command line

    Options:
      --help, -h  Show this help
      --version   Show version

    Examples:
      tracksplitter "/Users/music/陈升-别让我哭.flac"

    Requirements:
      • ffmpeg    (brew install ffmpeg)
      • python3 + mutagen  (pip3 install mutagen --break-system-packages)
    """
}
