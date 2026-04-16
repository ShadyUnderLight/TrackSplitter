import AppKit
import SwiftUI

/// 主窗口内容视图。
/// 根据 AppState.phase 切换空闲/已加载/处理中/完成/错误四个子界面。
struct ContentView: View {
    /// 主视图模型，管理状态机和业务流程。
    /// 使用 @StateObject：ObservableObject 需要由视图拥有其生命周期。
    @StateObject private var viewModel = SplitterViewModel()

    init() {
        fputs("[TrackSplitter] ContentView initialized\n", stderr)
    }

    var body: some View {
        Group {
            switch viewModel.appState.phase {
            case .idle:
                idleOrLoadedView(loaded: nil)

            case .loaded(let loaded):
                idleOrLoadedView(loaded: loaded)

            case .processing:
                ProcessingView(progress: viewModel.appState.progress, logs: viewModel.appState.logs)

            case .complete(let completion):
                ResultView(
                    result: completion,
                    logs: viewModel.appState.logs,
                    onShowInFinder: { showInFinder(directory: completion.outputDirectory) },
                    onProcessAnother: { viewModel.processAnother() }
                )

            case .error:
                idleOrLoadedView(loaded: nil)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "处理失败",
            isPresented: Binding(
                get: { viewModel.appState.isShowingErrorAlert },
                set: { viewModel.appState.isShowingErrorAlert = $0 }
            )
        ) {
            Button("确定") {
                viewModel.appState.dismissError()
            }
        } message: {
            Text(viewModel.appState.errorMessage)
        }
    }

    /// 空闲态与已加载态的统一页面。
    /// 当 loaded 参数为 nil 时仅显示拖放区；
    /// 有值时同时显示文件信息、曲目预览与"开始拆分"按钮。
    @ViewBuilder
    private func idleOrLoadedView(loaded: AppState.LoadedFiles?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 拖放区：始终显示，允许重新选择文件
            DropZoneView { fileURL in
                viewModel.load(audioURL: fileURL)
            }

            if let loaded {
                // 文件信息区
                VStack(alignment: .leading, spacing: 8) {
                    Text("已加载：\(loaded.audioURL.lastPathComponent)")
                        .font(.headline)
                    Text("CUE：\(loaded.cueURL.lastPathComponent)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("专辑：\(loaded.albumTitle ?? "未知")  ·  艺术家：\(loaded.performer ?? "未知")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 曲目列表预览
                TrackListView(tracks: loaded.tracks)
                    .frame(maxHeight: .infinity)

                // 操作按钮
                HStack {
                    Spacer()
                    Button("开始拆分") {
                        viewModel.startProcessing()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: .controlAccentColor))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 在 Finder 中高亮输出目录。
    private func showInFinder(directory: URL) {
        NSWorkspace.shared.selectFile(
            directory.path,
            inFileViewerRootedAtPath: directory.deletingLastPathComponent().path
        )
    }
}
