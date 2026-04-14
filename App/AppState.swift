import Foundation
import TrackSplitterLib

/// 应用状态机与界面共享状态。
/// 使用 ObservableObject 而非 @Observable（后者需要 macOS 14.0+）。
@MainActor
final class AppState: ObservableObject {
    /// 状态机阶段：空闲 -> 已加载 -> 处理中 -> 完成 -> 错误。
    enum Phase {
        /// 初始空闲状态。
        case idle
        /// 已加载输入文件并完成预解析。
        case loaded(LoadedFiles)
        /// 正在拆分处理。
        case processing
        /// 处理完成并持有结果。
        case complete(Completion)
        /// 处理失败并持有错误信息。
        case error(String)
    }

    /// 已加载文件上下文。
    struct LoadedFiles {
        /// 用户选择的 FLAC 文件。
        let flacURL: URL
        /// 自动匹配到的 CUE 文件。
        let cueURL: URL
        /// 解析出的曲目列表。
        let tracks: [CueTrack]
        /// 专辑标题（可能为空）。
        let albumTitle: String?
        /// 艺术家（可能为空）。
        let performer: String?
    }

    /// 完成态上下文。
    struct Completion {
        /// 输出目录。
        let outputDirectory: URL
        /// 生成的曲目文件列表。
        let trackFiles: [URL]
        /// 专辑标题（可能为空）。
        let albumTitle: String?
        /// 艺术家（可能为空）。
        let performer: String?
        /// 封面图是否写入成功。
        let coverEmbedded: Bool
        /// 每个 track 的元数据写入结果（按 trackFiles 顺序）。
        let metadataResult: MetadataEmbedder.EmbedResult
    }

    /// 当前阶段。
    @Published var phase: Phase = .idle
    /// 处理日志流。
    @Published var logs: [String] = []
    /// 处理进度（0...1）。
    @Published var progress: Double = 0
    /// 错误弹窗是否显示。
    @Published var isShowingErrorAlert: Bool = false
    /// 错误弹窗文案。
    @Published var errorMessage: String = ""

    /// 重置到初始状态。
    func reset() {
        phase = .idle
        logs = []
        progress = 0
        isShowingErrorAlert = false
        errorMessage = ""
    }

    /// 写入错误并切换到错误态。
    func setError(_ message: String) {
        phase = .error(message)
        errorMessage = message
        isShowingErrorAlert = true
    }

    /// 关闭错误弹窗。
    func dismissError() {
        isShowingErrorAlert = false
    }
}
