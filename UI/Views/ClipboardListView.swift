import SwiftUI
import AppKit

// ============================================================
// ClipboardListView - 横向滑动卡片列表
// Paste 标志性的横向滚动画廊式展示
// ============================================================
struct ClipboardListView: View {

    let items: [ClipboardItem]
    let onItemSelected: (ClipboardItem) -> Void
    let onItemAction: (ClipboardItem, ItemAction) -> Void

    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @State private var contextMenuItem: ClipboardItem? = nil

    var body: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipboardCard(
                            item: item,
                            isSelected: index == selectedIndex,
                            isHovered: hoveredIndex == index
                        )
                        .frame(width: cardWidth(for: item))
                        .onHover { isHovered in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hoveredIndex = isHovered ? index : nil
                            }
                        }
                        .onTapGesture {
                            selectedIndex = index
                            onItemSelected(item)
                        }
                        .contextMenu {
                            itemContextMenu(for: item)
                        }
                        .onAppear {
                            // 自动滚动到可见区域
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            .background(Color.clear)
            .overlay(alignment: .bottom) {
                // 键盘导航指示器
                if hoveredIndex != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.circle")
                            .font(.system(size: 14))
                        Text("← → 切换")
                            .font(.system(size: 11))
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 14))
                        Text("Enter 粘贴")
                            .font(.system(size: 11))
                            .padding(.leading, 8)
                    }
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text("还没有剪贴板历史")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("复制内容后会自动出现在这里")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func itemContextMenu(for item: ClipboardItem) -> some View {
        Button {
            onItemSelected(item)
        } label: {
            Label("粘贴", systemImage: "doc.on.clipboard")
        }

        Button {
            onItemAction(item, .pin)
        } label: {
            Label(item.isPinned ? "取消固定" : "固定到顶部", systemImage: item.isPinned ? "pin.slash" : "pin")
        }

        Button {
            onItemAction(item, .favorite)
        } label: {
            Label(item.isFavorite ? "取消收藏" : "添加收藏", systemImage: item.isFavorite ? "star.slash" : "star")
        }

        Divider()

        Button(role: .destructive) {
            onItemAction(item, .delete)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 根据内容类型确定卡片宽度

    private func cardWidth(for item: ClipboardItem) -> CGFloat {
        switch item.contentType {
        case .text, .html, .rtfd:
            return 280 // 文本卡片宽一些
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                let ratio = CGFloat(w) / CGFloat(max(h, 1))
                let height: CGFloat = 120
                return min(max(height * ratio, 120), 300)
            }
            return 180
        case .fileURL:
            return 220
        case .unknown:
            return 180
        }
    }
}

// ============================================================
// ClipboardCard - 单个剪贴板卡片
// 支持文本、图片、文件等不同内容类型的展示
// ============================================================
struct ClipboardCard: View {

    let item: ClipboardItem
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ---- 内容预览 ----
            cardContent
                .frame(maxHeight: 160)

            // ---- 底部信息栏 ----
            HStack(spacing: 6) {
                // 来源应用图标
                if let appName = item.sourceAppName {
                    HStack(spacing: 4) {
                        Image(systemName: sourceAppIcon(for: appName))
                            .font(.system(size: 9))
                        Text(appName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                // 时间
                Text(item.timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                // 固定标记
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }

                // 收藏标记
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.03))
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.3) : Color.clear), lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // MARK: - 内容区域

    @ViewBuilder
    private var cardContent: some View {
        switch item.contentType {
        case .text, .html, .rtfd:
            textPreview
        case .image:
            imagePreview
        case .fileURL:
            filePreview
        case .unknown:
            unknownPreview
        }
    }

    private var textPreview: some View {
        ScrollView {
            Text(item.previewText)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.primary.opacity(0.02))
        .cornerRadius(10, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    private var imagePreview: some View {
        Group {
            if let imageData = item.imageData,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    Color.gray.opacity(0.1)
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
            }
        }
        .cornerRadius(10, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    private var filePreview: some View {
        HStack(spacing: 8) {
            if let urls = item.fileURLs {
                let icon = workspaceIcon(for: urls.first?.pathExtension ?? "")
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let urls = item.fileURLs {
                    ForEach(urls.prefix(3), id: \.absoluteString) { url in
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    if urls.count > 3 {
                        Text("+ \(urls.count - 3) 个文件")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(10, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    private var unknownPreview: some View {
        ZStack {
            Color.gray.opacity(0.1)
            VStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                Text("未知内容")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .cornerRadius(10, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    // MARK: - 背景

    private var cardBackground: some View {
        Group {
            if item.contentType == .image {
                Color.clear
            } else {
                Color.primary.opacity(0.04)
            }
        }
    }

    // MARK: - 辅助方法

    private func sourceAppIcon(for appName: String) -> String {
        let name = appName.lowercased()
        if name.contains("chrome") || name.contains("safari") || name.contains("browser") {
            return "globe"
        } else if name.contains("xcode") || name.contains("code") {
            return "chevron.left.forwardslash.chevron.right"
        } else if name.contains("terminal") {
            return "terminal"
        } else if name.contains("slack") || name.contains("wechat") || name.contains("qq") {
            return "bubble.left.and.bubble.right"
        } else {
            return "app"
        }
    }

    private func workspaceIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift", "m", "h", "c", "cpp", "py", "js", "ts":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "rar":
            return "doc.zipper"
        default:
            return "doc"
        }
    }
}

// MARK: - 圆角扩展

extension View {
    func cornerRadius(_ radius: CGFloat, corners: CACornerMask) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        )
        return Path(path.cgPath)
    }
}
