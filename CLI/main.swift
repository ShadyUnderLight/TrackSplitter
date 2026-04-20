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

        // Parse --chapter-source
        // Parse chapter source options.
        // --chapter-source and --chapter-file are mutually exclusive.
        // Each parses from already-filtered args so consumed options don't reappear.
        var chapterSourceArg: String?
        var chapterFileArg: String?
        var filteredArgs = args

        // --chapter-source
        if let idx = filteredArgs.firstIndex(of: "--chapter-source") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --chapter-source requires a value (e.g. --chapter-source embedded)")
                exit(1)
            }
            chapterSourceArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        } else if let idx = filteredArgs.firstIndex(where: { $0.hasPrefix("--chapter-source=") }) {
            chapterSourceArg = String(filteredArgs[idx].dropFirst("--chapter-source=".count))
            filteredArgs.remove(at: idx)
        }

        // --chapter-file (mutually exclusive with --chapter-source)
        if let idx = filteredArgs.firstIndex(of: "--chapter-file") {
            if chapterSourceArg != nil {
                print("Error: --chapter-source and --chapter-file are mutually exclusive.")
                exit(1)
            }
            guard idx + 1 < filteredArgs.count else {
                print("Error: --chapter-file requires a path (e.g. --chapter-file /path/to/chapters.txt)")
                exit(1)
            }
            chapterFileArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        } else if let idx = filteredArgs.firstIndex(where: { $0.hasPrefix("--chapter-file=") }) {
            if chapterSourceArg != nil {
                print("Error: --chapter-source and --chapter-file are mutually exclusive.")
                exit(1)
            }
            chapterFileArg = String(filteredArgs[idx].dropFirst("--chapter-file=".count))
            filteredArgs.remove(at: idx)
        }

        // --output-format (always parsed from already-filtered list)
        var outputFormatArg: String?
        if let idx = filteredArgs.firstIndex(of: "--output-format") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --output-format requires a value (e.g. --output-format mp3)")
                exit(1)
            }
            outputFormatArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        } else if let idx = filteredArgs.firstIndex(where: { $0.hasPrefix("--output-format=") }) {
            outputFormatArg = String(filteredArgs[idx].dropFirst("--output-format=".count))
            filteredArgs.remove(at: idx)
        }

        // --output-dir (cumulative filter: operates on already-filtered list)
        var outputDirArg: String?
        if let idx = filteredArgs.firstIndex(of: "--output-dir") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --output-dir requires a path.")
                exit(1)
            }
            outputDirArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        } else if let idx = filteredArgs.firstIndex(where: { $0.hasPrefix("--output-dir=") }) {
            outputDirArg = String(filteredArgs[idx].dropFirst("--output-dir=".count))
            filteredArgs.remove(at: idx)
        }

        // --name-template
        var nameTemplateArg: String?
        if let idx = filteredArgs.firstIndex(of: "--name-template") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --name-template requires a template string.")
                exit(1)
            }
            nameTemplateArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        } else if let idx = filteredArgs.firstIndex(where: { $0.hasPrefix("--name-template=") }) {
            nameTemplateArg = String(filteredArgs[idx].dropFirst("--name-template=".count))
            filteredArgs.remove(at: idx)
        }

        // --overwrite
        var overwriteArg: String?
        if let idx = filteredArgs.firstIndex(of: "--overwrite") {
            guard idx + 1 < filteredArgs.count else {
                print("Error: --overwrite requires a policy (rename|overwrite|skip).")
                exit(1)
            }
            overwriteArg = filteredArgs[idx + 1]
            filteredArgs.remove(at: idx + 1)
            filteredArgs.remove(at: idx)
        } else if let idx = filteredArgs.firstIndex(where: { $0.hasPrefix("--overwrite=") }) {
            overwriteArg = String(filteredArgs[idx].dropFirst("--overwrite=".count))
            filteredArgs.remove(at: idx)
        }

        let overwritePolicy: AudioSplitter.OverwritePolicy
        if let raw = overwriteArg {
            switch raw.lowercased() {
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

        let outputConfig = TrackSplitterEngine.OutputConfig(
            outputDirectory: outputDirArg.map { URL(fileURLWithPath: $0) },
            nameTemplate: nameTemplateArg ?? "{index}. {title}.{ext}",
            overwritePolicy: overwritePolicy
        )

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

        // Parse chapter source (audioPath is now available for .embedded case)
        let chapterSource: ChapterSource?
        if let raw = chapterSourceArg {
            if raw == "embedded" {
                chapterSource = .embedded(URL(fileURLWithPath: audioPath))
            } else if raw == "cue" || raw == "auto" {
                chapterSource = nil  // auto-detect CUE (default)
            } else {
                print("Error: '\(raw)' is not a valid --chapter-source value.")
                print("Valid values: embedded, cue, auto")
                exit(1)
            }
        } else if let path = chapterFileArg {
            let fileURL = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: path) else {
                print("Error: Chapter file not found: \(path)")
                exit(1)
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "cue" || ext == "qcue" {
                chapterSource = .cue(fileURL)
            } else if ext == "meta" || ext == "ffmetadata" {
                chapterSource = .ffmpegChapters(fileURL)
            } else {
                // Default: treat as text chapters
                chapterSource = .textChapters(fileURL)
            }
        } else {
            chapterSource = nil  // auto-detect CUE
        }

        await runCLI(audioPath: audioPath, outputFormat: outputFormat, chapterSource: chapterSource, outputConfig: outputConfig)
    }

    // MARK: - CLI mode

    private static func runCLI(
        audioPath: String,
        outputFormat: AudioSplitter.AudioFormat?,
        chapterSource: ChapterSource?,
        outputConfig: TrackSplitterEngine.OutputConfig
    ) async {
        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            print("Error: File not found: \(audioPath)")
            exit(1)
        }

        let supported: Set<String> = ["flac", "mp3", "wav", "aiff", "alac", "m4a", "aac", "ogg", "opus"]
        guard supported.contains(audioURL.pathExtension.lowercased()) else {
            print("Error: Unsupported file format: \(audioURL.lastPathComponent)")
            print("Supported: FLAC, MP3, WAV, AIFF, ALAC, M4A, AAC, OGG, Opus")
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

        let outcome = await engine.process(
            inputURL: audioURL,
            outputFormat: outputFormat,
            chapterSource: chapterSource,
            outputConfig: outputConfig
        )
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
      tracksplitter <file>                         Process an audio file (uses .cue if found)
      tracksplitter <file> --chapter-source embedded  Read chapters from the audio file itself
      tracksplitter <file> --chapter-file /path/to/chapters.txt  Use a text/FFmpeg chapter file
      tracksplitter <file> --output-format mp3      Re-encode output to MP3

    Chapter source options:
      --chapter-source auto       Auto-detect CUE in the same directory (default)
      --chapter-source embedded   Read chapters from the input audio file (if any)
      --chapter-source cue        Alias for auto (CUE auto-detection)
      --chapter-file <path>       Use a chapter definition file:
                                   • .cue / .qcue  → CUE sheet
                                   • .meta / .ffmetadata → FFmpeg chapter file
                                   • anything else → plain text chapters (one "HH:MM:SS Title" per line)

    Text chapter file format:
      00:00:00 Track 1 Title
      00:03:45 - Track 2 Title
      [00:07:30] Track 3 Title

    FFmpeg chapter file format:
      ;FFMETADATA1
      CHAPTER0000=00:00:00.000
      CHAPTER0000NAME=Track 1 Title
      CHAPTER0001=00:03:45.000
      CHAPTER0001NAME=Track 2 Title

    Output format options:
      --output-format <fmt>  Output format. Omit to keep original format (passthrough).
                              Valid: flac, mp3, wav, aiff, alac, m4a, aac, ogg, opus

    Output options:
      --output-dir <path>        Output directory (default: same dir as input)
      --name-template <template> Filename template. Placeholders: {index}, {title}, {artist},
                                 {album}, {ext}. Default: "{index}. {title}.{ext}"
      --overwrite <policy>       rename (default) | overwrite | skip

    Metadata & cover art:
      Passthrough preserves all metadata. When re-encoding, some formats have
      limitations — see docs/METADATA_MATRIX.md.

    Examples:
      tracksplitter "/Users/music/陈升-别让我哭.flac"
      tracksplitter "/Users/music/album.flac" --chapter-source embedded
      tracksplitter "/Users/music/album.flac" --chapter-file chapters.txt
      tracksplitter "/Users/music/album.wav" --output-format flac
      tracksplitter "album.flac" --output-dir ~/Desktop/tracks
      tracksplitter "album.flac" --name-template "{index:02d} {title}.{ext}"
      tracksplitter "album.flac" --overwrite skip

    Requirements:
      • ffmpeg    (brew install ffmpeg)
      • python3 + mutagen  (python3 -m pip install mutagen; venv: python3 -m venv .venv && .venv/bin/pip install mutagen)
    """
}
