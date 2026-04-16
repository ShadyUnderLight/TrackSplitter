import Foundation
import Observation
import TrackSplitterLib

/// 负责协调界面与核心引擎的视图模型。
/// 使用 ObservableObject 而非 @Observable，以确保在 macOS 13.0 上兼容。
@MainActor
final class SplitterViewModel: ObservableObject {
    /// 全局应用状态。
    let appState = AppState()

    /// 处理用户选择或拖入的音频文件。
    func load(audioURL: URL) {
        let supported: Set<String> = ["flac", "mp3", "wav", "aiff", "alac", "m4a", "aac", "ogg", "opus"]
        guard supported.contains(audioURL.pathExtension.lowercased()) else {
            appState.setError("不支持的文件格式。支持：FLAC, MP3, WAV, AIFF, M4A, AAC, OGG, Opus")
            return
        }

        // 自动查找匹配的 CUE 文件。
        guard let cueURL = findCue(for: audioURL) else {
            appState.setError("未找到匹配的 CUE 文件（请确认 CUE 中 FILE 字段与音频文件名一致）")
            return
        }

        do {
            // 解析 CUE 并构造用于预览的曲目时间区间。
            let (tracks, albumTitle, performer, _, _) = try parseCue(at: cueURL)
            let previewTracks = fillPreviewEndTimes(for: tracks)
            let loaded = AppState.LoadedFiles(
                audioURL: audioURL,
                cueURL: cueURL,
                tracks: previewTracks,
                albumTitle: albumTitle,
                performer: performer
            )
            appState.phase = .loaded(loaded)
            appState.logs = []
            appState.progress = 0
        } catch {
            appState.setError("解析 CUE 失败：\(error.localizedDescription)")
        }
    }

    /// 启动异步拆分流程。
    func startProcessing() {
        // 仅在已加载状态下允许开始处理。
        guard case .loaded(let loaded) = appState.phase else {
            appState.setError("当前没有可处理的文件")
            return
        }

        appState.logs = []
        appState.progress = 0
        appState.phase = .processing

        // 注入日志回调，将引擎日志实时桥接到 UI。
        let logHandler = TrackSplitterEngine.LogHandler { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message, fallbackTotalTracks: loaded.tracks.count)
            }
        }

        // 使用 Task 以非阻塞方式执行异步处理。
        Task {
            do {
                let engine = TrackSplitterEngine(logHandler: logHandler)
                let result = try await engine.process(inputURL: loaded.audioURL)
                let completion = AppState.Completion(
                    outputDirectory: result.outputDirectory,
                    trackFiles: result.trackFiles,
                    albumTitle: result.albumTitle,
                    performer: result.performer,
                    coverEmbedded: result.coverEmbedded,
                    metadataResult: result.metadataResult
                )

                await MainActor.run {
                    self.appState.progress = 1
                    self.appState.phase = .complete(completion)
                }
            } catch {
                await MainActor.run {
                    self.appState.setError(error.localizedDescription)
                }
            }
        }
    }

    /// 重新开始下一次处理。
    func processAnother() {
        appState.reset()
    }

    /// 向日志列表追加一条记录，并尝试更新进度条。
    private func appendLog(_ message: String, fallbackTotalTracks: Int) {
        appState.logs.append(message)

        // 解析类似 "Splitting track X/Y" 的日志用于更新确定性进度。
        if let (current, total) = parseSplitProgress(from: message) {
            let safeTotal = max(total, 1)
            appState.progress = min(max(Double(current) / Double(safeTotal), 0), 1)
        } else if fallbackTotalTracks > 0,
                  let current = parseSplitCurrentTrack(from: message) {
            appState.progress = min(max(Double(current) / Double(fallbackTotalTracks), 0), 1)
        }
    }

    /// 从日志中解析当前/总曲目进度。
    private func parseSplitProgress(from message: String) -> (current: Int, total: Int)? {
        let pattern = #"Splitting track\s+(\d+)\/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let currentRange = Range(match.range(at: 1), in: message),
              let totalRange = Range(match.range(at: 2), in: message),
              let current = Int(message[currentRange]),
              let total = Int(message[totalRange]) else {
            return nil
        }
        return (current, total)
    }

    /// 在没有总数时，尝试仅解析当前曲目编号。
    private func parseSplitCurrentTrack(from message: String) -> Int? {
        let pattern = #"Splitting track\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let currentRange = Range(match.range(at: 1), in: message),
              let current = Int(message[currentRange]) else {
            return nil
        }
        return current
    }

    /// 为预览列表补齐每首歌的结束时间（最后一首保持未知）。
    private func fillPreviewEndTimes(for tracks: [CueTrack]) -> [CueTrack] {
        var filledTracks = tracks
        for index in filledTracks.indices {
            guard filledTracks[index].endSeconds == nil else { continue }
            if index + 1 < filledTracks.count {
                filledTracks[index].endSeconds = filledTracks[index + 1].startSeconds
            }
        }
        return filledTracks
    }
}
