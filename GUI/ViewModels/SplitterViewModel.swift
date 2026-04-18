import TrackSplitterLib
import Foundation
import Combine

/// Output format selection for the split.
public enum AudioSplitterOutputFormat: String, CaseIterable, Identifiable {
    case keepOriginal = ""
    case flac = "flac"
    case mp3 = "mp3"
    case wav = "wav"
    case aiff = "aiff"
    case alac = "alac"
    case m4a = "m4a"
    case aac = "aac"
    case ogg = "ogg"
    case opus = "opus"

    public var id: String { rawValue }

    /// Short display name for use in compact pickers.
    public var displayName: String {
        switch self {
        case .keepOriginal: return "保持原格式"
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .alac: return "ALAC"
        case .m4a: return "M4A"
        case .aac: return "AAC"
        case .ogg: return "OGG"
        case .opus: return "Opus"
        }
    }

    /// Human-readable description of this format's characteristics.
    public var formatDescription: String {
        switch self {
        case .keepOriginal: return "保持原始格式（最快，无重编码）"
        case .flac: return "无损压缩，兼容性好"
        case .mp3: return "有损压缩，体积小，兼容性最强"
        case .wav: return "无压缩，体积大，通用支持"
        case .aiff: return "Apple 无压缩格式"
        case .alac: return "Apple 无损格式（.m4a）"
        case .m4a: return "AAC 音频（.m4a）"
        case .aac: return "AAC 音频（.aac）"
        case .ogg: return "OGG Vorbis，开源有损"
        case .opus: return "Opus，开放高效"
        }
    }

    /// Caveats or limitations for this format (metadata / cover art), or nil if none.
    public var caveat: String? {
        switch self {
        case .keepOriginal, .flac, .mp3, .m4a: return nil
        case .wav: return "WAV 不支持嵌入封面"
        case .aiff: return "AIFF 封面支持不稳定"
        case .alac: return "ALAC 封面支持不稳定"
        case .aac: return "AAC 封面支持不稳定"
        case .ogg, .opus: return "OGG/Opus 封面支持不稳定"
        }
    }

    /// Whether this format uses re-encoding (vs passthrough).
    public var isPassthrough: Bool { self == .keepOriginal }

    /// Convert to AudioSplitter.AudioFormat for engine call, or nil for passthrough.
    public var audioFormat: AudioSplitter.AudioFormat? {
        guard self != .keepOriginal else { return nil }
        return AudioSplitter.AudioFormat(rawValue: self.rawValue)
    }
}

/// Chapter source type for the split (GUI-facing enum).
/// Maps to ChapterSource in the engine but decoupled for UI flexibility.
public enum ChapterSourceType: String, CaseIterable, Identifiable {
    case auto = "auto"
    case cue = "cue"
    case textChapters = "text"
    case ffmpegChapters = "ffmpeg"
    case embedded = "embedded"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:    return "自动检测 CUE"
        case .cue:     return "CUE 文件..."
        case .textChapters:  return "文本章节..."
        case .ffmpegChapters: return "FFmpeg 章节..."
        case .embedded:      return "嵌入章节（从音频文件读取）"
        }
    }

    /// Whether this type requires the user to pick a file via NSOpenPanel.
    var requiresFile: Bool {
        switch self {
        case .auto, .embedded: return false
        case .cue, .textChapters, .ffmpegChapters: return true
        }
    }

    /// Build a ChapterSource for engine call, given the audio file URL and a chosen file URL.
    func buildChapterSource(audioURL: URL, fileURL: URL?) -> ChapterSource? {
        switch self {
        case .auto:    return nil
        case .embedded: return .embedded(audioURL)
        case .cue:     guard let u = fileURL else { return nil }; return .cue(u)
        case .textChapters:  guard let u = fileURL else { return nil }; return .textChapters(u)
        case .ffmpegChapters: guard let u = fileURL else { return nil }; return .ffmpegChapters(u)
        }
    }
}

/// 负责协调界面与核心引擎的视图模型。
/// 直接持有所有 @Published 状态，不通过中间 AppState，避免跨对象观察链失效。
@MainActor
final class SplitterViewModel: ObservableObject {
    // MARK: - 状态
    enum Phase: Equatable {
        case idle
        case loaded(LoadedFiles)
        case processing
        case complete(Completion)
        case error(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.loaded, .loaded): return true
            case (.processing, .processing): return true
            case (.complete, .complete): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    struct LoadedFiles: Equatable {
        let audioURL: URL
        let cueURL: URL
        let tracks: [CueTrack]
        let albumTitle: String?
        let performer: String?

        static func == (lhs: LoadedFiles, rhs: LoadedFiles) -> Bool {
            lhs.audioURL == rhs.audioURL && lhs.cueURL == rhs.cueURL
        }
    }

