import Foundation
import Combine

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
        let flacURL: URL
        let cueURL: URL
        let tracks: [CueTrack]
        let albumTitle: String?
        let performer: String?

        static func == (lhs: LoadedFiles, rhs: LoadedFiles) -> Bool {
            lhs.flacURL == rhs.flacURL && lhs.cueURL == rhs.cueURL
        }
    }

    struct Completion: Equatable {
        let outputDirectory: URL
        let trackFiles: [URL]
        let albumTitle: String?
        let performer: String?
        let coverImageData: Data?

        /// 从第一个 FLAC 文件读取封面图数据（Data?）。
        static func readCover(from files: [URL]) -> Data? {
            guard let firstTrack = files.first(where: { $0.pathExtension.lowercased() == "flac" }) else { return nil }
            // 使用 mutagen 读取第一张封面，写入临时 PNG，读取后删除。
            let tmpPath = NSTemporaryDirectory() + "ts_cover_\(UUID().uuidString).png"
            let script = """
from mutagen.flac import FLAC
import sys
f = FLAC('\(firstTrack.path)')
if f.pictures:
    open('\(tmpPath)', 'wb').write(f.pictures[0].data)
    print('OK')
else:
    print('NO_COVER')
"""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = ["-c", script]
            try? proc.run()
            proc.waitUntilExit()
            guard FileManager.default.fileExists(atPath: tmpPath) else { return nil }
            let data = try? Data(contentsOf: URL(fileURLWithPath: tmpPath))
            try? FileManager.default.removeItem(atPath: tmpPath)
            return data
        }
    }

    @Published var phase: Phase = .idle
    @Published var logs: [String] = []
    @Published var progress: Double = 0
    @Published var isShowingErrorAlert: Bool = false
    @Published var errorMessage: String = ""

    // MARK: - Actions
    func load(flacURL: URL) {
        log("load() called: \(flacURL.path)")

        guard flacURL.pathExtension.lowercased() == "flac" else {
            log("FAIL: not .flac")
            setError("仅支持 .flac 文件")
            return
        }

        guard let cueURL = findCue(for: flacURL) else {
            log("FAIL: CUE not found")
            setError("未找到同名 CUE 文件：\(flacURL.deletingPathExtension().lastPathComponent).cue")
            return
        }

        do {
            let parsed = try parseCue(at: cueURL)
            log("CUE parsed: \(parsed.tracks.count) tracks")
            let previewTracks = fillPreviewEndTimes(for: parsed.tracks)
            let loaded = LoadedFiles(
                flacURL: flacURL,
                cueURL: cueURL,
                tracks: previewTracks,
                albumTitle: parsed.albumTitle,
                performer: parsed.performer
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
            Task { @MainActor in
                self?.appendLog(message, fallbackTotalTracks: loaded.tracks.count)
            }
        }

        Task {
            do {
                let engine = TrackSplitterEngine(logHandler: handler)
                let result = try await engine.process(flacURL: loaded.flacURL)
                let coverData = Completion.readCover(from: result.trackFiles)
                let completion = Completion(
                    outputDirectory: result.outputDirectory,
                    trackFiles: result.trackFiles,
                    albumTitle: result.albumTitle,
                    performer: result.performer,
                    coverImageData: coverData
                )
                await MainActor.run {
                    self.progress = 1
                    self.phase = .complete(completion)
                }
            } catch {
                await MainActor.run {
                    self.setError(error.localizedDescription)
                }
            }
        }
    }

    func processAnother() {
        phase = .idle
        logs = []
        progress = 0
        isShowingErrorAlert = false
        errorMessage = ""
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
