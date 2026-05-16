import SwiftUI
import AppKit

// ============================================================
// AppIconCache - 应用图标缓存 & 主色提取
// ============================================================
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var iconCache: [String: NSImage] = [:]
    private var colorCache: [String: NSColor] = [:]

    func icon(for bundleId: String) -> NSImage? {
        if let cached = iconCache[bundleId] {
            return cached
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        iconCache[bundleId] = icon
        return icon
    }

    /// 从应用图标中提取主色调
    func dominantColor(for bundleId: String) -> NSColor? {
        if let cached = colorCache[bundleId] {
            return cached
        }
        guard let icon = self.icon(for: bundleId) else {
            return nil
        }
        let color = extractDominantColor(from: icon)
        if let color = color {
            colorCache[bundleId] = color
        }
        return color
    }

    /// 提取图标主色：将图标缩小采样后统计像素频率，返回最常见的显著颜色
    private func extractDominantColor(from image: NSImage) -> NSColor? {
        // 缩小到 16x16 采样，加速计算
        let size = NSSize(width: 16, height: 16)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: Int(size.width) * 4,
            bitsPerPixel: 32
        ) else { return nil }

        let ctx = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // 收集所有非透明像素，按色相桶分组
        var hueBuckets: [Int: (r: Double, g: Double, b: Double, count: Int)] = [:]
        let totalPixels = Int(size.width * size.height)

        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let pixel = bitmap.colorAt(x: x, y: y)
                guard let pixel = pixel else { continue }
                let alpha = pixel.alphaComponent
                if alpha < 0.3 { continue } // 跳过透明像素

                let r = pixel.redComponent
                let g = pixel.greenComponent
                let b = pixel.blueComponent
                let brightness = (r + g + b) / 3.0

                // 跳过接近纯黑/纯白（这些通常是图标边缘/背景，不是品牌色）
                if brightness < 0.1 || brightness > 0.95 { continue }

                // 按色相分桶（36 个桶，每 10° 一桶）
                let hue: Int
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let delta = maxC - minC

                if delta < 0.1 {
                    // 低饱和度 → 归为灰色桶
                    hue = 360
                } else {
                    var h: Double
                    if maxC == r {
                        h = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
                    } else if maxC == g {
                        h = (b - r) / delta + 2.0
                    } else {
                        h = (r - g) / delta + 4.0
                    }
                    h *= 60.0
                    if h < 0 { h += 360.0 }
                    hue = Int(h / 10.0) // 0-35
                }

                let bucket = hueBuckets[hue] ?? (r: 0, g: 0, b: 0, count: 0)
                hueBuckets[hue] = (
                    r: bucket.r + r,
                    g: bucket.g + g,
                    b: bucket.b + b,
                    count: bucket.count + 1
                )
            }
        }

        // 找到像素最多的色相桶
        guard let bestBucket = hueBuckets.max(by: { $0.value.count < $1.value.count }),
              bestBucket.value.count > totalPixels / 8 // 至少占 12.5% 才算有意义的品牌色
        else { return nil }

        let avg = bestBucket.value
        let total = Double(avg.count)
        let r = avg.r / total
        let g = avg.g / total
        let b = avg.b / total

        // 稍微增强饱和度，让颜色更鲜明（作为背景色更好看）
        let maxC = max(r, g, b)
        let boost: Double = 1.15
        let nr = min(1.0, r + (r - (r + g + b) / 3.0) * (boost - 1.0))
        let ng = min(1.0, g + (g - (r + g + b) / 3.0) * (boost - 1.0))
        let nb = min(1.0, b + (b - (r + g + b) / 3.0) * (boost - 1.0))

        return NSColor(calibratedRed: nr, green: ng, blue: nb, alpha: 1.0)
    }

    private init() {}
}

// ============================================================
// AppIconHeaderView - Paste 风格卡片顶部（精确复刻）
// 高色块 + 右上角大图标(局部裁剪) + 左上角类型/时间
// ============================================================
struct AppIconHeaderView: View {
    let item: ClipboardItem
    let typeLabel: String

    @State private var appIcon: NSImage?
    @State private var appColor: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 背景：从应用图标提取的主色调
            Rectangle().fill(resolvedColor)

            // 右上角：大图标，只显示右半部分（溢出裁剪效果）
            // 图标底部与色块底部齐平，顶部自然溢出 2px
            if let icon = appIcon {
                HStack {
                    Spacer()
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .offset(x: 14, y: 0)
                }
                .clipped()
            }

