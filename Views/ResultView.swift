import SwiftUI

// MARK: - ResultView

/// 完成结果界面。
struct ResultView: View {
    /// 处理完成上下文。
    let result: AppState.Completion
    /// 处理日志（用于错误详情展示）。
    let logs: [String]
    /// 打开 Finder 回调。
    let onShowInFinder: () -> Void
    /// 再次处理回调。
    let onProcessAnother: () -> Void

    @State private var showingLogs = false

    private var metadataSummary: String {
        let r = result.metadataResult
        if r.isFullySuccessful {
            return "✅ 元数据全部写入成功（\(r.succeeded)/\(r.total)）"
        } else if r.isPartiallySuccessful {
            return "⚠️ 元数据部分成功（\(r.succeeded)/\(r.total)），\(r.failed) 个失败"
        } else {
            return "❌ 元数据写入失败（\(r.failed)/\(r.total)）"
        }
    }

    private var coverSummary: String {
        result.coverEmbedded ? "✅ 封面图已写入" : "⚠️ 未写入封面图"
    }

    private var overallIcon: String {
        result.metadataResult.isFullySuccessful ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var overallColor: Color {
        result.metadataResult.isFullySuccessful ? .green : .orange
    }

    private var hasAnyWarning: Bool {
        !result.metadataResult.isFullySuccessful || !result.coverEmbedded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: overallIcon)
                    .font(.title)
                    .foregroundStyle(overallColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("拆分完成")
                        .font(.title2.weight(.semibold))
                    if hasAnyWarning {
                        Text("存在警告，请检查以下详情")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }

            Divider()

            // Track status list
            VStack(alignment: .leading, spacing: 8) {
                Text("曲目状态")
                    .font(.headline)

                ForEach(Array(result.trackFiles.enumerated()), id: \.offset) { idx, url in
                    TrackStatusRow(
                        url: url,
                        index: idx,
                        totalCount: result.trackFiles.count,
                        failedCount: result.metadataResult.failed,
                        succeededCount: result.metadataResult.succeeded
                    )
                }
            }

            Divider()

            // Summary badges
            VStack(alignment: .leading, spacing: 8) {
                Text("处理摘要")
                    .font(.headline)

                HStack(spacing: 12) {
                    SummaryBadge(icon: "music.note.list", text: "共 \(result.trackFiles.count) 个 track")
                    SummaryBadge(icon: "tag.fill", text: metadataSummary)
                }

                HStack(spacing: 12) {
                    SummaryBadge(icon: "photo.fill", text: coverSummary)
                    SummaryBadge(icon: "folder.fill", text: "输出：\(result.outputDirectory.lastPathComponent)")
                }

                if !result.metadataResult.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("失败详情")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        ForEach(result.metadataResult.failures, id: \.self) { failure in
                            Text("• \(failure)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.05))
                    .cornerRadius(8)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 12) {
                Button("Show in Finder") {
                    onShowInFinder()
                }
                .buttonStyle(.bordered)

                Button("查看日志") {
                    showingLogs = true
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
        .sheet(isPresented: $showingLogs) {
            LogSheet(logs: logs)
        }
    }
}

// MARK: - TrackStatusRow

/// 单个曲目的状态行。
struct TrackStatusRow: View {
    let url: URL
    let index: Int
    let totalCount: Int
    let failedCount: Int
    let succeededCount: Int

    private var isFailed: Bool {
        failedCount > 0 && index >= (totalCount - failedCount)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isFailed ? .red : .green)

            Text(url.lastPathComponent)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            Text(isFailed ? "元数据失败" : "✅")
                .font(.caption)
                .foregroundStyle(isFailed ? .red : .secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isFailed ? Color.red.opacity(0.05) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - SummaryBadge

struct SummaryBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - LogSheet

struct LogSheet: View {
    let logs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("处理日志")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            ScrollView {
                Text(logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
        }
        .padding(20)
        .frame(width: 600, height: 400)
    }
}
