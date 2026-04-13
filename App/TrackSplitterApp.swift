import AppKit
import SwiftUI

// MARK: - 应用入口
// 使用 NSApplicationMain 属性，自动完成 app 初始化、AppDelegate 绑定和主循环启动。
// 不需要手写 main()，避免可执行表达式与 @main 冲突。
@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    /// 主窗口引用，避免被 ARC 提前释放。
    private var window: NSWindow?

    /// 应用启动入口。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建主窗口。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TrackSplitter"
        window.minSize = NSSize(width: 600, height: 400)
        window.backgroundColor = .windowBackgroundColor

        // 将 SwiftUI ContentView 作为窗口根视图。
        let contentView = ContentView()
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 激活为前台应用并聚焦窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 持有窗口引用，防止被 ARC 提前释放。
        self.window = window
    }

    /// 关闭最后一个窗口时退出应用。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