            // 左上角：类型标签 + 时间
            VStack(alignment: .leading, spacing: 1) {
                Text(typeLabel)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(item.timeAgo)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: 72)
        .onAppear {
            loadAppIconAndColor()
        }
    }

    /// 解析后使用的颜色：优先用提取的图标主色，否则回退到内容类型色
    private var resolvedColor: Color {
        appColor ?? fallbackTypeColor
    }

    private var fallbackTypeColor: Color {
        switch item.contentType {
        case .text:
            return Color(NSColor(red: 0.25, green: 0.7, blue: 0.5, alpha: 1.0))
        case .link:
            return Color(NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0))
        case .image:
            return Color(NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0))
        case .fileURL:
            return Color(NSColor(red: 0.5, green: 0.5, blue: 0.9, alpha: 1.0))
        case .html:
            return Color(NSColor(red: 0.9, green: 0.45, blue: 0.2, alpha: 1.0))
        case .rtfd:
            return Color(NSColor(red: 0.7, green: 0.5, blue: 0.2, alpha: 1.0))
        case .unknown:
            return .gray
        }
    }

    private func loadAppIconAndColor() {
        guard let bundleId = item.sourceAppBundleId else { return }
        if let icon = AppIconCache.shared.icon(for: bundleId) {
            self.appIcon = icon
        }
        if let color = AppIconCache.shared.dominantColor(for: bundleId) {
            self.appColor = Color(color)
        }
    }
}

// ============================================================
// PasteCardGrid - Paste 风格的水平滚动卡片网格
// ============================================================
struct PasteCardGrid: View {

    let items: [ClipboardItem]
    let pinboards: [Pinboard]
    let onItemSelected: (ClipboardItem) -> Void
    let onItemAction: (ClipboardItem, ItemAction) -> Void

    @State private var hoveredId: Int64? = nil
    @State private var selectedId: Int64? = nil

    var body: some View {
        if items.isEmpty {
            PasteCardEmptyView()
        } else {
            cardGrid
        }
    }

    private var cardGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(items) { item in
                    PasteCard(
                        item: item,
                        isHovered: hoveredId == item.id,
                        isSelected: selectedId == item.id
                    )
                    .onHover { isHovered in
                        hoveredId = isHovered ? item.id : nil
                    }
                    .onTapGesture(count: 2) {
                        selectedId = item.id
                        onItemSelected(item)
                    }
                    .onTapGesture(count: 1) {
                        selectedId = item.id
                    }
                    .contextMenu {
                        PasteCardContextMenu(
                            item: item,
                            onPaste: { onItemSelected(item) },
                            onPastePlainText: { onItemAction(item, .pastePlainText) },
                            onCopy: { onItemAction(item, .copy) },
                            onEdit: { onItemAction(item, .edit) },
                            onDelete: { onItemAction(item, .delete) },
                            onPin: { onItemAction(item, .pin) },
                            onPreview: { onItemAction(item, .preview) },
                            onShare: { onItemAction(item, .share) },
                            pinboards: pinboards,
                            onPinToBoard: { board in
                                onItemAction(item, .pinToBoard(board))
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ============================================================
// PasteCard - 单个 Paste 风格卡片
// ============================================================
struct PasteCard: View {

    let item: ClipboardItem
    let isHovered: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ---- 顶部：来源应用图标模糊背景 + 类型标签 + 时间 ----
            AppIconHeaderView(item: item, typeLabel: typeLabel)

            // ---- 内容预览区 ----
            contentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // ---- 底部信息栏 ----
            bottomBar
        }
        .frame(width: 220, height: 300)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor.opacity(0.8) : (isHovered ? Color.primary.opacity(0.15) : Color.clear), lineWidth: isSelected ? 2.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.2), radius: isHovered ? 6 : 2, x: 0, y: isHovered ? 4 : 1)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
    }

    // MARK: - 内容预览

    @ViewBuilder
    private var contentPreview: some View {
        switch item.contentType {
        case .text, .html, .rtfd:
            textContentPreview
        case .link:
            linkContentPreview
        case .image:
            imageContentPreview
        case .fileURL:
            fileContentPreview
        case .unknown:
            Text("未知内容")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(10)
        }
    }

    private var textContentPreview: some View {
        Text(item.previewText)
            .font(.system(size: 12.5, weight: .regular))
            .foregroundColor(.primary)
            .lineLimit(10)
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var linkContentPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let urlStr = item.textContent, let domain = urlStr.extractDomain() {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0)))
                    Text(domain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Text(urlStr)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var imageContentPreview: some View {
        Group {
            if let data = item.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(0)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("图片")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var fileContentPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let urls = item.fileURLs {
                ForEach(urls.prefix(4), id: \.absoluteString) { url in
                    HStack(spacing: 5) {
                        Image(systemName: fileIcon(for: url.pathExtension))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                if urls.count > 4 {
                    Text("+\(urls.count - 4) 个文件")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 底部信息栏

    private var bottomBar: some View {
        HStack {
            // 字符数/尺寸信息
            Text(bottomBarText)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06))
    }

    private var bottomBarText: String {
        switch item.contentType {
        case .link:
            return item.textContent?.extractDomain() ?? ""
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                return "\(w) × \(h)"
            }
            return ""
        case .fileURL:
            if let urls = item.fileURLs {
                return urls.first?.lastPathComponent ?? ""
            }
            return ""
        default:
            return "\(item.charCount) 个字符"
        }
    }

    // MARK: - 类型相关

    private var typeLabel: String {
        switch item.contentType {
        case .text: return "文本"
        case .link: return "链接"
        case .image: return "图片"
        case .fileURL: return "文件"
        case .html: return "HTML"
        case .rtfd: return "富文本"
        case .unknown: return "未知"
        }
    }

    // MARK: - 辅助方法

    private func appColor(for name: String) -> Color {
        let n = name.lowercased()
        if n.contains("xcode") { return .blue }
        if n.contains("chrome") || n.contains("arc") { return .orange }
        if n.contains("safari") { return .blue }
        if n.contains("terminal") || n.contains("iterm") { return .black }
        if n.contains("finder") { return .blue }
        if n.contains("notes") { return .yellow }
        if n.contains("slack") { return .purple }
        if n.contains("wechat") || n.contains("微信") { return .green }
        if n.contains("code") || n.contains("cursor") { return .blue }
        if n.contains("figma") { return .purple }
        return .gray.opacity(0.6)
    }

    private func fileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift", "m", "h", "c", "cpp", "py", "js", "ts", "rs": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "rar", "gz": return "doc.zipper"
        case "mp4", "mov", "avi": return "film"
        case "mp3", "wav", "flac": return "music.note"
        default: return "doc"
        }
    }
}

// MARK: - String 扩展：URL 检测

extension String {
    /// 检测字符串是否看起来像 URL
    var looksLikeURL: Bool {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 简单的 URL 检测：以 http://、https://、ftp:// 开头，或包含域名模式
        let urlPattern = "^(https?|ftp)://[^\\s]+$"
        let domainPattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?)*\\.[a-zA-Z]{2,}(/[^\\s]*)?$"

        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }

        if let regex = try? NSRegularExpression(pattern: domainPattern, options: .caseInsensitive) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    /// 从 URL 字符串中提取域名
    func extractDomain() -> String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            // 尝试添加 https:// 前缀
            guard let urlWithScheme = URL(string: "https://" + trimmed) else { return nil }
            return urlWithScheme.host
        }
        return url.host
    }
}

