import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ContentView
/// 主窗口视图：直接观察 SplitterViewModel，无需中间 AppState。
struct ContentView: View {
    @StateObject private var viewModel = SplitterViewModel()
    @State private var selectedOutputFormat = AudioSplitterOutputFormat.keepOriginal

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                IdleView(onFileSelected: { url in
                    selectedOutputFormat = .keepOriginal
                    viewModel.load(audioURL: url)
                })

            case .loaded(let loaded):
                LoadedView(
                    loaded: loaded,
                    onStart: { viewModel.startProcessing() },
                    selectedOutputFormat: $selectedOutputFormat
                )

            case .processing:
                ProcessingView(
                    progress: viewModel.progress,
                    logs: viewModel.logs
                )

            case .complete(let completion):
                ResultView(
                    result: completion,
                    onShowInFinder: {
                        NSWorkspace.shared.selectFile(
                            completion.outputDirectory.path,
                            inFileViewerRootedAtPath: completion.outputDirectory.deletingLastPathComponent().path
                        )
                    },
                    onProcessAnother: {
                        selectedOutputFormat = .keepOriginal
                        viewModel.processAnother()
                    }
                )

            case .error(let message):
                ErrorView(message: message) {
                    viewModel.processAnother()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .didSelectFlacFile)) { notification in
            if let url = notification.object as? URL {
                viewModel.load(audioURL: url)
            }
        }
    }
}

// MARK: - IdleViewController（纯 AppKit NSViewController）
/// 初始状态：所有交互通过 AppKit 实现，确保响应链完整。
final class IdleViewController: NSViewController {
    var onFileSelected: ((URL) -> Void)?

    private var dropZoneView: DropZoneVisualView!

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        // 图标。
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 60, weight: .thin)
        icon.contentTintColor = .controlAccentColor
        container.addSubview(icon)

        // 标题。
        let titleLabel = NSTextField(labelWithString: "TrackSplitter")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        container.addSubview(titleLabel)

        // 副标题。
        let subtitleLabel = NSTextField(labelWithString: "将 FLAC 整轨专辑拆分为独立曲目")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        container.addSubview(subtitleLabel)

        // 拖放区域。
        let dropZone = DropZoneVisualView()
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.onFileDropped = { [weak self] url in
            self?.onFileSelected?(url)
        }
        self.dropZoneView = dropZone
        container.addSubview(dropZone)

        // 选择按钮。
        let selectButton = NSButton(title: "从磁盘选择音频文件", target: self, action: #selector(selectButtonClicked))
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.bezelStyle = .rounded
        selectButton.controlSize = .large
        selectButton.keyEquivalent = "\r"
        container.addSubview(selectButton)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 500),

            icon.topAnchor.constraint(equalTo: container.topAnchor),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80),

            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            dropZone.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 32),
            dropZone.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dropZone.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dropZone.heightAnchor.constraint(equalToConstant: 160),

            selectButton.topAnchor.constraint(equalTo: dropZone.bottomAnchor, constant: 20),
            selectButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            selectButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func selectButtonClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "flac") ?? .audio,
            .init(filenameExtension: "mp3") ?? .audio,
            .init(filenameExtension: "wav") ?? .audio,
            .init(filenameExtension: "aiff") ?? .audio,
            .init(filenameExtension: "m4a") ?? .audio,
            .init(filenameExtension: "aac") ?? .audio,
            .init(filenameExtension: "ogg") ?? .audio,
            .init(filenameExtension: "opus") ?? .audio,
        ]
        panel.title = "选择音频文件"
        panel.message = "选择要拆分的整轨音频文件"
        if panel.runModal() == .OK, let url = panel.url {
            onFileSelected?(url)
        }
    }
}

