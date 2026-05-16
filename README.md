# PasteClone - macOS 剪贴板管理器

高保真复刻 macOS Paste 应用，使用纯原生 Swift + AppKit/SwiftUI 开发。

> ✅ **无需 Xcode！** 使用 `swift build` 直接编译，支持 macOS ARM64。

## 功能特性

| 模块 | 功能 | 状态 |
|------|------|------|
| 📋 剪贴板监听 | 实时监听，支持文本/图片/文件/富文本 | ✅ |
| 📜 历史面板 | 横向滑动卡片列表，高保真 Paste UI | ✅ |
| 🔍 全文搜索 | FTS5 全文索引，300ms 防抖实时搜索 | ✅ |
| 📌 Pinboard | 固定板分组管理，颜色标签支持 | ✅ |
| ⭐ 收藏夹 | 收藏重要剪贴板条目 | ✅ |
| ⌨️ 全局快捷键 | ⌘⇧V 打开面板 | ✅ |
| 🚫 应用排除 | 排除密码管理器等敏感应用 | ✅ |
| ⚙️ 偏好设置 | 快捷键/存储/排除应用配置 | ✅ |

## 编译运行

### 方式一：直接构建（无需 Xcode）

```bash
cd PasteClone

# Debug 模式（需要 Xcode）
swift build

# Release 模式（无需 Xcode，6MB 二进制）
swift build -c release

# 运行
.build/arm64-apple-macosx/release/PasteClone
```

### 方式二：Xcode（需要 Xcode）

```bash
GVM_ROOT="" /opt/homebrew/bin/xcodegen generate  # 生成 .xcodeproj
open PasteClone.xcodeproj
# ⌘R 运行
```

## 依赖说明

| 库 | 版本 | 用途 |
|----|------|------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29 | SQLite ORM + FTS5 全文搜索 |

## 技术要点

- **剪贴板监听**: `NSPasteboard.changeCount` 轮询方案（0.5s 间隔）
- **UI**: `NSPanel` HUD 磨砂透明背景 + SwiftUI 横向卡片画廊
- **数据**: GRDB + FTS5 全文索引，存储于 `~/Library/Application Support/PasteClone/`
- **全局快捷键**: `CGEventTap` 实现（需在系统设置授权辅助功能）
- **Swift 6**: 使用 `@MainActor` 确保并发安全

## macOS 版本要求

- **最低**: macOS 14.0 (Sonoma)
- **推荐**: macOS 15.0 (Sequoia)

## 授权提示

首次运行时需要在 **系统设置 > 隐私与安全性 > 辅助功能** 中授权，否则全局快捷键无法工作。

## License

MIT License
