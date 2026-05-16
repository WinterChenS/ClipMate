import Foundation
import AppKit

// ============================================================
// ClipboardMonitor - 剪贴板变化监听器
// 通过轮询 NSPasteboard.changeCount 检测剪贴板变化
// ============================================================
class ClipboardMonitor {

    // MARK: - 属性

    /// 定时器，用于轮询
    private var timer: Timer?

    /// 上次记录的 changeCount（用于判断是否变化）
    private var lastChangeCount: Int = 0

    /// 数据库管理器（用于存储历史）
    private weak var databaseManager: DatabaseManager?

    /// 是否正在运行
    private(set) var isRunning = false

    /// 轮询间隔（秒）
    private let pollingInterval: TimeInterval = 0.5

    /// 最大历史条数（超过则清理）
    private let maxHistoryCount = 1000

    /// 内容去重哈希（最近 50 条的哈希，防止连续重复记录）
    private var recentHashes: [Int] = []
    private let recentHashesLimit = 50

    /// 要排除的应用 Bundle ID 列表
    private var excludedBundleIds: Set<String> = []

    // MARK: - 初始化

    init(databaseManager: DatabaseManager?) {
        self.databaseManager = databaseManager
        self.lastChangeCount = NSPasteboard.general.changeCount

        // 从数据库加载排除规则
        loadExclusionRules()
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
            self?.checkClipboard()
        }

        // 将 timer 加入 common mode，确保在拖拽等操作时也能响应
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[ClipboardMonitor] 开始监听剪贴板...")
    }

    /// 停止监听
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        print("[ClipboardMonitor] 停止监听剪贴板")
    }

    /// 重新加载排除规则
    func reloadExclusionRules() {
        loadExclusionRules()
    }

    // MARK: - 核心：检测剪贴板变化

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        // 比较 changeCount — 这是 macOS 提供的剪贴板版本号
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 获取当前前台应用（判断来源）
        let sourceApp = NSRunningApplication.currentFrontApp

        // 检查是否应排除
        if let bundleId = sourceApp?.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            print("[ClipboardMonitor] 跳过排除的应用: \(sourceApp?.localizedName ?? bundleId)")
            return
        }

        // 从剪贴板读取内容
        guard let item = ClipboardItem.from(pasteboard: pasteboard, sourceApp: sourceApp) else {
            return
        }

        // 内容去重
        let hash = item.contentHash
        if recentHashes.contains(hash) {
            return
        }
        recentHashes.append(hash)
        if recentHashes.count > recentHashesLimit {
            recentHashes.removeFirst()
        }

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
            // 插入新记录
            var newItem = item
            try db.save(&newItem)

            // 清理超过上限的历史记录（保留固定项）
            try db.cleanupOldItems(keepCount: maxHistoryCount)

            print("[ClipboardMonitor] 保存剪贴板内容: \(item.displayText.prefix(50))")
        } catch {
            print("[ClipboardMonitor] 保存失败: \(error)")
        }
    }

    // MARK: - 排除规则

    private func loadExclusionRules() {
        guard let db = databaseManager else { return }

        do {
            let exclusions = try db.fetchAllExclusions()
            excludedBundleIds = Set(exclusions.filter { $0.isEnabled }.map { $0.bundleIdentifier })
            print("[ClipboardMonitor] 加载 \(excludedBundleIds.count) 条排除规则")
        } catch {
            print("[ClipboardMonitor] 加载排除规则失败: \(error)")
        }
    }
}

// MARK: - 内容哈希（用于去重）

extension ClipboardItem {
    /// 内容指纹哈希（用于快速去重比较）
    var contentHash: Int {
        switch contentType {
        case .text, .html, .link:
            return textContent.hashValue
        case .image:
            return imageData?.prefix(1024).hashValue ?? 0
        case .fileURL:
            return fileURLStrings.hashValue
        case .rtfd:
            return rtfdData?.prefix(1024).hashValue ?? 0
        case .unknown:
            return uuid.hashValue
        }
    }
}
