import AppKit

// ============================================================
// 入口点 - 手动启动应用
// ============================================================
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
