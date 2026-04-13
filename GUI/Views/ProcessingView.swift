import SwiftUI

/// 处理中界面：展示进度与实时日志。
struct ProcessingView: View {
    /// 当前进度（0...1）。
    let progress: Double
    /// 实时日志数据源。
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("正在拆分...")
                .font(.title3.weight(.semibold))

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(Color(nsColor: .controlAccentColor))

            Text(String(format: "进度：%.0f%%", min(max(progress, 0), 1) * 100))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Divider()

            Text("日志")
                .font(.headline)

            logPanel
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 可滚动日志面板，新增日志时自动滚到底部。
    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .onChange(of: logs.count) { _ in
                guard let lastIndex = logs.indices.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
    }
}
