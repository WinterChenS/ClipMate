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

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            databaseManager = try DatabaseManager()
            print("[ClipMate] 数据库初始化成功")
        } catch {
            print("[ClipMate] 数据库初始化失败: \(error)")
        }

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        HotKeyManager.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
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

        let panelWidth: CGFloat = 720
        let panelHeight: CGFloat = 420
        let screenFrame = screen.visibleFrame
        let panelX = screenFrame.midX - panelWidth / 2
        let panelY = screenFrame.minY + 30

        print("[Panel] 显示面板，位置: (\(Int(panelX)), \(Int(panelY))), 屏幕: \(Int(screenFrame.width))×\(Int(screenFrame.height))")

        // 关键：LSUIElement 应用必须临时切换为 regular 策略才能正确激活
        NSApp.setActivationPolicy(.regular)

        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        print("[Panel] 面板已显示，isVisible = \(panel.isVisible), isKeyWindow = \(panel.isKeyWindow)")
    }

    private func hideHistoryPanel() {
        guard let panel = historyPanel else { return }

        panel.orderOut(nil)

        // 隐藏后恢复 accessory 策略（无 Dock 图标）
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - 剪贴板监听

    private func startClipboardMonitoring() {
        clipboardMonitor = ClipboardMonitor(databaseManager: databaseManager)
        clipboardMonitor?.start()
    }

    // MARK: - 粘贴操作

    private func pasteItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.contentType {
        case .text:
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
            }
        case .rtfd:
            if let data = item.rtfdData {
                pasteboard.setData(data, forType: .rtfd)
            }
        case .unknown:
            break
        }

        hideHistoryPanel()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            self.simulatePaste()
        }
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
            let preferencesView = PreferencesView()
            preferencesWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            preferencesWindow?.title = "ClipMate 偏好设置"
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
}
