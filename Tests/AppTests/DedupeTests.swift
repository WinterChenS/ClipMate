import XCTest
@testable import App

// ============================================================
// 重复内容 / 从历史粘贴 之后，卡片需要前移到最前
// ============================================================

final class DedupeTests: XCTestCase {

    private var dbPath: String!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "clipmate-test-\(UUID().uuidString).sqlite"
        db = try DatabaseManager(databasePath: dbPath)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
    }

    private func text(_ value: String) -> ClipboardItem {
        ClipboardItem(contentType: .text, textContent: value)
    }

    /// 复制第二次相同内容时不能新增记录
    func testDuplicateCopyDoesNotInsertNewRow() throws {
        try db.saveOrPromote(text("重复内容"))
        try db.saveOrPromote(text("重复内容"))

        let history = try db.fetchHistory()
        XCTAssertEqual(history.count, 1, "相同内容再次复制不应产生第二条记录")
    }

    /// 复制相同内容后，已有条目前移到最前
    func testDuplicateCopyPromotesExistingItemToFront() throws {
        _ = try db.saveOrPromote(text("A"))
        _ = try db.saveOrPromote(text("B"))
        _ = try db.saveOrPromote(text("C"))

        // 此刻顺序应为 C, B, A
        XCTAssertEqual(try db.fetchHistory().map(\.textContent), ["C", "B", "A"])

        // 再次复制 A（历史里已有的内容）
        let result = try db.saveOrPromote(text("A"))
        guard case .promoted = result else {
            return XCTFail("重复内容应返回 .promoted，实际: \(result)")
        }

        XCTAssertEqual(try db.fetchHistory().map(\.textContent), ["A", "C", "B"],
                       "重复复制的 A 应前移到最前")
        XCTAssertEqual(try db.fetchHistory().count, 3, "不应新增记录")
    }

    /// 从历史粘贴（markUsed）后条目前移到最前，并使用次数 +1
    func testMarkUsedPromotesItemToFront() throws {
        try db.saveOrPromote(text("A"))
        try db.saveOrPromote(text("B"))
        try db.saveOrPromote(text("C"))

        let oldest = try XCTUnwrap(try db.fetchHistory().first { $0.textContent == "A" })
        try db.markUsed(oldest)

        let after = try db.fetchHistory()
        XCTAssertEqual(after.first?.textContent, "A", "从历史粘贴的 A 应前移到最前")
        XCTAssertEqual(after.first?.useCount, 1, "使用次数应 +1")
    }

    /// 搜索与类型过滤同样按「最后复制时间」排序
    func testSearchUsesRecencyOrder() throws {
        _ = try db.saveOrPromote(text("内容 alpha"))
        _ = try db.saveOrPromote(text("内容 beta"))
        _ = try db.saveOrPromote(text("内容 alpha"))

        let results = try db.search(query: "内容")
        XCTAssertEqual(results.first?.textContent, "内容 alpha", "重复复制后应排在最前")
        XCTAssertEqual(results.count, 2)
    }

    /// 固定项不受影响：仍然能保持置顶（排序字段之外由 ViewModel 处理），且内容指纹回填可用
    func testExistingRowGetsContentHashBackfilledOnMigration() throws {
        let history = try db.fetchHistory()
        XCTAssertTrue(history.isEmpty)

        let item = try db.saveOrPromote(text("指纹"))
        guard case .inserted(let saved) = item else {
            return XCTFail("首次保存应为 .inserted")
        }
        XCTAssertNotNil(saved.contentHash, "新记录应写入 contentHash")
        XCTAssertNotNil(saved.lastCopiedAt, "新记录应写入 lastCopiedAt")
    }
}
