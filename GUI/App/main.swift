import AppKit

// main.swift - macOS app 标准入口。
// 直接调用 NSApplication.shared，绑定 AppDelegate，然后 run()。
// 这种写法最直接，不依赖任何 attribute 或自动逻辑。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