    struct Completion: Equatable {
        let outputDirectory: URL
        let trackFiles: [URL]
        let albumTitle: String?
        let performer: String?
        let coverImageData: Data?
        /// Whether cover art was embedded.
        let coverEmbedded: Bool
        /// Total tracks that had metadata successfully written.
        let metadataSucceededCount: Int
        /// Total tracks that failed metadata writing.
        let metadataFailedCount: Int
        /// Cover art fetch error if any.
        let metadataFailures: [String]

        /// 从输出文件中读取封面图数据，支持所有嵌入格式（FLAC/MP3/M4A/AIFF 等）。
        static func readCover(from files: [URL]) -> (data: Data?, pythonPath: String) {
            guard !files.isEmpty else { return (nil, "") }
            // 构造 JSON 列表传递给 Python，避免 shell 转义问题
            let filePaths = files.map { $0.path }
            guard let jsonData = try? JSONEncoder().encode(filePaths),
                  let filePathsArg = String(data: jsonData, encoding: .utf8) else {
                return (nil, "")
            }
            let tmpPath = NSTemporaryDirectory() + "ts_cover_\(UUID().uuidString).png"
            let script = """
import sys, json
from mutagen.flac import FLAC
from mutagen.mp3 import MP3
from mutagen.m4a import M4A
from mutagen.aiff import AIFF

paths = json.loads(sys.argv[1])
tmp = sys.argv[2]

for path in paths:
    ext = path.rsplit('.', 1)[-1].lower()
    try:
        if ext == 'flac':
            f = FLAC(path)
            if f.pictures:
                open(tmp, 'wb').write(f.pictures[0].data)
                print('OK')
                break
        elif ext == 'mp3':
            f = MP3(path)
            # 先检查 pictures 属性（ID3 v2.4 APIC）
            if hasattr(f, 'pictures') and f.pictures:
                open(tmp, 'wb').write(f.pictures[0].data)
                print('OK')
                break
            # 兼容旧版 mutagen：直接遍历 tags
            if f.tags:
                for frame in f.tags.values():
                    if hasattr(frame, 'FrameID') and frame.FrameID == 'APIC':
                        open(tmp, 'wb').write(frame.data)
                        print('OK')
                        break
                else:
                    continue
                break
        elif ext in ('m4a', 'aac', 'alac'):
            f = M4A(path)
            if f.pictures:
                open(tmp, 'wb').write(f.pictures[0].data)
                print('OK')
                break
        elif ext == 'aiff':
            f = AIFF(path)
            if hasattr(f, 'pictures') and f.pictures:
                open(tmp, 'wb').write(f.pictures[0].data)
                print('OK')
                break
            # AIFF 也用 ID3
            if f.tags:
                for frame in f.tags.values():
                    if hasattr(frame, 'FrameID') and frame.FrameID == 'APIC':
                        open(tmp, 'wb').write(frame.data)
                        print('OK')
                        break
                else:
                    continue
                break
    except Exception:
        continue
else:
    print('NO_COVER')
"""
            // Use the same python lookup as MetadataEmbedder
            let candidates = ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.14", "/usr/local/bin/python3", "python3"]
            let pythonPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            proc.arguments = ["-c", script, filePathsArg, tmpPath]
            try? proc.run()
            proc.waitUntilExit()
            guard FileManager.default.fileExists(atPath: tmpPath) else { return (nil, pythonPath) }
            let data = try? Data(contentsOf: URL(fileURLWithPath: tmpPath))
            try? FileManager.default.removeItem(atPath: tmpPath)
            return (data, pythonPath)
        }
    }

    @Published var phase: Phase = .idle
    @Published var logs: [String] = []
    @Published var progress: Double = 0
    @Published var isShowingErrorAlert: Bool = false
    @Published var errorMessage: String = ""
    /// Selected output format for the split. nil = same as input.
    @Published var selectedOutputFormat: AudioSplitterOutputFormat = .keepOriginal

    /// Selected chapter source type for the split.
    @Published var selectedChapterSourceType: ChapterSourceType = .auto

    /// Resolved chapter source URL (set when user picks a file via NSOpenPanel).
    @Published var chapterSourceURL: URL? = nil

    /// The currently running engine, if any. Used to support cancellation.
    private var activeEngine: TrackSplitterEngine?