// MARK: - DropZoneVisualView
final class DropZoneVisualView: NSView {
    var onFileDropped: ((URL) -> Void)?
    private var isDragOver = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFlacFile(sender) else { return [] }
        isDragOver = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFlacFile(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFlacFile(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragOver = false
        guard let url = extractFlacUrl(sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private static let _supportedExtensions: Set<String> = [
        "flac", "mp3", "wav", "aiff", "alac", "m4a", "aac", "ogg", "opus"
    ]

    private func hasFlacFile(_ info: NSDraggingInfo) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        return urls.contains { Self._supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func extractFlacUrl(_ info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return nil }
        return urls.first { Self._supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let borderColor: NSColor = isDragOver ? .systemGreen : .separatorColor
        let bgColor: NSColor = isDragOver ? NSColor.systemGreen.withAlphaComponent(0.08) : .controlBackgroundColor

        bgColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()

        borderColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        borderPath.lineWidth = 2
        if !isDragOver { borderPath.setLineDash([8, 5], count: 2, phase: 0) }
        borderPath.stroke()

        let symbolName = isDragOver ? "plus.circle.fill" : "square.and.arrow.down"
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let rect = NSRect(x: (bounds.width - 40) / 2, y: (bounds.height + 10) / 2, width: 40, height: 40)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isDragOver ? 1.0 : 0.6)
        }

        let text = "拖放音频文件到这里"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: isDragOver ? NSColor.systemGreen : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        let textRect = NSRect(x: 0, y: (bounds.height - 40) / 2, width: bounds.width, height: 20)
        text.draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - SwiftUI Wrapper
struct IdleView: NSViewControllerRepresentable {
    let onFileSelected: (URL) -> Void

    func makeNSViewController(context: Context) -> IdleViewController {
        let controller = IdleViewController()
        controller.onFileSelected = onFileSelected
        return controller
    }

    func updateNSViewController(_ nsViewController: IdleViewController, context: Context) {
        nsViewController.onFileSelected = onFileSelected
    }
}

// MARK: - LoadedView
struct LoadedView: View {
    let loaded: SplitterViewModel.LoadedFiles
    let onStart: () -> Void
    @Binding var selectedOutputFormat: AudioSplitterOutputFormat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(loaded.albumTitle ?? "未知专辑")
                        .font(.headline)
                    Text(loaded.performer ?? "未知艺术家")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(loaded.audioURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(loaded.tracks.count) 曲目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            TrackListView(tracks: loaded.tracks)
                .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Text("CUE: \(loaded.cueURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                // Output format selector
                HStack(spacing: 8) {
                    Text("输出格式：")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $selectedOutputFormat) {
                        ForEach(AudioSplitterOutputFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                Button(action: onStart) {
                    HStack(spacing: 6) {
                        Image(systemName: "scissors")
                        Text("开始拆分")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ErrorView
struct ErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("处理失败")
                .font(.title2.bold())

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("重新开始", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ResultView
struct ResultView: View {
    let result: SplitterViewModel.Completion
    let onShowInFinder: () -> Void
    let onProcessAnother: () -> Void

    private var metadataStatusIcon: String {
        if result.metadataFailedCount == 0 {
            return "checkmark.circle.fill"
        } else if result.metadataFailedCount < result.trackFiles.count {
            return "exclamationmark.circle.fill"
        } else {
            return "xmark.circle.fill"
        }
    }

    private var metadataStatusColor: Color {
        if result.metadataFailedCount == 0 {
            return .green
        } else if result.metadataFailedCount < result.trackFiles.count {
            return .orange
        } else {
            return .red
        }
    }

    private var metadataStatusText: String {
        if result.metadataFailedCount == 0 {
            return "✅ 所有 \(result.metadataSucceededCount) 个曲目元数据写入成功"
        } else if result.metadataFailedCount < result.trackFiles.count {
            return "⚠️  \(result.metadataSucceededCount) 个成功，\(result.metadataFailedCount) 个失败"
        } else {
            return "❌ 元数据写入全部失败（\(result.metadataFailedCount) 个曲目）"
        }
    }

    private var coverStatusText: String {
        if result.coverEmbedded {
            return "✅ 封面已嵌入"
        } else {
            return "⚠️  封面未获取"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：封面图。
            Group {
                if let coverData = result.coverImageData,
                   let nsImage = NSImage(data: coverData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 200, height: 200)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                        )
                }
            }
            .padding(.horizontal, 40)

            // 右侧：信息。
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.albumTitle ?? "未知专辑")
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                    Text(result.performer ?? "未知艺术家")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .foregroundColor(.secondary)
                        Text("\(result.trackFiles.count) 个曲目")
                            .font(.subheadline)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary)
                        Text(result.outputDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()

                // 元数据状态
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: metadataStatusIcon)
                            .foregroundColor(metadataStatusColor)
                        Text(metadataStatusText)
                            .font(.subheadline)
                            .foregroundColor(metadataStatusColor)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: result.coverEmbedded ? "photo.fill" : "photo")
                            .foregroundColor(result.coverEmbedded ? .green : .orange)
                        Text(coverStatusText)
                            .font(.subheadline)
                            .foregroundColor(result.coverEmbedded ? .green : .orange)
                    }

                    // 部分失败时显示错误列表
                    if !result.metadataFailures.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("失败详情：")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(result.metadataFailures.prefix(5), id: \.self) { failure in
                                Text("• \(failure)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if result.metadataFailures.count > 5 {
                                Text("• ...还有 \(result.metadataFailures.count - 5) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button(action: onShowInFinder) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("在 Finder 中显示")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onProcessAnother) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("再次处理")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
