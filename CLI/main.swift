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

        // Parse options from args (累积过滤模式)
        var filteredArgs = args
        var outputDirArg: String?
        var nameTemplateArg: String?
        var overwriteArg: String?
        var outputFormatArg: String?

        if let idx = filteredArgs.firstIndex(of: "--output-dir") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --output-dir requires a path argument.")
                exit(1)
            }
            outputDirArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        }

        if let idx = filteredArgs.firstIndex(of: "--name-template") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --name-template requires a template argument.")
                exit(1)
            }
            nameTemplateArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        }

        if let idx = filteredArgs.firstIndex(of: "--overwrite") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --overwrite requires a policy argument (rename|overwrite|skip).")
                exit(1)
            }
            overwriteArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        }

        if let idx = filteredArgs.firstIndex(of: "--output-format") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --output-format requires a format argument.")
                exit(1)
            }
            outputFormatArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        }

        // Validate overwrite policy
        let overwritePolicy: AudioSplitter.OverwritePolicy
        if let arg = overwriteArg {
            switch arg.lowercased() {
            case "rename": overwritePolicy = .rename
            case "overwrite": overwritePolicy = .overwrite
            case "skip": overwritePolicy = .skip
            default:
                print("Error: --overwrite must be one of: rename, overwrite, skip")
                exit(1)
            }
        } else {
            overwritePolicy = .rename
        }

        // Validate output format
        let outputFormat: AudioSplitter.AudioFormat?
        if let arg = outputFormatArg {
            switch arg.lowercased() {
            case "flac": outputFormat = .flac
            case "mp3": outputFormat = .mp3
            case "wav": outputFormat = .wav
            case "alac": outputFormat = .alac
            default:
                print("Error: --output-format must be one of: flac, mp3, wav, alac")
                exit(1)
            }
        } else {
            outputFormat = nil
        }

        // Build OutputConfig
        let outputConfig = TrackSplitterEngine.OutputConfig(
            outputDirectory: outputDirArg.map { URL(fileURLWithPath: $0) },
            nameTemplate: nameTemplateArg ?? "{index}. {title}.{ext}",
            overwritePolicy: overwritePolicy
        )

        // CLI mode: positional audio file path
        let audioPath = filteredArgs.first { !$0.hasPrefix("-") }
        guard let audioPath else {
            print("Error: No audio file specified. Pass a supported audio file path.")
            print("Run 'tracksplitter --help' for usage.")
            exit(1)
        }

        runCLI(
            audioPath: audioPath,
            outputConfig: outputConfig,
            outputFormat: outputFormat
        )
    }

    // MARK: - CLI mode

    private static func runCLI(
        audioPath: String,
        outputConfig: TrackSplitterEngine.OutputConfig,
        outputFormat: AudioSplitter.AudioFormat?
    ) {
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
                let result = try await engine.process(
                    inputURL: audioURL,
                    outputFormat: outputFormat,
                    outputConfig: outputConfig
                )
                print("\n✅ Done! \(result.trackFiles.count) tracks saved to:")
                print("   \(result.outputDirectory.path)")
            } catch {
                runError = error
                print("\n❌ Error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        semaphore.wait()

        if runError != nil {
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
      --output-dir <path>    Output directory (default: same dir as input)
      --name-template <tmpl> Filename template with placeholders:
                             {index}, {title}, {artist}, {album}, {ext}
                             Default: "{index}. {title}.{ext}"
      --overwrite <policy>   rename | overwrite | skip  (default: rename)
      --output-format <fmt>   flac | mp3 | wav | alac  (default: keep original)
      --help, -h             Show this help
      --version              Show version

    Examples:
      tracksplitter "/Users/music/陈升-别让我哭.flac"
      tracksplitter "/Users/music/album.mp3" --output-dir ~/Desktop/tracks
      tracksplitter "album.flac" --name-template "{index:02d} {title}.{ext}"
      tracksplitter "album.flac" --overwrite skip

    Requirements:
      • ffmpeg    (brew install ffmpeg)
      • python3 + mutagen  (pip3 install mutagen --break-system-packages)
    """
}
