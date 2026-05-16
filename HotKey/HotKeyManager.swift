import Foundation
import Carbon
import AppKit

// ============================================================
// HotKeyManager - 全局快捷键管理器
// 使用 CGEventTap 实现跨应用全局快捷键
// 注意：需要在 系统设置 > 隐私与安全性 > 辅助功能 中授权
// ============================================================
class HotKeyManager: @unchecked Sendable {

    /// 单例
    static let shared = HotKeyManager()

    /// 快捷键回调（@MainActor 闭包）
    private var handlers: [String: @Sendable () -> Void] = [:]

    /// 事件 tap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 是否获得辅助功能权限
    private(set) var hasAccessibilityPermission = false

    /// 防抖：上次触发时间戳（systemUptime）
    private var lastTriggerTimes: [String: TimeInterval] = [:]

    /// 防抖冷却间隔（秒）
    private let cooldownInterval: TimeInterval = 0.35

    private init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        if !hasAccessibilityPermission {
            print("[HotKeyManager] ⚠️ 未获得辅助功能权限，全局快捷键将无法使用")
            print("[HotKeyManager] 请前往 系统设置 > 隐私与安全性 > 辅助功能 添加此应用")
        } else {
            print("[HotKeyManager] ✓ 辅助功能权限已获取")
        }
    }

    // MARK: - 注册快捷键

    /// 注册打开历史面板（默认：⌘⇧V）
    func registerShowPanel(_ handler: @escaping @Sendable () -> Void) {
        handlers["showPanel"] = handler
        setupEventTap()
    }

    /// 注册清空历史快捷键（⌘⇧Delete）
    func registerClearHistory(_ handler: @escaping @Sendable () -> Void) {
        handlers["clearHistory"] = handler
        setupEventTap()
    }

    /// 注册搜索快捷键
    func registerSearch(_ handler: @escaping @Sendable () -> Void) {
        handlers["search"] = handler
        setupEventTap()
    }

    // MARK: - 事件 Tap 核心

    private func setupEventTap() {
        guard eventTap == nil else { return }

        if !AXIsProcessTrusted() {
            print("[HotKeyManager] ⚠️ 无辅助功能权限，跳过事件 Tap 创建")
            return
        }

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard type == .keyDown,
                  let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleKeyEvent(event)
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotKeyManager] ⚠️ CGEventTap 创建失败！")
            print("[HotKeyManager] 请确保已在 系统设置 > 隐私与安全性 > 辅助功能 中授权")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        print("[HotKeyManager] ✓ 事件 Tap 已注册，全局快捷键已启用")
    }

    /// 处理按键事件
    private func handleKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 过滤按键重复事件（长按产生的 autorepeat）
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
        if isRepeat {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // ⌘⇧V → 打开历史面板
        if keyCode == 0x09 && flags.contains(.maskCommand) && flags.contains(.maskShift) {
            // 防抖：冷却期内忽略重复触发
            let now = ProcessInfo.processInfo.systemUptime
            let lastTime = lastTriggerTimes["showPanel"] ?? 0
            guard now - lastTime >= cooldownInterval else {
                return nil // 消费事件但不触发回调
            }
            lastTriggerTimes["showPanel"] = now

            print("[HotKeyManager] 检测到 ⌘⇧V → 触发面板")
            DispatchQueue.main.async { [weak self] in
                self?.handlers["showPanel"]?()
            }
            return nil
        }

        // ⌘⇧Delete → 清空历史
        if keyCode == 0x33 && flags.contains(.maskCommand) && flags.contains(.maskShift) {
            let now = ProcessInfo.processInfo.systemUptime
            let lastTime = lastTriggerTimes["clearHistory"] ?? 0
            guard now - lastTime >= cooldownInterval else {
                return nil
            }
            lastTriggerTimes["clearHistory"] = now

            DispatchQueue.main.async { [weak self] in
                self?.handlers["clearHistory"]?()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - 生命周期

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}
