import XCTest
@testable import App

// ============================================================
// 迁移回归：拿真实数据库的副本跑一遍 v2 迁移，确认不丢数据、不改变现有顺序
//   CLIPMATE_REAL_DB="/path/to/ClipMate.sqlite" swift test --filter MigrationRegressionTests
// ============================================================

final class MigrationRegressionTests: XCTestCase {

    func testMigrationOnRealDatabaseCopy() throws {
        guard let source = ProcessInfo.processInfo.environment["CLIPMATE_REAL_DB"],
              FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("未提供 CLIPMATE_REAL_DB，跳过真实数据库迁移回归")
        }

        let copyPath = NSTemporaryDirectory() + "clipmate-migration-\(UUID().uuidString).sqlite"
        try FileManager.default.copyItem(atPath: source, toPath: copyPath)
        defer { try? FileManager.default.removeItem(atPath: copyPath) }

        // 迁移前的顺序快照（旧排序键 = createdAt）
        let before = try snapshotIds(path: copyPath, orderBy: "createdAt DESC, id DESC")
        XCTAssertFalse(before.isEmpty, "真实库应有数据")

        // 打开即触发 v2 迁移
        let db = try DatabaseManager(databasePath: copyPath)
        let after = try db.fetchHistory(limit: 100_000)

        XCTAssertEqual(after.count, before.count, "迁移不应增删记录")
        XCTAssertEqual(after.compactMap(\.id), before, "迁移后顺序应与原 createdAt 顺序一致")

        let missingHash = after.filter { $0.contentHash == nil }
        XCTAssertTrue(missingHash.allSatisfy { $0.computeContentHash() == nil },
                      "只有内容为空/无法哈希的条目才允许没有 contentHash，共 \(missingHash.count) 条")
        XCTAssertTrue(after.allSatisfy { $0.lastCopiedAt != nil }, "所有条目都应回填 lastCopiedAt")

        // 迁移后重复内容应被识别：拿历史里第一条文字内容再复制一次
        if let textItem = after.first(where: { $0.contentType == .text && !($0.textContent ?? "").isEmpty }),
           let text = textItem.textContent {
            let result = try db.saveOrPromote(ClipboardItem(contentType: .text, textContent: text))
            XCTAssertTrue(result.isPromoted, "历史已有内容再次复制应命中已有记录而非新增")
            XCTAssertEqual(result.item.id, textItem.id)
            let newest = try db.fetchHistory(limit: 1).first
            XCTAssertEqual(newest?.id, textItem.id, "前移后应排在最前")
        }
    }

    private func snapshotIds(path: String, orderBy: String) throws -> [Int64] {
        let db = try DatabaseQueue(path: path, configuration: {
            var c = Configuration()
            c.readonly = true
            return c
        }())
        return try db.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM clipboard_items ORDER BY \(orderBy)")
        }
    }
}

import GRDB
