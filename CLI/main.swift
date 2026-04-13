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

        if args.contains("--gui") {
            runGUI()
            return
        }

        // CLI mode: positional FLAC path
        let flacPath = args.first { !$0.hasPrefix("-") }
        guard let flacPath else {
            print("Error: No FLAC file specified. Use --gui for the graphical interface, or pass a .flac file path.")
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

    // MARK: - GUI mode

    private static func runGUI() {
        let server = WebGUIServer(port: 7890)

        print("🎨 TrackSplitter GUI\n")

        do {
            let url = try server.start(
                onProgress: { msg in
                    print(msg)
                },
                onComplete: { result in
                    switch result {
                    case .success(let path):
                        print("\n✅ Done! \(path)")
                    case .failure(let err):
                        print("\n❌ Error: \(err.localizedDescription)")
                    }
                }
            )

            print("🌐 Opening browser at: \(url)")
            openBrowser(url: url)

            // Block forever — server runs on its own queue
            print("\nServer running. Press Ctrl+C to stop.\n")
            dispatchMain()

        } catch {
            print("❌ Failed to start GUI server: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func openBrowser(url: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url]
        try? proc.run()
    }

    // MARK: - Help text

    static let helpText = """
    TrackSplitter — Split FLAC+CUE albums into individual tracks with metadata.

    Usage:
      tracksplitter --gui              Open the graphical web interface
      tracksplitter <file.flac>        Process a FLAC file from the command line

    Options:
      --gui, -g   Launch the web-based graphical interface
      --help, -h  Show this help
      --version   Show version

    Examples:
      tracksplitter --gui
      tracksplitter "/Users/music/陈升-别让我哭.flac"

    Requirements:
      • ffmpeg    (brew install ffmpeg)
      • python3 + mutagen  (pip3 install mutagen --break-system-packages)
    """
}
