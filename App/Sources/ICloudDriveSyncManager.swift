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
