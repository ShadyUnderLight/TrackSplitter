import AppKit
import SwiftUI

// MARK: - AppDelegate
@objc(AppDelegate)
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 主窗口引用。
    private var window: NSWindow?
    /// 窗口控制器（持有防止 ARC 释放）。
    private var windowController: NSWindowController?

    /// 应用启动完成。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接同步创建窗口，不使用 DispatchQueue.async，
        // 确保窗口在 applicationDidFinishLaunching 返回前完全就绪。
        createWindow()
        setupMainMenu()

        // 写入日志确认此方法被调用到。
        fputs("[AppDelegate] applicationDidFinishLaunching done, window created\n", stderr)
        fflush(stderr)
    }

    /// 创建主窗口。
    private func createWindow() {
        // 创建 NSHostingController 作为窗口根视图控制器。
        let contentView = ContentView()
        let hostingController = NSHostingController(rootView: contentView)

        // 创建窗口，使用 contentViewController 确保响应链正确。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TrackSplitter"
        window.minSize = NSSize(width: 640, height: 480)
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = hostingController  // 用 contentViewController 而非直接设置 contentView
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.windowController = NSWindowController(window: window)

        fputs("[AppDelegate] window created and ordered front\n", stderr)
        fflush(stderr)
    }

    /// 配置菜单栏。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单。
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 TrackSplitter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 TrackSplitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 文件菜单。
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "打开...", action: #selector(openDocument(_:)), keyEquivalent: "o")

        // 窗口菜单。
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// 菜单"打开..."。
    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "flac") ?? .audio]
        panel.title = "选择 FLAC 文件"
        panel.message = "选择要拆分的 FLAC 整轨文件"

        if let window = self.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                fputs("[AppDelegate] file selected via sheet: \(url.path)\n", stderr)
                fflush(stderr)
                NotificationCenter.default.post(name: .didSelectFlacFile, object: url)
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url {
                fputs("[AppDelegate] file selected via modal: \(url.path)\n", stderr)
                fflush(stderr)
                NotificationCenter.default.post(name: .didSelectFlacFile, object: url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - 通知扩展
extension Notification.Name {
    static let didSelectFlacFile = Notification.Name("didSelectFlacFile")
}
