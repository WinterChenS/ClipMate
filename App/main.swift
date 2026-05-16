import AppKit

// ============================================================
// 入口点 - 手动启动应用，不使用 @main 注解
// 这样可以完全控制应用启动顺序和生命周期
// ============================================================
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