// ============================================================
// PasteCardEmptyView - 空状态
// ============================================================
struct PasteCardEmptyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundColor(.secondary.opacity(0.3))

            Text("暂无剪贴板历史")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary.opacity(0.5))

            Text("复制内容后会自动出现在这里")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ============================================================
// PasteCardContextMenu - Paste 风格右键菜单
// ============================================================
struct PasteCardContextMenu: View {
    let item: ClipboardItem
    let onPaste: () -> Void
    let onPastePlainText: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onPreview: () -> Void
    let onShare: () -> Void
    let pinboards: [Pinboard]
    let onPinToBoard: (Pinboard) -> Void

    var body: some View {
        // ---- 粘贴操作 ----
        Button(action: onPaste) {
            Label("粘贴到当前应用", systemImage: "arrow.down.doc")
        }

        if item.contentType != .text {
            Button(action: onPastePlainText) {
                Label("以纯文本粘贴", systemImage: "text.alignleft")
            }
        }

        Button(action: onCopy) {
            Label("复制", systemImage: "doc.on.doc")
        }

        Divider()

        // ---- 编辑操作 ----
        Button(action: onEdit) {
            Label("编辑", systemImage: "pencil")
        }

        Button(action: onDelete) {
            Label("删除", systemImage: "trash")
        }
        .foregroundColor(.red)

        Divider()

        // ---- 固定（带子菜单） ----
        Menu {
            Button(action: onPin) {
                Label(
                    item.isPinned ? "取消固定" : "固定到顶部",
                    systemImage: item.isPinned ? "pin.slash" : "pin"
                )
            }

            if !pinboards.isEmpty {
                Divider()
                ForEach(pinboards.prefix(5)) { board in
                    Button {
                        onPinToBoard(board)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(pinboardColor(for: board))
                                .frame(width: 6, height: 6)
                            Text(board.name)
                        }
                    }
                }
            }

            Divider()
            Button(action: {}) {
                Label("创建 Pinboard...", systemImage: "plus")
            }
        } label: {
            Label("固定", systemImage: "pin")
        }

        // ---- 预览 ----
        Button(action: onPreview) {
            Label("预览", systemImage: "eye")
        }

        // ---- 分享 ----
        Button(action: onShare) {
            Label("分享", systemImage: "square.and.arrow.up")
        }
    }

    private func pinboardColor(for board: Pinboard) -> Color {
        return Color(hex: board.colorHex) ?? .gray
    }
}

// ============================================================
// ItemAction 枚举
// ============================================================
enum ItemAction {
    case pin
    case favorite
    case delete
    case copy
    case pastePlainText
    case edit
    case preview
    case share
    case pinToBoard(Pinboard)
}
