import Foundation
import Carbon
import AppKit

// ============================================================
// HotKeyManager - 全局快捷键管理器
// 使用 Carbon RegisterEventHotKey API（最可靠，无需辅助功能权限）
// ============================================================
class HotKeyManager: @unchecked Sendable {

    /// 单例
    static let shared = HotKeyManager()

    /// 快捷键回调
    private var handlers: [String: @Sendable () -> Void] = [:]

    /// Carbon 热键注册引用（handlerKey → EventHotKeyRef）
    private var hotKeyRefs: [String: EventHotKeyRef] = [:]

    /// Carbon 热键 ID → handler key 的映射
    /// 使用 Int 作为 key（将 signature 和 id 合并编码）避免 EventHotKeyID 不遵守 Hashable 的问题
    private var hotKeyIDMap: [Int: String] = [:]

    /// 已安装的 EventHandler 引用（用于清理）
    private var eventHandlerRef: EventHandlerRef?

    /// 防抖
    private var lastTriggerTimes: [String: TimeInterval] = [:]
    private let cooldownInterval: TimeInterval = 0.35

    /// Carbon 热键 signature
    private static let hotKeySignature: OSType = 0x434D_5401 // 'CMT\x01'

    /// 实例级的自增 ID（避免 static var 并发问题）
    private var nextID: UInt32 = 1

    private init() {
        print("[HotKeyManager] 初始化完成（使用 Carbon RegisterEventHotKey API）")
    }

    // MARK: - 注册快捷键

    func registerShowPanel(_ handler: @escaping @Sendable () -> Void) {
        handlers["showPanel"] = handler
        registerCarbonHotKey(
            handlerKey: "showPanel",
            keyCode: UInt32(kVK_ANSI_V),   // 0x09
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    func registerClearHistory(_ handler: @escaping @Sendable () -> Void) {
        handlers["clearHistory"] = handler
        registerCarbonHotKey(
            handlerKey: "clearHistory",
            keyCode: UInt32(kVK_Delete),     // 0x33
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    func registerSearch(_ handler: @escaping @Sendable () -> Void) {
        handlers["search"] = handler
        registerCarbonHotKey(
            handlerKey: "search",
            keyCode: UInt32(kVK_ANSI_F),     // 0x03
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    // MARK: - Carbon Hot Key 注册

    /// 使用 Carbon RegisterEventHotKey 注册全局快捷键
    /// 这是 macOS 上最可靠的全局快捷键方案：
    /// - 不需要辅助功能权限
    /// - 对 LSUIElement 应用完全有效
    /// - 即使应用不在前台也能正常工作
    private func registerCarbonHotKey(handlerKey: String, keyCode: UInt32, modifiers: UInt32) {
        // 如果已经注册过同样的快捷键，先注销
        if let existingRef = hotKeyRefs[handlerKey] {
            UnregisterEventHotKey(existingRef)
            print("[HotKeyManager] 注销旧的 \(handlerKey) 注册")
        }

        // 确保 EventHandler 已安装（只需安装一次）
        ensureEventHandlerInstalled()

        let id = nextID
        nextID += 1

        // 使用 (signature, id) 的组合编码为 Int 作为 map key
        let mapKey = encodeHotKeyID(signature: Self.hotKeySignature, id: id)
        hotKeyIDMap[mapKey] = handlerKey

        // 注册 Carbon 热键
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)

        var hotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr, let ref = hotKeyRef else {
            print("[HotKeyManager] ❌ RegisterEventHotKey 失败: \(registerStatus), handlerKey=\(handlerKey)")
            hotKeyIDMap.removeValue(forKey: mapKey)
            return
        }

        hotKeyRefs[handlerKey] = ref
        let modStr = hotKeyLabel(handlerKey)
        print("[HotKeyManager] ✓ 已注册: \(modStr) (id=\(id))")
    }

    /// 确保全局 EventHandler 只安装一次
    private func ensureEventHandlerInstalled() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleHotKeyEvent(event)
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        if status == noErr, let ref = handlerRef {
            eventHandlerRef = ref
            print("[HotKeyManager] ✓ Carbon EventHandler 已安装")
        } else {
            print("[HotKeyManager] ❌ InstallEventHandler 失败: \(status)")
        }
    }

    /// Carbon 事件处理器回调
    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        // 从事件中提取 HotKeyID
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return OSStatus(eventNotHandledErr)
        }

        // 查找对应的 handler key
        let mapKey = encodeHotKeyID(signature: hotKeyID.signature, id: hotKeyID.id)
        guard let handlerKey = hotKeyIDMap[mapKey] else {
            return OSStatus(eventNotHandledErr)
        }

        // 防抖检查
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastTriggerTimes[handlerKey] ?? 0
        guard now - last >= cooldownInterval else { return noErr }
        lastTriggerTimes[handlerKey] = now

        let modStr = hotKeyLabel(handlerKey)
        print("[HotKeyManager] 检测到: \(modStr)")

        // 在主线程执行回调
        DispatchQueue.main.async { [weak self] in
            self?.handlers[handlerKey]?()
        }

        return noErr
    }

    // MARK: - 辅助方法

    /// 将 (signature, id) 编码为 Int，用作 Dictionary key
    private func encodeHotKeyID(signature: OSType, id: UInt32) -> Int {
        return (Int(signature) << 32) | Int(id)
    }

    /// 快捷键的可读标签
    private func hotKeyLabel(_ key: String) -> String {
        switch key {
        case "showPanel": return "⌘⇧V"
        case "clearHistory": return "⌘⇧Delete"
        case "search": return "⌘⇧F"
        default: return key
        }
    }

    // MARK: - 权限辅助

    /// 打开系统设置的辅助功能页面（保留，虽然 Carbon Hot Key 不需要此权限）
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 生命周期

    func stop() {
        // 注销所有 Carbon 热键
        for (key, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
            print("[HotKeyManager] 注销热键: \(key)")
        }
        hotKeyRefs.removeAll()
        hotKeyIDMap.removeAll()

        // 移除 EventHandler
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
            print("[HotKeyManager] Carbon EventHandler 已移除")
        }
    }
}
