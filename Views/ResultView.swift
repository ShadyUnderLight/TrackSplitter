import SwiftUI

/// 完成结果界面。
struct ResultView: View {
    /// 处理完成上下文。
    let result: AppState.Completion
    /// 打开 Finder 回调。
    let onShowInFinder: () -> Void
    /// 再次处理回调。
    let onProcessAnother: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("拆分完成", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(nsColor: .controlAccentColor))

            Group {
                Text("输出目录：\(result.outputDirectory.path)")
                Text("生成文件数：\(result.trackFiles.count)")
                Text("专辑：\(result.albumTitle ?? "未知")")
                Text("艺术家：\(result.performer ?? "未知")")
            }
            .font(.body)
            .textSelection(.enabled)

            Spacer()

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    onShowInFinder()
                }
                .buttonStyle(.bordered)

                Button("Process Another") {
                    onProcessAnother()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .controlAccentColor))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
