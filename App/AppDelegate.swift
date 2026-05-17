import AppKit
import SwiftUI
import Combine

// ============================================================
// AppDelegate - 应用生命周期、菜单栏图标、系统托盘
// @MainActor: 所有 UI 代码都在主线程执行（Swift 6 并发安全）
// ============================================================
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - 属性

    /// 菜单栏状态项
    private var statusItem: NSStatusItem?
    /// 悬浮历史面板
    private var historyPanel: HistoryPanel?
    /// 剪贴板监听器
    private var clipboardMonitor: ClipboardMonitor?
    /// 数据库管理器
    private var databaseManager: DatabaseManager?
    /// iCloud 同步管理器
    private var iCloudSyncManager: ICloudDriveSyncManager?
    /// 设置窗口
    private var preferencesWindow: NSWindow?
    /// 版本更新检查器
    private var updateChecker: UpdateChecker?
    /// 更新检查订阅（自动检查发现更新时显示面板）
    private var updateCheckerCancellable: AnyCancellable?
    /// 打开面板前的前台应用（用于粘贴后归还焦点）
    private var previousActiveApp: NSRunningApplication?

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动时立即设为 accessory 模式（无 Dock 图标，仅菜单栏）
        // 注意：不在 Info.plist 中设 LSUIElement，否则启动台也不显示
        NSApp.setActivationPolicy(.accessory)

        do {
            databaseManager = try DatabaseManager()
            print("[ClipMate] 数据库初始化成功")
        } catch {
            print("[ClipMate] 数据库初始化失败: \(error)")
        }

        // 设置 Dock 图标（即使 LSUIElement=true，也要设置 applicationIconImage）
        setupDockIcon()

        // 初始化版本更新检查器（必须在 setupHistoryPanel 之前）
        updateChecker = UpdateChecker()

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

        // 初始化 iCloud Drive 同步
        if let dbManager = databaseManager {
            iCloudSyncManager = ICloudDriveSyncManager(databaseManager: dbManager)
            print("[ClipMate] iCloud Drive 同步管理器已初始化")
        }

        // 延迟 3 秒后自动检查更新（避免影响启动速度）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            updateChecker?.checkForUpdateIfNeeded()
        }

        // 监听自动检查发现更新 → 如果面板不可见则显示面板，让 SwiftUI alert 可见
        updateCheckerCancellable = updateChecker?.$updateAvailable
            .removeDuplicates()
            .filter { $0 }
            .dropFirst() // 跳过初始值 false
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self, let panel = self.historyPanel, !panel.isVisible else { return }
                    self.showHistoryPanel()
                }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        HotKeyManager.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    /// 从启动台或 Dock 点击图标时，显示历史面板
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showHistoryPanel()
        }
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
        menu.addItem(NSMenuItem(title: "检查更新...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ClipMate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - 悬浮历史面板

    private func setupHistoryPanel() {
        guard let dbManager = databaseManager else { return }
        guard let checker = updateChecker else { return }

        let contentView = HistoryContentView(
            databaseManager: dbManager,
            syncManager: iCloudSyncManager,
            updateChecker: checker,
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
            // 隐藏后检查是否需要恢复 accessory 策略（无 Dock 图标）
            self.updateActivationPolicy(forWindowAction: .hide)
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
        // 恢复激活策略（如果设置窗口也不可见，则恢复 accessory）
        updateActivationPolicy(forWindowAction: .hide)
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
            let preferencesView = PreferencesView(databaseManager: dbManager, syncManager: iCloudSyncManager, updateChecker: updateChecker ?? UpdateChecker())
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
            preferencesWindow?.delegate = self
        }

        // 关键：LSUIElement 应用必须激活才能让窗口正确显示
        updateActivationPolicy(forWindowAction: .show)
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func focusSearch() {
        showHistoryPanel()
        NotificationCenter.default.post(name: .focusSearchField, object: nil, userInfo: nil)
    }

    @objc private func checkForUpdates() {
        guard let checker = updateChecker else { return }
        // 显示面板，让 SwiftUI alert 统一处理更新提示（避免同时弹出 NSAlert 和 SwiftUI alert）
        showHistoryPanel()
        checker.forceCheck()
    }

    // MARK: - 辅助功能权限检测

    /// 启动时静默检测，仅在控制台输出日志
    /// 不弹窗，避免与 macOS 系统弹窗冲突导致双弹窗
    /// 底部栏已有醒目的黄色警告提示，用户可点击授权
    private func checkAccessibilityPermissionOnLaunch() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[ClipMate] ⚠️ 辅助功能权限未授予，快速粘贴功能不可用（底部栏有提示）")
        } else {
            print("[ClipMate] ✓ 辅助功能权限已授予")
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
            // "授权并打开系统设置" → 仅打开系统设置（不触发系统原生弹窗，避免双弹窗）
            HotKeyManager.openAccessibilitySettings()

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
                if let onGranted = onGranted {
                    pollAccessibilityPermission(onGranted: onGranted)
                }
            }
        }

        // 如果面板和设置窗口都不处于显示状态，恢复 accessory 模式
        updateActivationPolicy(forWindowAction: .hide)
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

    // MARK: - 激活策略管理

    /// 窗口操作类型
    private enum WindowAction {
        case show   // 显示窗口
        case hide   // 隐藏/关闭窗口
    }

    /// 统一管理 activationPolicy：
    /// - 面板可见 OR 设置窗口可见 → .regular（显示 Dock 图标，可接收焦点）
    /// - 两者都不可见 → .accessory（仅菜单栏图标，无 Dock 图标）
    private func updateActivationPolicy(forWindowAction action: WindowAction) {
        let panelVisible = historyPanel?.isVisible ?? false
        let prefsVisible = preferencesWindow?.isVisible ?? false
        let anyWindowVisible = panelVisible || prefsVisible

        if anyWindowVisible {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        MainActor.assumeIsolated {
            // 设置窗口关闭时，清理引用并更新激活策略
            if window == preferencesWindow {
                // 延迟一帧后更新策略（isVisible 此时可能仍为 true）
                DispatchQueue.main.async {
                    self.updateActivationPolicy(forWindowAction: .hide)
                }
            }
        }
    }
}
import Foundation
import AppKit

// ============================================================
// UpdateChecker - 版本更新检查
// 通过 GitHub Releases API 获取最新版本 tag，与当前版本比较
// 网络异常时静默失败，绝不崩溃
// ============================================================

@MainActor
class UpdateChecker: ObservableObject {

    // MARK: - 发布状态

    struct ReleaseInfo: Sendable {
        let tagName: String       // e.g. "v1.2.0"
        let version: String      // e.g. "1.2.0"
        let htmlURL: String?      // release 页面链接
        let body: String?         // release notes
    }

    // MARK: - 公开状态

    /// 检查结果
    enum CheckResult: Equatable {
        case idle           // 未检查
        case upToDate       // 已是最新版本
        case updateAvailable // 有新版本
        case failed         // 检查失败
    }

    /// 是否有可用更新
    @Published var updateAvailable: Bool = false
    /// 最新版本信息
    @Published var latestRelease: ReleaseInfo?
    /// 是否正在检查
    @Published var isChecking: Bool = false
    /// 检查结果
    @Published var checkResult: CheckResult = .idle
    /// 错误信息（仅供调试，不展示给用户）
    @Published var lastError: String?

    // MARK: - 持久化（使用 UserDefaults，@AppStorage 仅限 SwiftUI View）

    /// 用户跳过的版本号（"不再提醒"）
    private var skippedVersion: String {
        get { UserDefaults.standard.string(forKey: "skippedVersion") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }

    /// 上次检查时间戳（限制检查频率，最多每天一次）
    private var lastCheckTimestamp: Double {
        get { UserDefaults.standard.double(forKey: "lastUpdateCheckTimestamp") }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheckTimestamp") }
    }

    // MARK: - 配置

    /// GitHub 仓库所有者
    private let repoOwner = "WinterChenS"
    /// GitHub 仓库名
    private let repoName = "ClipMate"
    /// 检查间隔（秒），默认 24 小时
    private let checkInterval: TimeInterval = 24 * 60 * 60

    // MARK: - 当前版本

    /// 当前应用版本（从 Bundle 获取）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 检查更新

    /// 自动检查（受频率限制 + 跳过版本过滤）
    func checkForUpdateIfNeeded() {
        // 频率限制：距离上次检查不足 24 小时则跳过
        let now = Date().timeIntervalSince1970
        guard now - lastCheckTimestamp >= checkInterval else {
            print("[UpdateChecker] 距上次检查不足 24h，跳过")
            return
        }

        performCheck()
    }

    /// 手动检查（忽略频率限制，但仍然尊重跳过版本）
    func checkForUpdate() {
        performCheck()
    }

    /// 强制检查（忽略频率限制和跳过版本，用于"关于"页面手动检查）
    func forceCheck() {
        performCheck(ignoreSkipped: true)
    }

    // MARK: - 内部实现

    private func performCheck(ignoreSkipped: Bool = false) {
        guard !isChecking else { return }

        isChecking = true
        lastError = nil
        checkResult = .idle

        let owner = repoOwner
        let repo = repoName

        Task { [weak self] in
            guard let self = self else { return }

            do {
                let release = try await fetchLatestRelease(owner: owner, repo: repo)

                // 更新时间戳
                self.lastCheckTimestamp = Date().timeIntervalSince1970

                // 解析版本号（去掉 v 前缀）
                let remoteVersion = release.version
                let localVersion = self.currentVersion

                print("[UpdateChecker] 远程版本: \(remoteVersion), 本地版本: \(localVersion)")

                if self.isNewer(remote: remoteVersion, local: localVersion) {
                    // 检查用户是否已跳过此版本
                    if !ignoreSkipped && self.skippedVersion == remoteVersion {
                        print("[UpdateChecker] 用户已跳过版本 \(remoteVersion)")
                        self.updateAvailable = false
                        self.latestRelease = nil
                        self.checkResult = .upToDate
                    } else {
                        self.latestRelease = release
                        self.updateAvailable = true
                        self.checkResult = .updateAvailable
                    }
                } else {
                    self.updateAvailable = false
                    self.latestRelease = nil
                    self.checkResult = .upToDate
                }
            } catch {
                // 网络异常静默处理，绝不崩溃
                print("[UpdateChecker] 检查更新失败: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                self.checkResult = .failed
            }

            self.isChecking = false
        }
    }

    /// 请求 GitHub Releases API
    private nonisolated func fetchLatestRelease(owner: String, repo: String) async throws -> ReleaseInfo {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15 // 15 秒超时

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        // 404 = 还没有 release，不算错误
        if httpResponse.statusCode == 404 {
            throw UpdateError.noRelease
        }

        guard httpResponse.statusCode == 200 else {
            throw UpdateError.httpError(statusCode: httpResponse.statusCode)
        }

        // 安全解析 JSON
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateError.invalidJSON
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let htmlURL = json["html_url"] as? String
        let body = json["body"] as? String

        return ReleaseInfo(
            tagName: tagName,
            version: version,
            htmlURL: htmlURL,
            body: body
        )
    }

    // MARK: - 版本比较

    /// 语义化版本比较：remote > local → true
    private func isNewer(remote: String, local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        // 补齐到 3 段 (major.minor.patch)
        var r = remoteParts
        var l = localParts
        while r.count < 3 { r.append(0) }
        while l.count < 3 { l.append(0) }

        for i in 0..<3 {
            if r[i] > l[i] { return true }
            if r[i] < l[i] { return false }
        }
        return false // 完全相同
    }

    // MARK: - 用户操作

    /// 跳过当前可用更新（不再提醒此版本）
    func skipCurrentUpdate() {
        if let release = latestRelease {
            skippedVersion = release.version
            updateAvailable = false
            latestRelease = nil
            print("[UpdateChecker] 用户跳过版本 \(release.version)")
        }
    }

    /// 打开下载页面
    func openDownloadPage() {
        if let urlString = latestRelease?.htmlURL,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            // fallback: 打开 GitHub releases 页面
            if let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - 错误类型

enum UpdateError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidJSON
    case noRelease
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的请求地址"
        case .invalidResponse: return "无效的响应"
        case .invalidJSON: return "解析版本信息失败"
        case .noRelease: return "暂无发布版本"
        case .httpError(let code): return "请求失败 (HTTP \(code))"
        }
    }
}
import Foundation
import GRDB

// ============================================================
// ICloudDriveSyncManager - iCloud Drive 文件同步管理器
// 替代 CloudKit，使用 ubiquity container 实现跨设备同步
// 免费 Apple ID 可用
// ============================================================

// MARK: - 同步状态通知

extension Notification.Name {
    /// 同步状态变化（.userInfo["syncState"] = SyncState）
    static let cloudKitSyncStateDidChange = Notification.Name("cloudKitSyncStateDidChange")
}

/// 同步状态枚举
enum SyncState: String, Sendable {
    case idle           // 空闲
    case pushing        // 正在推送
    case pulling        // 正在拉取
    case syncing        // 推送+拉取
    case error          // 出错
    case disabled       // 未启用
}

/// 同步状态信息（供 UI 显示）
struct SyncStatusInfo {
    let state: SyncState
    let lastSyncDate: Date?
    let errorMessage: String?
    let pendingPushCount: Int
}

// MARK: - 可同步的 ClipboardItem 编码模型
// 去除 imageData 等大数据字段，单独存储图片文件

struct SyncableClipboardItem: Codable {
    var uuid: String
    var contentType: String
    var textContent: String?
    var htmlContent: String?
    var hasImage: Bool           // 标记是否有图片（图片单独存为文件）
    var imageWidth: Int?
    var imageHeight: Int?
    var fileURLStrings: String?
    var sourceAppBundleId: String?
    var sourceAppName: String?
    var charCount: Int
    var isPinned: Bool
    var isFavorite: Bool
    var searchText: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var deviceUUID: String      // 来源设备标识
}

/// 可同步的 Pinboard 编码模型
struct SyncablePinboard: Codable {
    var id: Int64
    var name: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
    var deviceUUID: String
}

/// 同步清单文件
struct SyncManifest: Codable {
    var lastSyncDate: Date
    var deviceUUID: String
    var syncedItemUUIDs: [String]     // 已同步的条目 UUID 列表
    var syncedPinboardIDs: [Int64]    // 已同步的收藏栏 ID 列表
    var version: Int = 1
}

// MARK: - ICloudDriveSyncManager

@MainActor
class ICloudDriveSyncManager: @unchecked Sendable {

    // MARK: - 属性

    /// iCloud Drive ubiquity 容器 URL
    private let ubiquityContainerURL: URL?
    private let itemsDirectory: URL?
    private let pinboardsDirectory: URL?
    private let imagesDirectory: URL?

    /// 本地数据库管理器
    private let databaseManager: DatabaseManager

    /// 当前设备 UUID
    private let deviceUUID: String

    /// 同步状态
    @Published private(set) var syncState: SyncState = .disabled
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingPushCount: Int = 0

    /// 是否启用同步
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "iCloudSyncEnabled")
            NotificationCenter.default.post(name: .iCloudSyncSettingDidChange, object: nil)
        }
    }

    /// 防抖：避免频繁推送
    private var pushTimer: Timer?
    private var pendingItems: Set<String> = [] // 待推送的 UUID 集合

    /// iCloud 文件变化监听
    private nonisolated(unsafe) var metadataQuery: NSMetadataQuery?

    /// 图片大小上限（5MB）
    private let maxImageSize = 5 * 1024 * 1024

    /// JSON 编码器/解码器
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - 初始化

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager

        // 获取 ubiquity 容器 URL
        // 容器 ID 必须与 entitlements 中的 ubiquity-container-identifiers 匹配
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clipmate.app"
        let containerIdentifier = "iCloud.\(bundleID)"
        self.ubiquityContainerURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        )

        if let containerURL = ubiquityContainerURL {
            self.itemsDirectory = containerURL.appendingPathComponent("items", isDirectory: true)
            self.pinboardsDirectory = containerURL.appendingPathComponent("pinboards", isDirectory: true)
            self.imagesDirectory = containerURL.appendingPathComponent("images", isDirectory: true)
            print("[iCloudDrive] ✓ 容器可用: \(containerURL.path)")
        } else {
            self.itemsDirectory = nil
            self.pinboardsDirectory = nil
            self.imagesDirectory = nil
            // 区分两种不可用的原因
            if FileManager.default.ubiquityIdentityToken == nil {
                print("[iCloudDrive] iCloud 未登录，同步不可用（请在系统设置中登录 iCloud 账号）")
            } else {
                print("[iCloudDrive] ubiquity 容器不可用（需要通过 Xcode 签名运行才能使用 iCloud 同步，ad-hoc/自签名构建不支持）")
            }
        }

        // 获取或生成设备 UUID
        if let saved = UserDefaults.standard.string(forKey: "clipmate_device_uuid") {
            self.deviceUUID = saved
        } else {
            let newUUID = UUID().uuidString
            UserDefaults.standard.set(newUUID, forKey: "clipmate_device_uuid")
            self.deviceUUID = newUUID
        }

        // 监听本地数据库变更通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localItemDidChange(_:)),
            name: .clipboardItemDidCreate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localItemDidChange(_:)),
            name: .clipboardItemDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localItemDidDelete(_:)),
            name: .clipboardItemDidDelete,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pinboardDidChange(_:)),
            name: .pinboardDidCreate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pinboardDidChange(_:)),
            name: .pinboardDidDelete,
            object: nil
        )

        // 监听启用/禁用
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncSettingDidChange),
            name: .iCloudSyncSettingDidChange,
            object: nil
        )

        updateSyncState(.disabled)

        // 启动 iCloud 文件变化监听
        if ubiquityContainerURL != nil {
            setupMetadataQuery()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        metadataQuery?.stop()
    }

    // MARK: - 状态管理

    private func updateSyncState(_ state: SyncState) {
        syncState = state
        NotificationCenter.default.post(
            name: .cloudKitSyncStateDidChange,
            object: nil,
            userInfo: ["syncState": state]
        )
    }

    // MARK: - iCloud 可用性检查

    /// 检查 iCloud 账号是否可用
    func checkAccountStatus() async -> Bool {
        guard ubiquityContainerURL != nil else {
            print("[iCloudDrive] ubiquity 容器不可用，跳过账号检查")
            return false
        }

        // 检查 iCloud 是否可用（通过 ubiquity identity token）
        if FileManager.default.ubiquityIdentityToken != nil {
            return true
        }

        print("[iCloudDrive] iCloud 未登录（ubiquityIdentityToken 为 nil）")
        return false
    }

    // MARK: - iCloud 文件监听（NSMetadataQuery）

    private func setupMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        if let containerURL = ubiquityContainerURL {
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@", 
                                           NSMetadataItemPathKey,
                                           containerURL.path)
        }
        query.valueListAttributes = [NSMetadataItemFSNameKey, NSMetadataItemFSSizeKey,
                                      NSMetadataItemLastUsedDateKey, NSMetadataItemContentModificationDateKey]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )

        query.start()
        self.metadataQuery = query
        print("[iCloudDrive] NSMetadataQuery 已启动")
    }

    @objc private func metadataQueryDidFinishGathering(_ notification: Notification) {
        // 首次加载完成，拉取远端数据
        if isEnabled {
            Task { await performFullSync() }
        }
    }

    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        // 远端文件有变化，拉取
        guard isEnabled else { return }
        print("[iCloudDrive] 检测到远端文件变化")
        Task { await performFullSync() }
    }

    // MARK: - 通知处理

    /// 本地条目变更 → 标记待推送
    @objc private func localItemDidChange(_ notification: Notification) {
        guard isEnabled, ubiquityContainerURL != nil else { return }
        if let uuid = notification.userInfo?["uuid"] as? String {
            pendingItems.insert(uuid)
            schedulePush()
        }
    }

    /// 本地条目删除 → 标记待推送（删除远端文件）
    @objc private func localItemDidDelete(_ notification: Notification) {
        guard isEnabled, ubiquityContainerURL != nil else { return }
        if let uuid = notification.userInfo?["uuid"] as? String {
            pendingItems.insert(uuid)
            schedulePush()
        }
    }

    /// 收藏栏变更 → 标记待推送
    @objc private func pinboardDidChange(_ notification: Notification) {
        guard isEnabled, ubiquityContainerURL != nil else { return }
        schedulePush()
    }

    /// 同步设置变化
    @objc private func syncSettingDidChange() {
        if isEnabled {
            print("[iCloudDrive] 同步已启用")
            updateSyncState(.idle)
            Task { await performFullSync() }
        } else {
            print("[iCloudDrive] 同步已禁用")
            updateSyncState(.disabled)
            pushTimer?.invalidate()
            pushTimer = nil
            pendingItems.removeAll()
        }
    }

    // MARK: - 防抖推送调度

    private func schedulePush() {
        pendingPushCount = pendingItems.count

        pushTimer?.invalidate()
        pushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performFullSync()
            }
        }
    }

    // MARK: - 核心同步流程

    /// 执行完整同步（推送 + 拉取）
    func performFullSync() async {
        guard isEnabled else { return }
        guard ubiquityContainerURL != nil else {
            errorMessage = "iCloud Drive 不可用"
            updateSyncState(.error)
            return
        }

        // 检查账号状态
        guard await checkAccountStatus() else {
            errorMessage = "iCloud 账号未登录或不可用"
            updateSyncState(.error)
            return
        }

        updateSyncState(.syncing)
        errorMessage = nil

        // 确保目录存在
        ensureDirectoriesExist()

        // 1. 推送本地变更
        await pushLocalChanges()

        // 2. 拉取远端变更
        await pullRemoteChanges()

        // 更新状态
        lastSyncDate = Date()
        pendingItems.removeAll()
        pendingPushCount = 0
        updateSyncState(.idle)

        print("[iCloudDrive] 同步完成, lastSyncDate: \(String(describing: lastSyncDate))")
    }

    // MARK: - 确保目录结构

    private func ensureDirectoriesExist() {
        guard ubiquityContainerURL != nil else { return }
        let fm = FileManager.default

        for dir in [itemsDirectory, pinboardsDirectory, imagesDirectory] {
            guard let dir = dir else { continue }
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - 推送本地变更到 iCloud Drive

    private func pushLocalChanges() async {
        guard let itemsDir = itemsDirectory else { return }

        let itemsToPush = Array(pendingItems)
        guard !itemsToPush.isEmpty else {
            // 仍然推送 pinboards
            await pushAllPinboards()
            return
        }

        print("[iCloudDrive] 开始推送 \(itemsToPush.count) 条变更")

        for uuid in itemsToPush {
            // 从本地数据库获取条目
            guard let localItem = fetchLocalItem(uuid: uuid) else {
                // 本地已删除 → 删除远端文件
                await deleteRemoteItem(uuid: uuid, in: itemsDir)
                continue
            }

            // 编码为可同步模型
            let syncable = SyncableClipboardItem(
                uuid: localItem.uuid,
                contentType: localItem.contentType.rawValue,
                textContent: localItem.textContent,
                htmlContent: localItem.htmlContent,
                hasImage: localItem.imageData != nil,
                imageWidth: localItem.imageWidth,
                imageHeight: localItem.imageHeight,
                fileURLStrings: localItem.fileURLStrings,
                sourceAppBundleId: localItem.sourceAppBundleId,
                sourceAppName: localItem.sourceAppName,
                charCount: localItem.charCount,
                isPinned: localItem.isPinned,
                isFavorite: localItem.isFavorite,
                searchText: localItem.searchText,
                createdAt: localItem.createdAt,
                updatedAt: localItem.updatedAt,
                lastUsedAt: localItem.lastUsedAt,
                useCount: localItem.useCount,
                deviceUUID: deviceUUID
            )

            // 写入 JSON 文件
            await writeSyncableItem(syncable, uuid: uuid, in: itemsDir)

            // 写入图片（如果有的话且 < 5MB）
            if let imageData = localItem.imageData,
               imageData.count <= maxImageSize,
               let imagesDir = imagesDirectory {
                await writeImageData(imageData, uuid: uuid, in: imagesDir)
            }
        }

        // 推送收藏栏
        await pushAllPinboards()

        // 更新 manifest
        await updateManifest()

        print("[iCloudDrive] 推送完成")
    }

    /// 写入单个同步条目到 iCloud Drive
    private func writeSyncableItem(_ item: SyncableClipboardItem, uuid: String, in directory: URL) async {
        let fileURL = directory.appendingPathComponent("\(uuid).json")

        do {
            let data = try encoder.encode(item)
            // 使用 NSFileCoordinator 保证并发安全
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
                try? data.write(to: url, options: .atomic)
            }
            if let coordError = coordError {
                print("[iCloudDrive] 写入失败 \(uuid): \(coordError)")
            }
        } catch {
            print("[iCloudDrive] 编码失败 \(uuid): \(error)")
        }
    }

    /// 写入图片数据到 iCloud Drive
    private func writeImageData(_ data: Data, uuid: String, in directory: URL) async {
        let fileURL = directory.appendingPathComponent("\(uuid).dat")

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
            try? data.write(to: url, options: .atomic)
        }
        if let coordError = coordError {
            print("[iCloudDrive] 图片写入失败 \(uuid): \(coordError)")
        }
    }

    /// 删除远端条目文件
    private func deleteRemoteItem(uuid: String, in directory: URL) async {
        let jsonURL = directory.appendingPathComponent("\(uuid).json")
        let imageURL = imagesDirectory?.appendingPathComponent("\(uuid).dat")

        let fm = FileManager.default
        let coordinator = NSFileCoordinator()
        var coordError: NSError?

        coordinator.coordinate(writingItemAt: jsonURL, options: .forDeleting, error: &coordError) { url in
            try? fm.removeItem(at: url)
        }

        if let imageURL = imageURL {
            var imgError: NSError?
            coordinator.coordinate(writingItemAt: imageURL, options: .forDeleting, error: &imgError) { url in
                try? fm.removeItem(at: url)
            }
        }

        print("[iCloudDrive] 已删除远端: \(uuid.prefix(8))...")
    }

    /// 推送所有收藏栏
    private func pushAllPinboards() async {
        guard let pinboardsDir = pinboardsDirectory else { return }
        guard let db = databaseManager.dbQueue else { return }

        do {
            let pinboards = try await db.read { db in
                try Pinboard.fetchAll(db)
            }

            for board in pinboards {
                guard let boardId = board.id else { continue }
                let syncable = SyncablePinboard(
                    id: boardId,
                    name: board.name,
                    colorHex: board.colorHex,
                    createdAt: board.createdAt,
                    updatedAt: board.updatedAt,
                    deviceUUID: deviceUUID
                )

                let fileURL = pinboardsDir.appendingPathComponent("pinboard_\(boardId).json")
                do {
                    let data = try encoder.encode(syncable)
                    let coordinator = NSFileCoordinator()
                    var coordError: NSError?
                    coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
                        try? data.write(to: url, options: .atomic)
                    }
                } catch {
                    print("[iCloudDrive] 收藏栏编码失败: \(error)")
                }
            }
        } catch {
            print("[iCloudDrive] 读取收藏栏失败: \(error)")
        }
    }

    /// 更新同步清单
    private func updateManifest() async {
        guard let containerURL = ubiquityContainerURL else { return }

        let manifestURL = containerURL.appendingPathComponent("sync_manifest.json")

        // 收集已同步的 UUIDs
        var syncedUUIDs: [String] = []
        if let itemsDir = itemsDirectory {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: nil) {
                syncedUUIDs = files
                    .filter { $0.pathExtension == "json" }
                    .map { $0.deletingPathExtension().lastPathComponent }
            }
        }

        let manifest = SyncManifest(
            lastSyncDate: Date(),
            deviceUUID: deviceUUID,
            syncedItemUUIDs: syncedUUIDs,
            syncedPinboardIDs: []
        )

        do {
            let data = try encoder.encode(manifest)
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: manifestURL, options: .forReplacing, error: &coordError) { url in
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            print("[iCloudDrive] 清单更新失败: \(error)")
        }
    }

    // MARK: - 从 iCloud Drive 拉取远端变更

    private func pullRemoteChanges() async {
        guard let itemsDir = itemsDirectory else { return }
        let fm = FileManager.default

        print("[iCloudDrive] 开始拉取远端变更")

        // 获取上次同步时间
        let lastSync = UserDefaults.standard.object(forKey: "icd_last_sync_date") as? Date ?? Date.distantPast

        // 1. 拉取条目
        var pulledCount = 0
        if let files = try? fm.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for fileURL in files where fileURL.pathExtension == "json" {
                // 检查文件修改时间
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > lastSync {
                    // 读取并合并
                    if let item = await readSyncableItem(at: fileURL) {
                        await mergeRemoteItem(item)
                        pulledCount += 1
                    }
                }
            }
        }

        // 2. 拉取收藏栏
        if let pinboardsDir = pinboardsDirectory {
            if let files = try? fm.contentsOfDirectory(at: pinboardsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for fileURL in files where fileURL.pathExtension == "json" {
                    if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate > lastSync {
                        if let pinboard = await readSyncablePinboard(at: fileURL) {
                            mergeRemotePinboard(pinboard)
                        }
                    }
                }
            }
        }

        // 更新拉取时间
        UserDefaults.standard.set(Date(), forKey: "icd_last_sync_date")

        print("[iCloudDrive] 拉取完成: +\(pulledCount)")
    }

    /// 读取远端条目 JSON
    private func readSyncableItem(at url: URL) async -> SyncableClipboardItem? {
        let coordinator = NSFileCoordinator()
        var result: SyncableClipboardItem?
        var coordError: NSError?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                result = try? self.decoder.decode(SyncableClipboardItem.self, from: data)
            }
        }

        if let error = coordError {
            print("[iCloudDrive] 读取失败: \(error)")
        }

        return result
    }

    /// 读取远端收藏栏 JSON
    private func readSyncablePinboard(at url: URL) async -> SyncablePinboard? {
        let coordinator = NSFileCoordinator()
        var result: SyncablePinboard?
        var coordError: NSError?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                result = try? self.decoder.decode(SyncablePinboard.self, from: data)
            }
        }

        return result
    }

    // MARK: - 合并远端变更到本地

    private func mergeRemoteItem(_ remote: SyncableClipboardItem) async {
        let uuid = remote.uuid

        // 跳过本设备创建的（避免回写）
        if remote.deviceUUID == deviceUUID { return }

        // 跳过本设备刚推送的
        if pendingItems.contains(uuid) { return }

        if let localItem = fetchLocalItem(uuid: uuid) {
            // 已存在 → last-write-wins
            if remote.updatedAt > localItem.updatedAt {
                updateLocalItem(from: remote, uuid: uuid)
                print("[iCloudDrive] 合并更新: \(uuid.prefix(8))...")
            }
        } else {
            // 不存在 → 新增
            insertLocalItem(from: remote, uuid: uuid)
            print("[iCloudDrive] 合并新增: \(uuid.prefix(8))...")
        }

        // 通知 UI 刷新
        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
    }

    private func mergeRemotePinboard(_ remote: SyncablePinboard) {
        guard remote.deviceUUID != deviceUUID else { return }
        guard let db = databaseManager.dbQueue else { return }

        do {
            try db.write { db in
                if let existing = try Pinboard.filter(Column("id") == remote.id).fetchOne(db) {
                    if remote.updatedAt > existing.updatedAt {
                        var updated = existing
                        updated.name = remote.name
                        updated.colorHex = remote.colorHex
                        updated.updatedAt = remote.updatedAt
                        try updated.update(db)
                        print("[iCloudDrive] 收藏栏更新: \(remote.name)")
                    }
                } else {
                    let newBoard = Pinboard(
                        id: remote.id,
                        name: remote.name,
                        colorHex: remote.colorHex,
                        createdAt: remote.createdAt,
                        updatedAt: remote.updatedAt
                    )
                    try newBoard.insert(db)
                    print("[iCloudDrive] 收藏栏新增: \(remote.name)")
                }
            }
        } catch {
            print("[iCloudDrive] 收藏栏合并失败: \(error)")
        }
    }

    // MARK: - 本地数据库操作

    private func fetchLocalItem(uuid: String) -> ClipboardItem? {
        guard let db = databaseManager.dbQueue else { return nil }
        do {
            return try db.read { db in
                try ClipboardItem.filter(Column("uuid") == uuid).fetchOne(db)
            }
        } catch {
            print("[iCloudDrive] 本地查询失败: \(error)")
            return nil
        }
    }

    private func insertLocalItem(from remote: SyncableClipboardItem, uuid: String) {
        guard let db = databaseManager.dbQueue else { return }
        do {
            var item = ClipboardItem(
                contentType: ClipboardContentType(rawValue: remote.contentType) ?? .text,
                textContent: remote.textContent
            )
            item.uuid = uuid
            item.htmlContent = remote.htmlContent
            item.imageWidth = remote.imageWidth
            item.imageHeight = remote.imageHeight
            item.fileURLStrings = remote.fileURLStrings
            item.sourceAppBundleId = remote.sourceAppBundleId
            item.sourceAppName = remote.sourceAppName
            item.charCount = remote.charCount
            item.isPinned = remote.isPinned
            item.isFavorite = remote.isFavorite
            item.searchText = remote.searchText
            item.createdAt = remote.createdAt
            item.updatedAt = remote.updatedAt
            item.lastUsedAt = remote.lastUsedAt
            item.useCount = remote.useCount

            // 读取图片（如果有的话）
            if remote.hasImage, let imagesDir = imagesDirectory {
                let imageURL = imagesDir.appendingPathComponent("\(uuid).dat")
                let coordinator = NSFileCoordinator()
                var coordError: NSError?
                coordinator.coordinate(readingItemAt: imageURL, options: .withoutChanges, error: &coordError) { readURL in
                    if let data = try? Data(contentsOf: readURL) {
                        item.imageData = data
                    }
                }
            }

            try db.write { db in
                try item.insert(db)
            }
        } catch {
            print("[iCloudDrive] 插入本地记录失败: \(error)")
        }
    }

    private func updateLocalItem(from remote: SyncableClipboardItem, uuid: String) {
        guard let db = databaseManager.dbQueue else { return }
        do {
            try db.write { db in
                if var item = try ClipboardItem.filter(Column("uuid") == uuid).fetchOne(db) {
                    item.textContent = remote.textContent
                    item.htmlContent = remote.htmlContent
                    item.imageWidth = remote.imageWidth
                    item.imageHeight = remote.imageHeight
                    item.isPinned = remote.isPinned
                    item.isFavorite = remote.isFavorite
                    item.updatedAt = remote.updatedAt

                    // 更新图片（如果有的话）
                    if remote.hasImage, let imagesDir = imagesDirectory {
                        let imageURL = imagesDir.appendingPathComponent("\(uuid).dat")
                        let coordinator = NSFileCoordinator()
                        var coordError: NSError?
                        coordinator.coordinate(readingItemAt: imageURL, options: .withoutChanges, error: &coordError) { readURL in
                            if let data = try? Data(contentsOf: readURL) {
                                item.imageData = data
                            }
                        }
                    }

                    try item.update(db)
                }
            }
        } catch {
            print("[iCloudDrive] 更新本地记录失败: \(error)")
        }
    }
}

// MARK: - 同步设置通知

extension Notification.Name {
    static let iCloudSyncSettingDidChange = Notification.Name("iCloudSyncSettingDidChange")
    static let clipboardItemDidCreate = Notification.Name("clipboardItemDidCreate")
    static let clipboardItemDidUpdate = Notification.Name("clipboardItemDidUpdate")
    static let clipboardItemDidDelete = Notification.Name("clipboardItemDidDelete")
    static let pinboardDidCreate = Notification.Name("pinboardDidCreate")
    static let pinboardDidDelete = Notification.Name("pinboardDidDelete")
}
