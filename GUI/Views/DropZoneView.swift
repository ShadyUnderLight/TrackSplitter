import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DropZoneView (纯 AppKit 实现，兼容性与稳定性更高)
/// FLAC 文件拖放与选择组件。
/// 使用 NSView 封装而不是纯 SwiftUI onDrop，以避免 NSHostingView 环境下的拖放事件丢失。
struct DropZoneView: View {
    /// 文件选中回调。
    let onFileSelected: (URL) -> Void

    var body: some View {
        DropZoneViewRepresentable(onFileSelected: onFileSelected)
            .frame(minHeight: 180)
    }
}

// MARK: - AppKit 封装层
/// 对应 NSView，支持拖放和文件选择按钮。
class DropZoneNSView: NSView {
    /// 文件选中回调。
    var onFileSelected: ((URL) -> Void)?

    /// 是否处于拖放高亮状态。
    private var isDragHighlighted = false {
        didSet { needsDisplay = true }
    }

    /// 支持的音频格式列表（来自 SupportedAudioFormat）。
    private static let supportedExtensions = SupportedAudioFormat.extensions

    /// 支持的 UTType 列表（来自 SupportedAudioFormat）。
    private static var supportedTypes: [UTType] {
        SupportedAudioFormat.utTypes
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // 注册为接受文件拖放。
        registerForDraggedTypes([.fileURL])

        // 添加"选择文件"按钮。
        let button = NSButton(title: "选择音频文件", target: self, action: #selector(openFilePicker))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// 打开文件选择器。
    @objc private func openFilePicker() {
        fputs("[TrackSplitter] openFilePicker called\n", stderr)
        fflush(stderr)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.supportedTypes
        panel.title = "选择音频文件"
        panel.message = "请选择要拆分的音频文件（FLAC, MP3, WAV, AIFF, M4A, AAC, OGG, Opus）"

        // 设置为 sheet 模式，避免阻塞主事件循环。
        if let window = self.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                fputs("[TrackSplitter] File selected: \(url.path)\n", stderr)
                fflush(stderr)
                self?.onFileSelected?(url)
            }
        } else {
            // 没有 window 时用 modal 模式。
            if panel.runModal() == .OK, let url = panel.url {
                fputs("[TrackSplitter] File selected (modal): \(url.path)\n", stderr)
                fflush(stderr)
                self.onFileSelected?(url)
            }
        }
    }

    // MARK: - 拖放支持

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasValidAudioFile(sender) else {
            return []
        }
        isDragHighlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasValidAudioFile(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasValidAudioFile(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        guard let fileURL = extractAudioFile(sender) else { return false }
        fputs("[TrackSplitter] Dropped file: \(fileURL.path)\n", stderr)
        fflush(stderr)
        onFileSelected?(fileURL)
        return true
    }

    /// 检查拖放数据中是否包含有效的音频文件。
    private func hasValidAudioFile(_ info: NSDraggingInfo) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        return urls.contains { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// 从拖放数据中提取音频文件 URL。
    private func extractAudioFile(_ info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgColor = NSColor.controlBackgroundColor
        let borderColor = isDragHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor

        // 背景。
        bgColor.setFill()
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        bgPath.fill()

        // 虚线边框。
        borderColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        borderPath.lineWidth = 2
        let dashPattern: [CGFloat] = [8, 4]
        borderPath.setLineDash(dashPattern, count: 2, phase: 0)
        borderPath.stroke()

        // 中心图标和文字。
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let iconAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let iconRect = NSRect(x: 0, y: bounds.midY + 10, width: bounds.width, height: 40)
        (isDragHighlighted ? "plus.square.fill" : "square.and.arrow.down").draw(in: iconRect, withAttributes: iconAttrs)

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        let textRect = NSRect(x: 0, y: bounds.midY - 40, width: bounds.width, height: 20)
        "拖放音频文件到此处".draw(in: textRect, withAttributes: textAttrs)
    }
}

// MARK: - SwiftUI NSViewRepresentable 桥接
/// 将 DropZoneNSView 桥接到 SwiftUI。
struct DropZoneViewRepresentable: NSViewRepresentable {
    let onFileSelected: (URL) -> Void

    func makeNSView(context: Context) -> DropZoneNSView {
        let view = DropZoneNSView()
        view.onFileSelected = onFileSelected
        return view
    }

    func updateNSView(_ nsView: DropZoneNSView, context: Context) {
        nsView.onFileSelected = onFileSelected
    }
}
