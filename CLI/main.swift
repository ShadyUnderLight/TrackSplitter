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
            print("TrackSplitter \(Version.cliVersion)")
            return
        }

        // Parse --output-format
        var outputFormatArg: String?
        var filteredArgs = args
        if let idx = args.firstIndex(of: "--output-format") {
            guard idx + 1 < args.count else {
                print("Error: --output-format requires a value (e.g. --output-format mp3)")
                exit(1)
            }
            outputFormatArg = args[idx + 1]
            filteredArgs = args.filter { $0 != "--output-format" && $0 != outputFormatArg }
        } else if let idx = args.firstIndex(where: { $0.hasPrefix("--output-format=") }) {
            outputFormatArg = String(args[idx].dropFirst("--output-format=".count))
            filteredArgs = args.filter { $0 != args[idx] }
        }

        // Validate output format early
        let outputFormat: AudioSplitter.AudioFormat?
        if let arg = outputFormatArg {
            guard let fmt = AudioSplitter.AudioFormat(rawValue: arg.lowercased()) else {
                let valid = AudioSplitter.AudioFormat.allCases.map { $0.rawValue }.joined(separator: ", ")
                print("Error: '\(arg)' is not a supported output format.")
                print("Valid formats: \(valid)")
                exit(1)
            }
            outputFormat = fmt
        } else {
            outputFormat = nil  // passthrough — keep original format
        }

        // CLI mode: positional audio file path
        let audioPath = filteredArgs.first { !$0.hasPrefix("-") }
        guard let audioPath else {
            print("Error: No audio file specified. Pass a supported audio file path.")
            print("Run 'tracksplitter --help' for usage.")
            exit(1)
        }

        await runCLI(audioPath: audioPath, outputFormat: outputFormat)
    }

    // MARK: - CLI mode

    private static func runCLI(audioPath: String, outputFormat: AudioSplitter.AudioFormat?) async {
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

        print("🎧 TrackSplitter v\(Version.currentVersion) (build \(Version.buildNumber))\n")

        if let fmt = outputFormat {
            print("Output format: \(fmt.rawValue.uppercased()) (re-encode)\n")
        } else {
            print("Output format: passthrough (keeping original format)\n")
        }

        let outcome = await engine.process(inputURL: audioURL, outputFormat: outputFormat)
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
      tracksplitter <file>                    Process an audio file from the command line
      tracksplitter <file> --output-format mp3  Re-encode output to MP3

    Options:
      --help, -h           Show this help
      --version            Show version
      --output-format <fmt>  Output format. Omit to keep original format (passthrough).
                             Valid formats: flac, mp3, wav, aiff, alac, m4a, aac, ogg, opus

    Format notes:
      • Passthrough (default): no re-encoding, fastest, preserves original quality.
      • FLAC: lossless, widely supported, larger files.
      • MP3: universally compatible, smaller files, lossy.
      • WAV: uncompressed, large files, universal support.
      • AIFF: uncompressed, Apple ecosystem.
      • ALAC / M4A / AAC: Apple lossless or lossy, efficient.
      • OGG / Opus: open formats, efficient.

    Metadata & cover art:
      Passthrough preserves all metadata. When re-encoding, some formats have
      limitations — see docs/METADATA_MATRIX.md.

    Examples:
      tracksplitter "/Users/music/陈升-别让我哭.flac"
      tracksplitter "/Users/music/album.mp3"
      tracksplitter "/Users/music/album.wav" --output-format flac

    Requirements:
      • ffmpeg    (brew install ffmpeg)
      • python3 + mutagen  (python3 -m pip install mutagen; venv: python3 -m venv .venv && .venv/bin/pip install mutagen)
    """
}
