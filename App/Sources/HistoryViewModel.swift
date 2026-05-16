import Foundation
import AppKit
import Combine

// ============================================================
// HistoryViewModel - 历史面板数据管理
// 负责加载、搜索、过滤、固定、收藏等业务逻辑
// ============================================================
class HistoryViewModel: ObservableObject {

    // MARK: - Published 属性（SwiftUI 自动绑定）

    @Published var items: [ClipboardItem] = []
    @Published var filteredItems: [ClipboardItem] = []
    @Published var pinboards: [Pinboard] = []
    @Published var pinboardItems: [ClipboardItem] = []
    @Published var favorites: [ClipboardItem] = []
    @Published var searchQuery: String = ""
    @Published var selectedContentType: ClipboardContentType?
    @Published var selectedPinboardId: Int64? = nil
    @Published var isLoading: Bool = false

    // MARK: - 属性

    private let databaseManager: DatabaseManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager

        // 监听搜索框变化（防抖 300ms）
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
    }

    // MARK: - 数据加载

    /// 加载历史记录
    func loadHistory() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                var history = try self.databaseManager.fetchHistory(limit: 200)

                // 固定项排在最前
                let pinned = history.filter { $0.isPinned }
                let unpinned = history.filter { !$0.isPinned }
                history = pinned + unpinned

                DispatchQueue.main.async {
                    self.items = history
                    self.filteredItems = history
                    self.isLoading = false
                }
            } catch {
                print("[HistoryViewModel] 加载历史失败: \(error)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }

    /// 全文搜索
    func performSearch(query: String? = nil) {
        let q = query ?? searchQuery

        if q.isEmpty {
            filteredItems = items
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let results = try self.databaseManager.search(query: q)
                DispatchQueue.main.async {
                    self.filteredItems = results
                }
            } catch {
                print("[HistoryViewModel] 搜索失败: \(error)")
            }
        }
    }

    /// 按类型过滤
    func filterByType(_ type: ClipboardContentType?) {
        selectedContentType = type
        if let type = type {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let results = try self.databaseManager.fetchByType(type)
                    DispatchQueue.main.async {
                        self.filteredItems = results
                    }
                } catch {
                    print("[HistoryViewModel] 类型过滤失败: \(error)")
                }
            }
        } else {
            filteredItems = items
        }
    }

    // MARK: - Pinboard

    func loadPinboards() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let boards = try self.databaseManager.fetchAllPinboards()
                DispatchQueue.main.async {
                    self.pinboards = boards
                }
            } catch {
                print("[HistoryViewModel] 加载固定板失败: \(error)")
            }
        }
    }

    func loadPinboardItems(_ pinboard: Pinboard) {
        guard let id = pinboard.id else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let items = try self.databaseManager.fetchItemsInPinboard(id)
                DispatchQueue.main.async {
                    self.pinboardItems = items
                }
            } catch {
                print("[HistoryViewModel] 加载固定板内容失败: \(error)")
            }
        }
    }

    func createPinboard(name: String, colorHex: String = "#378ADD") {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                _ = try self.databaseManager.createPinboard(name: name, colorHex: colorHex)
                self.loadPinboards()
            } catch {
                print("[HistoryViewModel] 创建固定板失败: \(error)")
            }
        }
    }

    /// 删除收藏栏（同时级联删除 pinboard_items 关联）
    func deletePinboard(_ pinboard: Pinboard) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.databaseManager.deletePinboard(pinboard)
                DispatchQueue.main.async {
                    // 如果当前正在查看被删除的 Pinboard，切回剪贴板
                    if self.selectedPinboardId == pinboard.id {
                        self.selectedPinboardId = nil
                        self.pinboardItems = []
                    }
                    self.loadPinboards()
                }
            } catch {
                print("[HistoryViewModel] 删除固定板失败: \(error)")
            }
        }
    }

    /// 重命名收藏栏
    func renamePinboard(_ pinboard: Pinboard, newName: String) {
        guard !newName.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.databaseManager.updatePinboard(pinboard, name: newName)
                self.loadPinboards()
            } catch {
                print("[HistoryViewModel] 重命名固定板失败: \(error)")
            }
        }
    }

    // MARK: - 收藏

    func loadFavorites() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let favs = try self.databaseManager.fetchAllPinboards() // 暂用 Pinboard
                DispatchQueue.main.async {
                    self.favorites = [] // TODO: 实现收藏查询
                }
            } catch {
                print("[HistoryViewModel] 加载收藏失败: \(error)")
            }
        }
    }

    // MARK: - CRUD 操作

    func togglePinned(_ item: ClipboardItem) {
        do {
            try databaseManager.togglePinned(item)
            loadHistory()
        } catch {
            print("[HistoryViewModel] 固定失败: \(error)")
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        do {
            try databaseManager.toggleFavorite(item)
            loadHistory()
        } catch {
            print("[HistoryViewModel] 收藏失败: \(error)")
        }
    }

    func delete(_ item: ClipboardItem) {
        do {
            try databaseManager.delete(item)
            // 刷新所有可能包含该条目的列表
            loadHistory()
            // 如果当前正在查看某个 Pinboard，也刷新它
            if let boardId = selectedPinboardId {
                if let board = pinboards.first(where: { $0.id == boardId }) {
                    loadPinboardItems(board)
                }
            }
            loadPinboards()
        } catch {
            print("[HistoryViewModel] 删除失败: \(error)")
        }
    }

    func markUsed(_ item: ClipboardItem) {
        do {
            try databaseManager.markUsed(item)
        } catch {
            print("[HistoryViewModel] 标记使用失败: \(error)")
        }
    }

    func clearHistory() {
        do {
            try databaseManager.clearHistory()
            loadHistory()
        } catch {
            print("[HistoryViewModel] 清空历史失败: \(error)")
        }
    }

    /// 将条目固定到指定 Pinboard
    func pinItemToBoard(_ item: ClipboardItem, board: Pinboard) {
        guard let itemId = item.id, let boardId = board.id else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.databaseManager.addToPinboard(pinboardId: boardId, clipboardItemId: itemId)
                DispatchQueue.main.async {
                    self.loadHistory()
                }
            } catch {
                print("[HistoryViewModel] 固定到 Pinboard 失败: \(error)")
            }
        }
    }
}

// MARK: - 辅助方法

extension HistoryViewModel {
    /// 按内容类型分组
    var groupedByType: [(ClipboardContentType, [ClipboardItem])] {
        Dictionary(grouping: filteredItems, by: { $0.contentType })
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    /// 统计信息
    var statistics: (total: Int, texts: Int, images: Int, files: Int) {
        let texts = filteredItems.filter { $0.contentType == .text || $0.contentType == .html || $0.contentType == .rtfd }.count
        let images = filteredItems.filter { $0.contentType == .image }.count
        let files = filteredItems.filter { $0.contentType == .fileURL }.count
        return (filteredItems.count, texts, images, files)
    }
}
