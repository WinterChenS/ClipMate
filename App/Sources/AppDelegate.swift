import AppKit
import SwiftUI

// ============================================================
// AppDelegate - 应用生命周期、菜单栏图标、系统托盘
// @MainActor: 所有 UI 代码都在主线程执行（Swift 6 并发安全）
// ============================================================
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 属性

    /// 菜单栏状态项
    private var statusItem: NSStatusItem?
    /// 悬浮历史面板
    private var historyPanel: HistoryPanel?
    /// 剪贴板监听器
    private var clipboardMonitor: ClipboardMonitor?
    /// 数据库管理器
    private var databaseManager: DatabaseManager?
    /// 设置窗口
    private var preferencesWindow: NSWindow?
    /// 打开面板前的前台应用（用于粘贴后归还焦点）
    private var previousActiveApp: NSRunningApplication?

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            databaseManager = try DatabaseManager()
            print("[ClipMate] 数据库初始化成功")
        } catch {
            print("[ClipMate] 数据库初始化失败: \(error)")
        }

        // 设置 Dock 图标（即使 LSUIElement=true，也要设置 applicationIconImage）
        setupDockIcon()

        setupStatusItem()
        startClipboardMonitoring()
        registerGlobalShortcuts()
        setupHistoryPanel()

        // 监听通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPreferences),
            name: .openPreferences,
            object: nil
        )

        // 监听排除规则变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(exclusionRulesDidChange),
            name: .exclusionRulesDidChange,
            object: nil
        )

        // 启动时检测辅助功能权限
        checkAccessibilityPermissionOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        HotKeyManager.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Dock 图标

    /// 设置 Dock 图标（从 icns 文件加载）
    private func setupDockIcon() {
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
            print("[ClipMate] Dock 图标已设置")
        } else {
            print("[ClipMate] ⚠️ 未找到 AppIcon.icns，Dock 图标为空")
        }
    }

    @objc private func exclusionRulesDidChange() {
        clipboardMonitor?.reloadExclusionRules()
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipMate") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "📋"
        }

        button.toolTip = "ClipMate - 剪贴板管理器"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleHistoryPanel()
        }
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "打开历史面板", action: #selector(toggleHistoryPanel), keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())

        let pinboardItem = NSMenuItem(title: "固定板", action: nil, keyEquivalent: "")
        let pinboardSubmenu = NSMenu()
        pinboardSubmenu.addItem(NSMenuItem(title: "代码片段", action: nil, keyEquivalent: ""))
        pinboardSubmenu.addItem(NSMenuItem(title: "常用回复", action: nil, keyEquivalent: ""))
        pinboardSubmenu.addItem(NSMenuItem.separator())
        pinboardSubmenu.addItem(NSMenuItem(title: "管理固定板...", action: nil, keyEquivalent: ""))
        pinboardItem.submenu = pinboardSubmenu
        menu.addItem(pinboardItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "搜索...", action: #selector(focusSearch), keyEquivalent: "f"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "偏好设置...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ClipMate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - 悬浮历史面板

    private func setupHistoryPanel() {
        guard let dbManager = databaseManager else { return }

        let contentView = HistoryContentView(
            databaseManager: dbManager,
            onItemSelected: { [weak self] item in
                self?.pasteItem(item)
            },
            onPastePlainText: { [weak self] item in
                self?.pasteItemAsPlainText(item)
            },
            onClose: { [weak self] in
                self?.hideHistoryPanel()
            }
        )

        historyPanel = HistoryPanel(contentView: contentView)
    }

    @objc private func toggleHistoryPanel() {
        print("[Panel] toggleHistoryPanel 被调用，panel 存在: \(historyPanel != nil)")

        guard let panel = historyPanel else {
            print("[Panel] ❌ historyPanel 为 nil！")
            return
        }

        if panel.isVisible {
            print("[Panel] 面板当前可见 → 隐藏")
            hideHistoryPanel()
        } else {
            print("[Panel] 面板当前不可见 → 显示")
            showHistoryPanel()
        }
    }

    private func showHistoryPanel() {
        guard let panel = historyPanel else {
            print("[Panel] showHistoryPanel: panel 为 nil")
            return
        }
        guard let screen = NSScreen.main else {
            print("[Panel] showHistoryPanel: NSScreen.main 为 nil")
            return
        }

        // 关键：在切换 activationPolicy 之前记录当前前台应用
        // 否则 setActivationPolicy(.regular) + activate 会让自己变成前台，拿到的就是自己
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        // 贴住屏幕底部，全宽布局（类似 Paste app）
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let panelWidth = screenFrame.width
        let panelHeight: CGFloat = 400
        let panelX = screenFrame.origin.x
        let targetY = visibleFrame.minY
        let startY = targetY - panelHeight // 从屏幕下方开始

        print("[Panel] 显示面板，位置: (\(Int(panelX)), \(Int(targetY))), 大小: \(Int(panelWidth))×\(Int(panelHeight))")

        // 关键：LSUIElement 应用必须临时切换为 regular 策略才能正确激活
        NSApp.setActivationPolicy(.regular)

        // 初始位置：面板在屏幕下方（不可见）
        panel.setFrame(NSRect(x: panelX, y: startY, width: panelWidth, height: panelHeight), display: false)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        // 动画：从底部滑入 + 淡入
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(x: panelX, y: targetY, width: panelWidth, height: panelHeight), display: true)
            panel.animator().alphaValue = 1.0
        }, completionHandler: nil)

        print("[Panel] 面板已显示，isVisible = \(panel.isVisible), isKeyWindow = \(panel.isKeyWindow)")
    }

    private func hideHistoryPanel() {
        guard let panel = historyPanel else { return }

        let currentFrame = panel.frame
        let targetY = currentFrame.origin.y - currentFrame.height // 向下滑出屏幕

        // 动画：向下滑出 + 淡出
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(NSRect(x: currentFrame.origin.x, y: targetY, width: currentFrame.width, height: currentFrame.height), display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
            // 隐藏后恢复 accessory 策略（无 Dock 图标）
            NSApp.setActivationPolicy(.accessory)
        })
    }

    // MARK: - 剪贴板监听

    private func startClipboardMonitoring() {
        clipboardMonitor = ClipboardMonitor(databaseManager: databaseManager)
        clipboardMonitor?.start()
    }

    // MARK: - 粘贴操作

    private func pasteItem(_ item: ClipboardItem) {
        // 先记录要写入 pasteboard 的内容
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.contentType {
        case .text, .link:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .fileURL:
            if let urls = item.fileURLs {
                pasteboard.writeObjects(urls as [NSURL])
            }
        case .html:
            if let html = item.htmlContent {
                pasteboard.setString(html, forType: .html)
                // 同时写入纯文本，确保 Cmd+V 在任何输入框都能粘贴
                pasteboard.setString(item.textContent ?? html, forType: .string)
            }
        case .rtfd:
            if let data = item.rtfdData {
                pasteboard.setData(data, forType: .rtfd)
                // 同时写入纯文本
                if let text = item.textContent {
                    pasteboard.setString(text, forType: .string)
                }
            }
        case .unknown:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        }

        // 粘贴操作：立即隐藏面板并归还焦点
        hidePanelImmediately()

        // 延迟后模拟 Cmd+V，增加延迟确保目标应用拿到焦点
        Task { @MainActor in
            // 检查辅助功能权限（模拟按键需要）
            if AXIsProcessTrusted() {
                await self.performPasteSequence()
            } else {
                self.ensureAccessibilityPermission(item: item, asPlainText: false)
            }
        }
    }

    /// 以纯文本粘贴（从任何内容类型提取纯文本）
    private func pasteItemAsPlainText(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var plainText = ""
        switch item.contentType {
        case .text, .html, .rtfd, .link:
            plainText = item.textContent ?? ""
        case .fileURL:
            plainText = item.fileURLs?.map { $0.path }.joined(separator: "\n") ?? ""
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                plainText = "[图片 \(w)×\(h)]"
            } else {
                plainText = "[图片]"
            }
        case .unknown:
            plainText = item.textContent ?? ""
        }

        guard !plainText.isEmpty else { return }

        pasteboard.setString(plainText, forType: .string)
        hidePanelImmediately()

        Task { @MainActor in
            if AXIsProcessTrusted() {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms，等待目标应用获得焦点
                self.simulatePaste()
            } else {
                self.ensureAccessibilityPermission(item: item, asPlainText: true)
            }
        }
    }

    /// 立即隐藏面板（无动画），用于粘贴操作
    private func hidePanelImmediately() {
        guard let panel = historyPanel else { return }

        // 先激活目标应用，再隐藏面板（顺序很重要）
        if let targetApp = previousActiveApp, targetApp != NSRunningApplication.current {
            targetApp.activate()
        }

        panel.orderOut(nil)
        // 恢复 accessory 策略（无 Dock 图标）
        NSApp.setActivationPolicy(.accessory)
    }

    /// 焦点切换 + 延迟 + 模拟粘贴的完整序列
    private func performPasteSequence() async {
        // 先等待一小段时间让系统完成焦点切换
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // 强制激活之前的前台应用
        if let targetApp = previousActiveApp {
            targetApp.activate()
        }

        // 再等待确保激活完成
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        simulatePaste()
    }

    private func simulatePaste() {
        let source: CGEventSource? = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(0x09),
            keyDown: true
        ) else { return }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(0x09),
            keyDown: false
        ) else { return }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - 全局快捷键

    private func registerGlobalShortcuts() {
        HotKeyManager.shared.registerShowPanel { [weak self] in
            // handler 已在主线程（由 DispatchQueue.main.async 调度），
            // 使用 assumeIsolated 避免额外 Task 调度开销
            MainActor.assumeIsolated {
                self?.toggleHistoryPanel()
            }
        }
    }

    // MARK: - 其他操作

    @objc private func openPreferences() {
        if preferencesWindow == nil {
            guard let dbManager = databaseManager else {
                print("[ClipMate] ⚠️ 数据库未初始化，无法打开偏好设置")
                return
            }
            let preferencesView = PreferencesView(databaseManager: dbManager)
            preferencesWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            preferencesWindow?.title = "ClipMate 偏好设置"
            preferencesWindow?.appearance = NSAppearance(named: .darkAqua)
            preferencesWindow?.contentView = NSHostingView(rootView: preferencesView)
            preferencesWindow?.center()
            preferencesWindow?.isReleasedWhenClosed = false
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func focusSearch() {
        showHistoryPanel()
        NotificationCenter.default.post(name: .focusSearchField, object: nil, userInfo: nil)
    }

    // MARK: - 辅助功能权限检测

    /// 启动时静默检测，首次无权限时弹窗引导
    private func checkAccessibilityPermissionOnLaunch() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[ClipMate] ⚠️ 辅助功能权限未授予，快速粘贴功能不可用")
            // 延迟 1s 弹窗，等应用 UI 就绪
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.requestAccessibilityPermission(
                    title: "需要辅助功能权限",
                    message: "ClipMate 需要「辅助功能」权限才能将内容快速粘贴到其他应用。\n\n"
                        + "如果您刚覆盖安装了新版本，系统可能无法自动识别新版本。"
                        + "请在系统设置中先删除旧的 ClipMate 条目，再重新添加。",
                    allowRetry: false
                )
            }
        }
    }

    /// 粘贴前检测权限，无权限时弹窗提示
    /// - Parameter item: 当前要粘贴的条目（用于重试时重新粘贴）
    /// - Parameter asPlainText: 是否以纯文本粘贴
    private func ensureAccessibilityPermission(item: ClipboardItem, asPlainText: Bool = false) {
        let trusted = AXIsProcessTrusted()
        if trusted {
            return
        }

        print("[ClipMate] ⚠️ 辅助功能权限未授予，模拟粘贴失败")
        requestAccessibilityPermission(
            title: "快速粘贴需要辅助功能权限",
            message: "当前没有辅助功能权限，无法模拟 ⌘V 粘贴。\n\n"
                + "内容已复制到剪贴板，您可以手动按 ⌘V 粘贴。\n\n"
                + "如果您刚覆盖安装了新版本，请在系统设置中先删除旧的 ClipMate 条目，再点击下方按钮重新添加。",
            allowRetry: true
        ) { [weak self] in
            // 用户授权成功后自动重试粘贴
            guard let self = self else { return }
            if asPlainText {
                self.retryPaste(item, asPlainText: true)
            } else {
                self.retryPaste(item, asPlainText: false)
            }
        }
    }

    /// 授权后重新尝试粘贴（不重新显示面板）
    private func retryPaste(_ item: ClipboardItem, asPlainText: Bool) {
        // 重新写入 pasteboard（之前可能被其他应用覆盖）
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if asPlainText {
            var plainText = ""
            switch item.contentType {
            case .text, .html, .rtfd, .link:
                plainText = item.textContent ?? ""
            case .fileURL:
                plainText = item.fileURLs?.map { $0.path }.joined(separator: "\n") ?? ""
            case .image:
                if let w = item.imageWidth, let h = item.imageHeight {
                    plainText = "[图片 \(w)×\(h)]"
                } else {
                    plainText = "[图片]"
                }
            case .unknown:
                plainText = item.textContent ?? ""
            }
            guard !plainText.isEmpty else { return }
            pasteboard.setString(plainText, forType: .string)
        } else {
            switch item.contentType {
            case .text, .link:
                if let text = item.textContent {
                    pasteboard.setString(text, forType: .string)
                }
            case .image:
                if let data = item.imageData, let image = NSImage(data: data) {
                    pasteboard.writeObjects([image])
                }
            case .fileURL:
                if let urls = item.fileURLs {
                    pasteboard.writeObjects(urls as [NSURL])
                }
            case .html:
                if let html = item.htmlContent {
                    pasteboard.setString(html, forType: .html)
                    pasteboard.setString(item.textContent ?? html, forType: .string)
                }
            case .rtfd:
                if let data = item.rtfdData {
                    pasteboard.setData(data, forType: .rtfd)
                    if let text = item.textContent {
                        pasteboard.setString(text, forType: .string)
                    }
                }
            case .unknown:
                if let text = item.textContent {
                    pasteboard.setString(text, forType: .string)
                }
            }
        }

        // 激活目标应用并模拟粘贴
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if let targetApp = self.previousActiveApp {
                targetApp.activate()
            }
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            self.simulatePaste()
        }
    }

    /// 显示权限引导 alert 并触发系统原生授权弹窗
    /// - Parameters:
    ///   - title: alert 标题
    ///   - message: alert 正文
    ///   - allowRetry: 是否显示"重试粘贴"按钮
    ///   - onGranted: 用户授权成功后的回调（用于重试粘贴）
    private func requestAccessibilityPermission(
        title: String,
        message: String,
        allowRetry: Bool,
        onGranted: (() -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "辅助功能权限")

        alert.addButton(withTitle: "授权并打开系统设置")
        alert.addButton(withTitle: "稍后")

        if allowRetry {
            alert.addButton(withTitle: "已授权，重试粘贴")
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 强制将 alert 窗口拉到最前面（LSUIElement 应用切到 .regular 后窗口不会自动前置）
        alert.window.level = .floating
        alert.window.orderFrontRegardless()

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // "授权并打开系统设置" → 打开系统设置 + 触发系统原生弹窗
            HotKeyManager.openAccessibilitySettings()
            // 使用 AXIsProcessTrustedWithOptions 触发系统原生授权弹窗
            // macOS 会自动匹配当前进程签名，引导用户正确添加
            triggerSystemAccessibilityPrompt()

            // 如果允许重试，持续轮询权限状态直到用户授权或取消
            if allowRetry, let onGranted = onGranted {
                pollAccessibilityPermission(onGranted: onGranted)
            }
        } else if allowRetry && response == .alertThirdButtonReturn {
            // "已授权，重试粘贴" → 检查一次权限，有则重试
            if AXIsProcessTrusted() {
                onGranted?()
            } else {
                // 仍然没有权限，打开系统设置
                HotKeyManager.openAccessibilitySettings()
                triggerSystemAccessibilityPrompt()
                if let onGranted = onGranted {
                    pollAccessibilityPermission(onGranted: onGranted)
                }
            }
        }

        // 如果面板不处于显示状态，恢复 accessory 模式
        if !(historyPanel?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 触发 macOS 系统原生辅助功能授权弹窗
    private nonisolated func triggerSystemAccessibilityPrompt() {
        // 直接使用 kAXTrustedCheckOptionPrompt 的字符串值 "AXTrustedCheckOptionPrompt"
        // 避免 Swift 6 对 kAXTrustedCheckOptionPrompt 变量的并发安全检查
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 轮询权限状态，用户在系统设置中授权后自动回调
    private func pollAccessibilityPermission(onGranted: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            // 最多轮询 60 秒（每 0.5s 检查一次）
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                if AXIsProcessTrusted() {
                    print("[ClipMate] ✓ 用户已授予辅助功能权限")
                    onGranted()
                    return
                }
            }
            print("[ClipMate] 等待权限授权超时")
        }
    }
}
