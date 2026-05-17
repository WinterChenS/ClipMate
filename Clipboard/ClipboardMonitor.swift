import Foundation
import AppKit
import os.log

// ============================================================
// ClipboardMonitor - 剪贴板变化监听器
// 通过轮询 NSPasteboard.changeCount + NSWorkspace 应用切换通知
// 检测剪贴板变化
// ============================================================
class ClipboardMonitor {

    private static let logger = Logger(subsystem: "com.clipmate.app", category: "ClipboardMonitor")

    // MARK: - 属性

    /// 定时器，用于轮询
    private var timer: Timer?

    /// 上次成功处理的 changeCount
    private var lastChangeCount: Int = 0

    /// 上一次解析失败的 changeCount（用于重试）
    private var failedChangeCount: Int?

    /// 数据库管理器（用于存储历史）
    private weak var databaseManager: DatabaseManager?

    /// 是否正在运行
    private(set) var isRunning = false

    /// 轮询间隔（秒）
    private let pollingInterval: TimeInterval = 0.5

    /// 最大历史条数（超过则清理）
    private let maxHistoryCount = 1000

    /// 内容去重指纹（最近 100 条的指纹，防止连续重复记录）
    private var recentFingerprints: [String] = []
    private let recentFingerprintsLimit = 100

    /// 要排除的应用 Bundle ID 列表
    private var excludedBundleIds: Set<String> = []

    /// NSWorkspace 通知观察者
    private var activateObserver: Any?
    private var deactivateObserver: Any?

    // MARK: - 初始化

    init(databaseManager: DatabaseManager?) {
        self.databaseManager = databaseManager
        self.lastChangeCount = NSPasteboard.general.changeCount

        // 从数据库加载排除规则
        loadExclusionRules()

        Self.logger.debug("初始化, changeCount=\(self.lastChangeCount)")
    }

    deinit {
        stop()
    }

    // MARK: - 生命周期

    /// 开始监听
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 主线程定时器（与 UI 联动）
        timer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkClipboard(reason: "timer")
        }

        // 将 timer 加入 common mode，确保在拖拽等操作时也能响应
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // 监听应用切换 — 当其他应用激活/失活时主动检查剪贴板
        // 这是关键修复：弥补 Timer 可能错过的 changeCount 变化
        let nc = NSWorkspace.shared.notificationCenter
        activateObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // 另一个应用激活了（比如 iShot Pro 截图后激活），延迟检查剪贴板
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.checkClipboard(reason: "appActivate")
            }
        }
        deactivateObserver = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // 一个应用失活了（焦点回到 ClipMate），检查剪贴板
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.checkClipboard(reason: "appDeactivate")
            }
        }

        Self.logger.debug("开始监听剪贴板, 初始 changeCount=\(self.lastChangeCount)")
    }

    /// 停止监听
    func stop() {
        timer?.invalidate()
        timer = nil

        if let obs = activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activateObserver = nil
        }
        if let obs = deactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            deactivateObserver = nil
        }

        isRunning = false
        Self.logger.debug("停止监听剪贴板")
    }

    /// 重新加载排除规则
    func reloadExclusionRules() {
        loadExclusionRules()
    }

    // MARK: - 核心：检测剪贴板变化

    private func checkClipboard(reason: String) {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        // 比较 changeCount
        guard currentCount != lastChangeCount else { return }

        // 获取当前前台应用
        let sourceApp = NSRunningApplication.currentFrontApp

        Self.logger.debug("[\(reason)] changeCount: \(self.lastChangeCount)→\(currentCount), 前台: \(sourceApp?.localizedName ?? "nil") [\(sourceApp?.bundleIdentifier ?? "nil")]")

        // 检查是否应排除
        if let bundleId = sourceApp?.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            Self.logger.debug("跳过排除的应用: \(sourceApp?.localizedName ?? bundleId)")
            lastChangeCount = currentCount
            failedChangeCount = nil
            return
        }

        // 从剪贴板读取内容
        guard let item = ClipboardItem.from(pasteboard: pasteboard, sourceApp: sourceApp) else {
            let typeList = pasteboard.types?.map { $0.rawValue } ?? []
            Self.logger.debug("无法解析剪贴板内容, types=\(typeList)")

            if failedChangeCount == currentCount {
                // 已经重试过一次，放弃
                Self.logger.debug("重试仍失败，放弃 changeCount=\(currentCount)")
                lastChangeCount = currentCount
                failedChangeCount = nil
            } else {
                // 记录失败，下次重试
                Self.logger.debug("首次解析失败，将在下次轮询重试")
                failedChangeCount = currentCount
            }
            return
        }

        // 成功解析 — 更新 lastChangeCount
        lastChangeCount = currentCount
        failedChangeCount = nil

        // 内容去重（基于 SHA256 指纹，防止碰撞）
        let fingerprint = item.contentFingerprint
        if recentFingerprints.contains(fingerprint) {
            Self.logger.debug("跳过重复内容: \(item.displayText.prefix(30))")
            return
        }
        recentFingerprints.append(fingerprint)
        if recentFingerprints.count > recentFingerprintsLimit {
            recentFingerprints.removeFirst()
        }

        Self.logger.debug("保存: \(item.contentType.rawValue), 来源=\(sourceApp?.localizedName ?? "nil")")

        // 存储到数据库
        saveItem(item)

        // 发送通知更新 UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .clipboardDidChange,
                object: item
            )
        }
    }

    // MARK: - 数据持久化

    private func saveItem(_ item: ClipboardItem) {
        guard let db = databaseManager else { return }

        do {
            var newItem = item
            try db.save(&newItem)
            try db.cleanupOldItems(keepCount: maxHistoryCount)
            Self.logger.debug("已保存到数据库, id=\(newItem.id?.description ?? "nil")")
        } catch {
            Self.logger.error("保存失败: \(error)")
        }
    }

    // MARK: - 排除规则

    private func loadExclusionRules() {
        guard let db = databaseManager else { return }

        do {
            let exclusions = try db.fetchAllExclusions()
            excludedBundleIds = Set(exclusions.filter { $0.isEnabled }.map { $0.bundleIdentifier })
            Self.logger.debug("加载 \(self.excludedBundleIds.count) 条排除规则")
        } catch {
            Self.logger.error("加载排除规则失败: \(error)")
        }
    }
}

// MARK: - 内容指纹（用于去重）

extension ClipboardItem {
    /// 内容指纹（用于去重比较，使用 SHA256 防止碰撞）
    var contentFingerprint: String {
        switch contentType {
        case .text, .html, .link:
            return "t:" + Self.sha256Hex(textContent?.data(using: .utf8) ?? Data())
        case .image:
            return "i:" + Self.sha256Hex(imageData ?? Data())
        case .fileURL:
            return "f:" + Self.sha256Hex(fileURLStrings?.data(using: .utf8) ?? Data())
        case .rtfd:
            return "r:" + Self.sha256Hex(rtfdData ?? Data())
        case .unknown:
            return "u:" + UUID().uuidString
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// CommonCrypto 桥接
import CommonCrypto
