import Foundation
import AppKit
import GRDB

// ============================================================
// ClipboardItem - 剪贴板条目数据模型
// 支持 GRDB 持久化和多种内容类型
// ============================================================

/// 内容类型枚举
enum ClipboardContentType: String, Codable, DatabaseValueConvertible {
    case text       // 普通文本
    case image      // 图片
    case fileURL    // 文件/文件夹路径
    case html       // HTML 内容
    case rtfd       // 富文本（带格式）
    case unknown    // 未知类型
}

/// Pinboard（固定板）关联模型
struct Pinboard: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var name: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "pinboards"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// PinboardItem 关联表
struct PinboardItem: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var pinboardId: Int64
    var clipboardItemId: Int64

    static let databaseTableName = "pinboard_items"
}

/// 应用排除规则
struct AppExclusion: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var bundleIdentifier: String
    var appName: String
    var isEnabled: Bool
    var createdAt: Date

    static let databaseTableName = "app_exclusions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 剪贴板条目模型
struct ClipboardItem: Identifiable, Codable, FetchableRecord, PersistableRecord {

    // MARK: - 数据库字段

    var id: Int64?
    var uuid: String          // 全局唯一标识
    var contentType: ClipboardContentType
    var textContent: String?          // 纯文本内容
    var htmlContent: String?          // HTML 内容
    var imageData: Data?              // 图片数据（压缩存储）
    var imageWidth: Int?              // 图片宽度
    var imageHeight: Int?            // 图片高度
    var fileURLStrings: String?      // 文件路径数组（JSON 字符串）
    var rtfdData: Data?              // RTFD 富文本数据
    var sourceAppBundleId: String?   // 来源应用 Bundle ID
    var sourceAppName: String?       // 来源应用名称
    var charCount: Int               // 字符数
    var isPinned: Bool               // 是否固定
    var isFavorite: Bool             // 是否收藏
    var searchText: String           // 搜索用的合并文本
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?            // 最后使用时间
    var useCount: Int                // 使用次数

    static let databaseTableName = "clipboard_items"

    // 自动生成 ID
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - 初始化

    init(
        id: Int64? = nil,
        contentType: ClipboardContentType,
        textContent: String? = nil,
        htmlContent: String? = nil,
        imageData: Data? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        fileURLs: [URL]? = nil,
        rtfdData: Data? = nil,
        sourceApp: NSRunningApplication? = nil
    ) {
        self.id = id
        self.uuid = UUID().uuidString
        self.contentType = contentType
        self.textContent = textContent
        self.htmlContent = htmlContent
        self.imageData = imageData
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileURLStrings = fileURLs.map { $0.map { $0.path }.joined(separator: "|||") }
        self.rtfdData = rtfdData
        self.sourceAppBundleId = sourceApp?.bundleIdentifier
        self.sourceAppName = sourceApp?.localizedName
        self.charCount = textContent?.count ?? 0
        self.isPinned = false
        self.isFavorite = false
        self.searchText = Self.buildSearchText(
            text: textContent,
            sourceApp: sourceApp?.localizedName
        )
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastUsedAt = nil
        self.useCount = 0
    }

    // MARK: - 辅助方法

    /// 构建搜索文本（用于全文搜索）
    private static func buildSearchText(text: String?, sourceApp: String?) -> String {
        var parts: [String] = []
        if let t = text { parts.append(t) }
        if let app = sourceApp { parts.append(app) }
        return parts.joined(separator: " ")
    }

    /// 获取文件 URL 数组
    var fileURLs: [URL]? {
        guard let str = fileURLStrings else { return nil }
        return str.split(separator: "|||").map { URL(fileURLWithPath: String($0)) }
    }

    /// 显示用的摘要文本
    var displayText: String {
        switch contentType {
        case .text:
            return textContent ?? ""
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "🖼️ 图片 \(w)×\(h)"
            }
            return "🖼️ 图片"
        case .fileURL:
            if let urls = fileURLs {
                return "📁 " + urls.map { $0.lastPathComponent }.joined(separator: ", ")
            }
            return "📁 文件"
        case .html:
            return "🌐 HTML"
        case .rtfd:
            return "📝 富文本"
        case .unknown:
            return "❓ 未知内容"
        }
    }

    /// 简短预览（用于列表展示）
    var previewText: String {
        switch contentType {
        case .text, .html, .rtfd:
            let text = textContent ?? htmlContent ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
            if singleLine.count > 120 {
                return String(singleLine.prefix(120)) + "..."
            }
            return singleLine
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "\(w) × \(h) px"
            }
            return "图片"
        case .fileURL:
            if let urls = fileURLs {
                return urls.map { $0.lastPathComponent }.joined(separator: ", ")
            }
            return "文件"
        case .unknown:
            return "未知"
        }
    }

    /// 时间友好的显示格式
    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    // MARK: - 从 NSPasteboard 创建 ClipboardItem

    /// 从系统剪贴板读取并创建 ClipboardItem
    static func from(pasteboard: NSPasteboard, sourceApp: NSRunningApplication?) -> ClipboardItem? {
        // 1. 优先检测图片
        if let imageTypes = pasteboard.types?.filter({ [.tiff, .png].contains($0) }), !imageTypes.isEmpty {
            if let data = pasteboard.data(forType: imageTypes[0]),
               let image = NSImage(data: data) {
                let size = image.size
                // 压缩图片数据（超过 500KB 则压缩）
                var imageData = data
                if data.count > 500 * 1024 {
                    if let tiffData = image.tiffRepresentation,
                       let compressed = NSBitmapImageRep(data: tiffData)?
                           .representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                        imageData = compressed
                    }
                }
                return ClipboardItem(
                    contentType: .image,
                    imageData: imageData,
                    imageWidth: Int(size.width),
                    imageHeight: Int(size.height),
                    sourceApp: sourceApp
                )
            }
        }

        // 2. 检测 RTFD 富文本
        if pasteboard.types?.contains(.rtfd) == true,
           let rtfdData = pasteboard.data(forType: .rtfd) {
            return ClipboardItem(
                contentType: .rtfd,
                rtfdData: rtfdData,
                sourceApp: sourceApp
            )
        }

        // 3. 检测 HTML
        if pasteboard.types?.contains(.html) == true,
           let html = pasteboard.string(forType: .html) {
            let text = pasteboard.string(forType: .string)
            return ClipboardItem(
                contentType: .html,
                textContent: text,
                htmlContent: html,
                sourceApp: sourceApp
            )
        }

        // 4. 检测文件
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return ClipboardItem(
                contentType: .fileURL,
                fileURLs: urls,
                sourceApp: sourceApp
            )
        }

        // 5. 普通文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return ClipboardItem(
                contentType: .text,
                textContent: text,
                sourceApp: sourceApp
            )
        }

        return nil
    }
}

// MARK: - NSRunningApplication 扩展：获取前台应用

extension NSRunningApplication {
    /// 获取当前前台（前台窗口所在）的应用
    static var currentFrontApp: NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }
}

// MARK: - NSNotification.Name 扩展

extension Notification.Name {
    static let focusSearchField = Notification.Name("focusSearchField")
    static let clipboardDidChange = Notification.Name("clipboardDidChange")
    static let historyDidUpdate = Notification.Name("historyDidUpdate")
}
