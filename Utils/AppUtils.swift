import Foundation
import AppKit

// ============================================================
// AppUtils - 应用工具函数
// ============================================================

/// 应用配置常量
enum AppConfig {
    /// 应用名称
    static let appName = "ClipMate"
    /// Bundle Identifier
    static let bundleIdentifier = "com.clipmate.app"
    /// 数据库文件名
    static let databaseName = "ClipMate.sqlite"
    /// 默认快捷键
    static let defaultShortcut = (key: "V", modifiers: "⌘⇧")
}

/// 应用状态
enum AppState {
    case running
    case hidden
    case terminated
}

// MARK: - 文件路径工具

extension FileManager {
    /// 获取 Application Support 目录
    static var applicationSupportDirectory: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths.first!.appendingPathComponent(AppConfig.appName, isDirectory: true)
    }

    /// 确保目录存在
    static func ensureDirectoryExists(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}

// MARK: - 数据压缩工具

struct ImageCompressor {

    /// JPEG 压缩
    static func compress(
        imageData: Data,
        quality: CGFloat = 0.7,
        maxSizeKB: Int = 500
    ) -> Data? {
        guard let image = NSImage(data: imageData) else { return nil }

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        var compressed = bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )

        // 如果压缩后仍然太大，降低质量重试
        var currentQuality = quality
        while let data = compressed, data.count > maxSizeKB * 1024, currentQuality > 0.1 {
            currentQuality -= 0.1
            compressed = bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: currentQuality]
            )
        }

        return compressed
    }

    /// PNG 压缩
    static func compressPNG(imageData: Data) -> Data? {
        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

// MARK: - 字符串工具

extension String {
    /// 截断到指定长度
    func truncated(to length: Int, trailing: String = "...") -> String {
        if self.count <= length {
            return self
        }
        return String(self.prefix(length)) + trailing
    }

    /// 去除首尾空白和换行
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否为有效搜索词
    var isValidSearchTerm: Bool {
        !trimmingCharacters(in: .whitespaces).isEmpty && count >= 1
    }
}
