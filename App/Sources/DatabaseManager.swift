import Foundation
import GRDB

// ============================================================
// DatabaseManager - GRDB 数据库管理器
// 负责剪贴板历史、固定板、应用排除规则的持久化
// ============================================================
final class DatabaseManager: @unchecked Sendable {

    // MARK: - 数据库连接

    private var dbQueue: DatabaseQueue?

    /// 数据库路径（放在 Application Support 下）
    private var databasePath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let appFolder = appSupport.appendingPathComponent("ClipMate", isDirectory: true)

        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: appFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return appFolder.appendingPathComponent("ClipMate.sqlite").path
    }

    // MARK: - 初始化

    init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = false

        dbQueue = try DatabaseQueue(path: databasePath, configuration: config)

        try migrate()
        try seedDefaultData()

        print("[DatabaseManager] 数据库路径: \(databasePath)")
    }

    // MARK: - 数据库迁移

    private func migrate() throws {
        guard let db = dbQueue else { return }

        var migrator = DatabaseMigrator()

        // v1: 初始表结构
        migrator.registerMigration("v1_initial") { db in
            // 剪贴板历史表
            try db.create(table: "clipboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("contentType", .text).notNull()
                t.column("textContent", .text)
                t.column("htmlContent", .text)
                t.column("imageData", .blob)
                t.column("imageWidth", .integer)
                t.column("imageHeight", .integer)
                t.column("fileURLStrings", .text)
                t.column("rtfdData", .blob)
                t.column("sourceAppBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("charCount", .integer).notNull().defaults(to: 0)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("searchText", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime)
                t.column("useCount", .integer).notNull().defaults(to: 0)
            }

            // 创建全文搜索索引
            try db.create(virtualTable: "clipboard_items_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clipboard_items")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("searchText")
                t.column("textContent")
            }

            // 固定板表
            try db.create(table: "pinboards") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull().defaults(to: "#378ADD")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // 固定板与剪贴板条目关联表
            try db.create(table: "pinboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pinboardId", .integer)
                    .notNull()
                    .references("pinboards", onDelete: .cascade)
                t.column("clipboardItemId", .integer)
                    .notNull()
                    .references("clipboard_items", onDelete: .cascade)
                t.uniqueKey(["pinboardId", "clipboardItemId"])
            }

            // 应用排除规则表
            try db.create(table: "app_exclusions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleIdentifier", .text).notNull().unique()
                t.column("appName", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }

            // 创建索引
            try db.create(index: "idx_clipboard_created", on: "clipboard_items", columns: ["createdAt"])
            try db.create(index: "idx_clipboard_pinned", on: "clipboard_items", columns: ["isPinned"])
            try db.create(index: "idx_clipboard_type", on: "clipboard_items", columns: ["contentType"])
        }

        try migrator.migrate(db)
    }

    /// 初始化默认数据
    private func seedDefaultData() throws {
        guard let db = dbQueue else { return }

        try db.write { db in
            // 默认排除密码管理器
            let existingExclusion = try AppExclusion
                .filter(Column("bundleIdentifier") == "com.1password.1password")
                .fetchOne(db)

            if existingExclusion == nil {
                let exclusion = AppExclusion(
                    id: nil,
                    bundleIdentifier: "com.1password.1password",
                    appName: "1Password",
                    isEnabled: true,
                    createdAt: Date()
                )
                try exclusion.insert(db)
            }
        }
    }

    // MARK: - CRUD: ClipboardItem

    /// 保存剪贴板条目
    func save(_ item: inout ClipboardItem) throws {
        guard let db = dbQueue else { return }
        try db.write { db in
            try item.save(db)
        }
    }

    /// 获取所有历史记录（按时间倒序）
    func fetchHistory(limit: Int = 100) throws -> [ClipboardItem] {
        guard let db = dbQueue else { return [] }
        return try db.read { db in
            try ClipboardItem
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 获取固定条目
    func fetchPinned() throws -> [ClipboardItem] {
        guard let db = dbQueue else { return [] }
        return try db.read { db in
            try ClipboardItem
                .filter(Column("isPinned") == true)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// 全文搜索
    func search(query: String, limit: Int = 50) throws -> [ClipboardItem] {
        guard let db = dbQueue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try fetchHistory(limit: limit)
        }

        return try db.read { db in
            // FTS5 全文搜索
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
            let sql = """
                SELECT clipboard_items.*
                FROM clipboard_items
                JOIN clipboard_items_fts ON clipboard_items.rowid = clipboard_items_fts.rowid
                WHERE clipboard_items_fts MATCH ?
                ORDER BY clipboard_items.createdAt DESC
                LIMIT ?
                """
            return try ClipboardItem.fetchAll(db, sql: sql, arguments: [pattern?.rawPattern ?? query, limit])
        }
    }

    /// 按类型过滤
    func fetchByType(_ type: ClipboardContentType, limit: Int = 100) throws -> [ClipboardItem] {
        guard let db = dbQueue else { return [] }
        return try db.read { db in
            try ClipboardItem
                .filter(Column("contentType") == type.rawValue)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 删除指定条目
    func delete(_ item: ClipboardItem) throws {
        guard let db = dbQueue, let id = item.id else { return }
        try db.write { db in
            _ = try ClipboardItem.deleteOne(db, id: id)
        }
    }

    /// 清空所有历史（保留固定）
    func clearHistory() throws {
        guard let db = dbQueue else { return }
        try db.write { db in
            try ClipboardItem
                .filter(Column("isPinned") == false)
                .deleteAll(db)
        }
    }

    /// 清理旧记录（保留固定项和最近 N 条）
    func cleanupOldItems(keepCount: Int) throws {
        guard let db = dbQueue else { return }
        try db.write { db in
            // 用 Row 只取 id 列，避免 GRDB 尝试解码完整 ClipboardItem
            let pinnedRows = try Row.fetchAll(db, sql: "SELECT id FROM clipboard_items WHERE isPinned = 1")
            let keepIds = pinnedRows.compactMap { $0["id"] as Int64? }

            let recentRows = try Row.fetchAll(db, sql: "SELECT id FROM clipboard_items ORDER BY createdAt DESC LIMIT \(keepCount)")
            let recentIds = recentRows.compactMap { $0["id"] as Int64? }

            let allKeepIds = Set(keepIds + recentIds)

            if !allKeepIds.isEmpty {
                try ClipboardItem
                    .filter(!allKeepIds.contains(Column("id")))
                    .deleteAll(db)
            }
        }
    }

    /// 标记使用（更新 lastUsedAt 和 useCount）
    func markUsed(_ item: ClipboardItem) throws {
        guard let db = dbQueue, let id = item.id else { return }
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET lastUsedAt = ?, useCount = useCount + 1, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), Date(), id]
            )
        }
    }

    /// 切换固定状态
    func togglePinned(_ item: ClipboardItem) throws {
        guard let db = dbQueue, let id = item.id else { return }
        try db.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isPinned = NOT isPinned, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// 切换收藏状态
    func toggleFavorite(_ item: ClipboardItem) throws {
        guard let db = dbQueue, let id = item.id else { return }
        try db.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isFavorite = NOT isFavorite, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    // MARK: - CRUD: Pinboard

    func createPinboard(name: String, colorHex: String = "#378ADD") throws -> Pinboard {
        guard let db = dbQueue else { throw DatabaseError.notInitialized }
        return try db.write { db in
            var pinboard = Pinboard(
                id: nil,
                name: name,
                colorHex: colorHex,
                createdAt: Date(),
                updatedAt: Date()
            )
            try pinboard.insert(db)
            return pinboard
        }
    }

    func fetchAllPinboards() throws -> [Pinboard] {
        guard let db = dbQueue else { return [] }
        return try db.read { db in
            try Pinboard.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func deletePinboard(_ pinboard: Pinboard) throws {
        guard let db = dbQueue, let id = pinboard.id else { return }
        try db.write { db in
            _ = try Pinboard.deleteOne(db, id: id)
        }
    }

    func updatePinboard(_ pinboard: Pinboard, name: String) throws {
        guard let db = dbQueue, let id = pinboard.id else { return }
        try db.write { db in
            var updated = pinboard
            updated.name = name
            updated.updatedAt = Date()
            try updated.update(db)
        }
    }

    func addToPinboard(pinboardId: Int64, clipboardItemId: Int64) throws {
        guard let db = dbQueue else { return }
        try db.write { db in
            var item = PinboardItem(id: nil, pinboardId: pinboardId, clipboardItemId: clipboardItemId)
            try item.insert(db)
        }
    }

    func fetchItemsInPinboard(_ pinboardId: Int64) throws -> [ClipboardItem] {
        guard let db = dbQueue else { return [] }
        return try db.read { db in
            let sql = """
                SELECT clipboard_items.*
                FROM clipboard_items
                JOIN pinboard_items ON clipboard_items.id = pinboard_items.clipboardItemId
                WHERE pinboard_items.pinboardId = ?
                ORDER BY clipboard_items.createdAt DESC
                """
            return try ClipboardItem.fetchAll(db, sql: sql, arguments: [pinboardId])
        }
    }

    // MARK: - CRUD: AppExclusion

    func fetchAllExclusions() throws -> [AppExclusion] {
        guard let db = dbQueue else { return [] }
        return try db.read { db in
            try AppExclusion.order(Column("appName").asc).fetchAll(db)
        }
    }

    func addExclusion(bundleIdentifier: String, appName: String) throws {
        guard let db = dbQueue else { return }
        try db.write { db in
            var exclusion = AppExclusion(
                id: nil,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                isEnabled: true,
                createdAt: Date()
            )
            try exclusion.insert(db)
        }
    }

    func removeExclusion(_ exclusion: AppExclusion) throws {
        guard let db = dbQueue, let id = exclusion.id else { return }
        try db.write { db in
            _ = try AppExclusion.deleteOne(db, id: id)
        }
    }

    func toggleExclusion(_ exclusion: AppExclusion) throws {
        guard let db = dbQueue, let id = exclusion.id else { return }
        try db.write { db in
            try db.execute(
                sql: "UPDATE app_exclusions SET isEnabled = NOT isEnabled WHERE id = ?",
                arguments: [id]
            )
        }
    }
}

// MARK: - 数据库错误

enum DatabaseError: Error {
    case notInitialized
    case migrationFailed
}