    // MARK: - Actions
    func load(audioURL: URL) {
        log("load() called: \(audioURL.path)")

        guard SupportedAudioFormat.extensions.contains(audioURL.pathExtension.lowercased()) else {
            log("FAIL: unsupported format")
            setError("不支持的文件格式。支持：FLAC, MP3, WAV, AIFF, M4A, AAC, OGG, Opus")
            return
        }

        guard let cueURL = findCue(for: audioURL) else {
            log("FAIL: CUE not found")
            setError("未找到匹配的 CUE 文件（请确认 CUE 中 FILE 字段与音频文件名一致）")
            return
        }

        do {
            let (tracks, albumTitle, performer, _, _) = try parseCue(at: cueURL)
            log("CUE parsed: \(tracks.count) tracks")
            let previewTracks = fillPreviewEndTimes(for: tracks)
            let loaded = LoadedFiles(
                audioURL: audioURL,
                cueURL: cueURL,
                tracks: previewTracks,
                albumTitle: albumTitle,
                performer: performer
            )
            phase = .loaded(loaded)
            logs = []
            progress = 0
            log("DONE: phase = .loaded")
        } catch {
            log("FAIL: parseCue threw: \(error)")
            setError("解析 CUE 失败：\(error.localizedDescription)")
        }
    }

    func startProcessing() {
        guard case .loaded(let loaded) = phase else {
            setError("当前没有可处理的文件")
            return
        }

        logs = []
        progress = 0
        phase = .processing

        let handler = TrackSplitterEngine.LogHandler { [weak self] message in
            let totalTracks = loaded.tracks.count
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendLog(message, fallbackTotalTracks: totalTracks)
            }
        }

        Task {
            let engine = TrackSplitterEngine(logHandler: handler)
            self.activeEngine = engine
            let chapterSource = selectedChapterSourceType.buildChapterSource(
                audioURL: loaded.audioURL,
                fileURL: chapterSourceURL
            )
            let outcome = await engine.process(inputURL: loaded.audioURL,
                                               outputFormat: selectedOutputFormat.audioFormat,
                                               chapterSource: chapterSource)

            await MainActor.run {
                self.progress = 1
                switch outcome.status {
                case .success, .partialSuccess:
                    guard let output = outcome.output else {
                        // Shouldn't happen, but treat as error
                        self.setError("Internal error: no output available")
                        self.activeEngine = nil
                        return
                    }
                    let (coverData, _) = Completion.readCover(from: output.trackFiles)
                    let completion = Completion(
                        outputDirectory: output.outputDirectory,
                        trackFiles: output.trackFiles,
                        albumTitle: output.albumTitle,
                        performer: output.performer,
                        coverImageData: coverData,
                        coverEmbedded: output.coverEmbedded,
                        metadataSucceededCount: output.metadataResult.succeeded,
                        metadataFailedCount: output.metadataResult.failed,
                        metadataFailures: output.metadataResult.failures
                    )
                    self.phase = .complete(completion)
                case .failure:
                    self.setError(outcome.summary)
                }
                self.activeEngine = nil
            }
        }
    }

    /// Cancel the currently running split, if any.
    func cancelProcessing() {
        activeEngine?.cancel()
    }

    func processAnother() {
        phase = .idle
        logs = []
        progress = 0
        isShowingErrorAlert = false
        errorMessage = ""
        activeEngine = nil
    }

    // MARK: - Private
    private func log(_ msg: String) {
        let path = "/tmp/trackSplitter_debug.log"
        let line = "[\(Date())] \(msg)\n"
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
        print("[SplitterViewModel] \(msg)")
    }

    private func setError(_ message: String) {
        phase = .error(message)
        errorMessage = message
        isShowingErrorAlert = true
    }

    private func appendLog(_ message: String, fallbackTotalTracks: Int) {
        logs.append(message)
        if let (current, total) = parseSplitProgress(from: message) {
            progress = min(max(Double(current) / Double(max(total, 1)), 0), 1)
        }
    }

    private func parseSplitProgress(from message: String) -> (current: Int, total: Int)? {
        let pattern = #"Splitting track\s+(\d+)\/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              match.numberOfRanges >= 3,
              let cr = Range(match.range(at: 1), in: message),
              let tr = Range(match.range(at: 2), in: message),
              let current = Int(message[cr]),
              let total = Int(message[tr]) else { return nil }
        return (current, total)
    }

    private func fillPreviewEndTimes(for tracks: [CueTrack]) -> [CueTrack] {
        var filled = tracks
        for i in filled.indices {
            if filled[i].endSeconds == nil && i + 1 < filled.count {
                filled[i].endSeconds = filled[i + 1].startSeconds
            }
        }
        return filled
    }
}
