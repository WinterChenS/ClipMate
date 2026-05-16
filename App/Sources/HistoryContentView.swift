import AppKit
import SwiftUI
import QuickLook

// ============================================================
// HistoryPanel - Paste 风格悬浮面板
// 暗色毛玻璃背景、圆角、无边框、屏幕底部居中
// ============================================================
class HistoryPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 点击外部关闭用的全局鼠标监听器引用
    private var globalMouseMonitor: Any?

    init(contentView: HistoryContentView) {
        super.init(
            contentRect: .zero,
            styleMask: [
                .borderless,
                .utilityWindow,
            ],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.appearance = NSAppearance(named: .darkAqua)
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false // 手动管理隐藏逻辑

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ]

        // 深色毛玻璃
        let visualEffect = NSVisualEffectView()
        visualEffect.appearance = NSAppearance(named: .darkAqua)
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0
        // 顶部微妙的亮线
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        self.contentView = visualEffect

        // ESC 关闭
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.orderOut(nil)
                // 通知 AppDelegate 恢复 accessory 策略
                NSApp.setActivationPolicy(.accessory)
                return nil
            }
            return event
        }

        // 点击面板外部区域关闭
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            let screenLoc = NSEvent.mouseLocation
            let frame = self.frame
            if !frame.contains(screenLoc) {
                DispatchQueue.main.async {
                    self.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // 注意：globalMouseMonitor 的生命周期与 NSPanel 相同，无需手动移除
}

// ============================================================
// HistoryContentView - Paste 风格主内容视图
// 顶部搜索+Tab → 下方水平滚动卡片网格
// ============================================================
struct HistoryContentView: View {

    @ObservedObject var viewModel: HistoryViewModel
    var syncManager: ICloudDriveSyncManager?
    @State private var syncState: SyncState = .disabled
    @State private var selectedTab: HistoryTab = .history
    @State private var showingNewPinboardDialog = false
    @State private var newPinboardName = ""
    @FocusState private var isSearchFocused: Bool
    @State private var hasAccessibilityPermission: Bool = true
    @State private var pinboardToRename: Pinboard? = nil
    @State private var renameText: String = ""
    @State private var pinboardToDelete: Pinboard? = nil
    @State private var previewItem: ClipboardItem?
    @ObservedObject var updateChecker: UpdateChecker

    var onItemSelected: (ClipboardItem) -> Void
    var onPastePlainText: (ClipboardItem) -> Void
    var onClose: () -> Void

    init(
        databaseManager: DatabaseManager,
        syncManager: ICloudDriveSyncManager? = nil,
        updateChecker: UpdateChecker,
        onItemSelected: @escaping (ClipboardItem) -> Void,
        onPastePlainText: @escaping (ClipboardItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = HistoryViewModel(databaseManager: databaseManager)
        self.syncManager = syncManager
        self.updateChecker = updateChecker
        self.onItemSelected = onItemSelected
        self.onPastePlainText = onPastePlainText
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // ---- 顶部工具栏：搜索 + Tab ----
            topToolbar

            Divider()
                .background(Color.primary.opacity(0.08))

            // ---- 水平滚动卡片区域 ----
            PasteCardGrid(
                items: currentItems,
                pinboards: viewModel.pinboards,
                onItemSelected: onItemSelected,
                onItemAction: { item, action in
                    handleItemAction(item, action: action)
                }
            )
            .frame(maxHeight: .infinity)

            // ---- 底部状态栏 ----
            bottomBar
        }
        .frame(height: 400)
        .background(Color.clear)
        .onAppear {
            viewModel.loadHistory()
            viewModel.loadPinboards()
            hasAccessibilityPermission = AXIsProcessTrusted()
            // 初始化同步状态
            if let mgr = syncManager {
                syncState = mgr.syncState
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardDidChange)) { _ in
            viewModel.loadHistory()
            // 刷新权限状态（用户可能刚在系统设置中授权）
            hasAccessibilityPermission = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudKitSyncStateDidChange)) { notification in
            if let state = notification.userInfo?["syncState"] as? SyncState {
                syncState = state
            }
        }
        // Quick Look 预览
        .sheet(item: $previewItem) { item in
            ClipMatePreviewView(item: item)
                .frame(minWidth: 500, minHeight: 400)
        }
        // 更新提醒
        .alert("发现新版本", isPresented: $updateChecker.updateAvailable) {
            Button("下载更新") {
                updateChecker.openDownloadPage()
            }
            Button("不再提醒") {
                updateChecker.skipCurrentUpdate()
            }
            Button("稍后", role: .cancel) {}
        } message: {
            if let release = updateChecker.latestRelease {
                Text("ClipMate \(release.version) 已发布（当前 \(updateChecker.currentVersion)）")
            } else {
                Text("有新版本可用")
            }
        }
    }

    // MARK: - 当前 Tab 对应的数据

    private var currentItems: [ClipboardItem] {
        switch selectedTab {
        case .history:
            return viewModel.filteredItems
        case .pinboard:
            return viewModel.pinboardItems
        case .favorites:
            return viewModel.favorites
        }
    }

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        HStack(spacing: 0) {
            // ---- 左侧空间：将搜索框推到中间偏左 ----
            Spacer()
                .frame(minWidth: 16)

            // ---- 搜索框 ----
            searchField
                .frame(width: 180)

            // ---- 中间弹性空间（新增 Pinboard 时自动压缩） ----
            Spacer(minLength: 20)

            // ---- Tab 按钮（剪贴板 + Pinboards） ----
            tabBar

            // ---- 中间弹性空间（新增 Pinboard 时自动压缩） ----
            Spacer(minLength: 20)

            // ---- + 按钮：新建 Pinboard（中间靠右） ----
            Button {
                showingNewPinboardDialog = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建收藏栏")

            // ---- 右侧空间：将 + 按钮推到中间靠右 ----
            Spacer()
                .frame(minWidth: 16)

            // ---- ... 菜单按钮（最右侧，去掉下拉箭头） ----
            Menu {
                Button {
                    NotificationCenter.default.post(name: .openPreferences, object: nil)
                } label: {
                    Label("偏好设置...", systemImage: "gear")
                }

                Divider()

                Button {
                    updateChecker.forceCheck()
                } label: {
                    Label("检查更新...", systemImage: "arrow.down.circle")
                }

                Divider()

                Button {
                    HotKeyManager.openAccessibilitySettings()
                } label: {
                    Label("辅助功能权限...", systemImage: "lock.shield")
                }

                Divider()

                Button {
                    viewModel.clearHistory()
                } label: {
                    Label("清空剪贴板历史", systemImage: "trash")
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出 ClipMate", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("更多选项")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06))
        .sheet(isPresented: $showingNewPinboardDialog) {
            NewPinboardDialog(
                pinboardName: $newPinboardName,
                onCreate: {
                    if !newPinboardName.isEmpty {
                        viewModel.createPinboard(name: newPinboardName)
                        newPinboardName = ""
                    }
                    showingNewPinboardDialog = false
                },
                onCancel: {
                    newPinboardName = ""
                    showingNewPinboardDialog = false
                }
            )
        }
        // 删除收藏栏确认弹窗
        .alert("删除收藏栏", isPresented: Binding(
            get: { pinboardToDelete != nil },
            set: { if !$0 { pinboardToDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pinboardToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let board = pinboardToDelete {
                    viewModel.deletePinboard(board)
                    pinboardToDelete = nil
                }
            }
        } message: {
            if let board = pinboardToDelete {
                Text("确定要删除「\(board.name)」吗？栏内的条目不会被删除，只是取消关联。")
            }
        }
        // 重命名收藏栏弹窗
        .alert("重命名收藏栏", isPresented: Binding(
            get: { pinboardToRename != nil },
            set: { if !$0 { pinboardToRename = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {
                pinboardToRename = nil
            }
            Button("确定") {
                if let board = pinboardToRename, !renameText.isEmpty {
                    viewModel.renamePinboard(board, newName: renameText)
                }
                pinboardToRename = nil
            }
        } message: {
            Text("输入新的收藏栏名称")
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)

            TextField("搜索...", text: $viewModel.searchQuery)
                .font(.system(size: 12, weight: .regular))
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .foregroundColor(.primary)
                .onSubmit { viewModel.performSearch() }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - Tab 栏（剪贴板 + 动态 Pinboards）

    private var tabBar: some View {
        HStack(spacing: 0) {
            // 剪贴板 Tab
            tabButton(title: "剪贴板", icon: "doc.on.clipboard", isActive: selectedTab == .history) {
                selectedTab = .history
                viewModel.loadHistory()
            }

            // 动态 Pinboard Tabs
            ForEach(viewModel.pinboards.prefix(3)) { board in
                pinboardTabButton(board: board)
            }
        }
    }

    private func pinboardTabButton(board: Pinboard) -> some View {
        let isActive = selectedTab == .pinboard && viewModel.selectedPinboardId == board.id
        return Button {
            selectedTab = .pinboard
            viewModel.selectedPinboardId = board.id
            viewModel.loadPinboardItems(board)
        } label: {
            HStack(spacing: 5) {
                // 彩色圆点指示器
                Circle()
                    .fill(pinboardColor(for: board))
                    .frame(width: 6, height: 6)
                Text(board.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .foregroundColor(isActive ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = board.name
                pinboardToRename = board
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                pinboardToDelete = board
            } label: {
                Label("删除收藏栏", systemImage: "trash")
            }
        }
    }

    private func pinboardColor(for board: Pinboard) -> Color {
        return Color(hex: board.colorHex) ?? .gray
    }

    private func tabButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .foregroundColor(isActive ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部状态栏

    private var bottomBar: some View {
        HStack {
            if !hasAccessibilityPermission {
                // 权限警告（醒目提示）
                Button {
                    HotKeyManager.openAccessibilitySettings()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("需要辅助功能权限才能快速粘贴")
                            .font(.system(size: 10, weight: .medium))
                        Text("点击授权 →")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.yellow)
                }
                .buttonStyle(.plain)
                .help("点击打开系统设置，授予 ClipMate 辅助功能权限")
            } else {
                HStack(spacing: 6) {
                    Text("\(currentItems.count) 条")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))

                    // iCloud 同步状态指示
                    syncStatusIndicator
                }
            }

            Spacer()

            Text("⌘⇧V 打开 · ↑↓ 浏览 · ↵ 粘贴 · esc 关闭 · ⌘, 设置")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(Color(NSColor.quaternaryLabelColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06))
    }

    // MARK: - 同步状态指示器

    @ViewBuilder
    private var syncStatusIndicator: some View {
        switch syncState {
        case .disabled:
            EmptyView()
        case .idle:
            Image(systemName: "icloud.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .help("iCloud 已同步")
        case .pushing, .pulling, .syncing:
            Image(systemName: "icloud.fill")
                .font(.system(size: 10))
                .foregroundColor(.blue)
                .help("iCloud 同步中...")
        case .error:
            Image(systemName: "icloud.slash")
                .font(.system(size: 10))
                .foregroundColor(.red)
                .help("iCloud 同步失败")
        }
    }

    // MARK: - 操作处理

    private func handleItemAction(_ item: ClipboardItem, action: ItemAction) {
        switch action {
        case .pin:
            viewModel.togglePinned(item)
        case .favorite:
            viewModel.toggleFavorite(item)
        case .delete:
            viewModel.delete(item)
        case .copy:
            // 复制到剪贴板但不粘贴
            copyToClipboard(item)
        case .pastePlainText:
            // 以纯文本粘贴（通过 AppDelegate 统一处理隐藏+粘贴）
            onPastePlainText(item)
        case .edit:
            // TODO: 打开编辑对话框
            print("[HistoryContentView] 编辑条目: \(item.id ?? 0)")
        case .preview:
            previewItem = item
        case .share:
            // TODO: 打开分享面板
            shareItem(item)
        case .pinToBoard(let board):
            // 固定到指定 Pinboard
            viewModel.pinItemToBoard(item, board: board)
        }
    }

    /// 复制条目内容到系统剪贴板（不触发粘贴）
    private func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.contentType {
        case .text, .link:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .fileURL:
            if let urls = item.fileURLs {
                pasteboard.writeObjects(urls as [NSURL])
            }
        case .html:
            if let html = item.htmlContent {
                pasteboard.setString(html, forType: .html)
            }
        case .rtfd:
            if let data = item.rtfdData {
                pasteboard.setData(data, forType: .rtfd)
            }
        case .unknown:
            break
        }
    }

    /// 分享条目
    private func shareItem(_ item: ClipboardItem) {
        var itemsToShare: [Any] = []

        switch item.contentType {
        case .text:
            if let text = item.textContent {
                itemsToShare.append(text)
            }
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                itemsToShare.append(image)
            }
        case .fileURL:
            if let urls = item.fileURLs {
                itemsToShare.append(contentsOf: urls)
            }
        default:
            if let text = item.textContent {
                itemsToShare.append(text)
            }
        }

        if !itemsToShare.isEmpty {
            let picker = NSSharingServicePicker(items: itemsToShare)
            if let contentView = NSApp.keyWindow?.contentView {
                picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
            }
        }
    }

}

// MARK: - Tab 枚举

enum HistoryTab {
    case history
    case pinboard
    case favorites
}

// MARK: - 新建 Pinboard 对话框

struct NewPinboardDialog: View {
    @Binding var pinboardName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("新建收藏栏")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)

            TextField("名称", text: $pinboardName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("创建", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pinboardName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}

// MARK: - 预览视图

struct ClipMatePreviewView: View {
    let item: ClipboardItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text(previewTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Text(item.contentType.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(item.createdAt, style: .date)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // 内容区域
            ScrollView {
                previewContent
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var previewTitle: String {
        switch item.contentType {
        case .text, .link:
            return String(item.textContent?.prefix(50) ?? "预览")
        case .image:
            return "图片预览"
        case .fileURL:
            return "文件预览"
        case .html:
            return "富文本预览"
        case .rtfd:
            return "富文本预览"
        case .unknown:
            return "预览"
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.contentType {
        case .text:
            if let text = item.textContent {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .link:
            VStack(alignment: .leading, spacing: 8) {
                if let text = item.textContent {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let url = URL(string: item.textContent ?? "") {
                    Link("打开链接", destination: url)
                        .font(.system(size: 12))
                }
            }

        case .image:
            if let data = item.imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(8)
            }

        case .fileURL:
            if let urls = item.fileURLs {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(urls, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.blue)
                            Text(url.lastPathComponent)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: getFileSize(url), countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

        case .html:
            if let html = item.htmlContent {
                ScrollView {
                    Text(attributedStringFromHTML(html))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .rtfd:
            Text("富文本内容")
                .foregroundColor(.secondary)

        case .unknown:
            Text("无法预览此类型的内容")
                .foregroundColor(.secondary)
        }
    }

    private func getFileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    private func attributedStringFromHTML(_ html: String) -> AttributedString {
        guard let data = html.data(using: .utf8),
              let attrStr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else {
            return AttributedString(html)
        }
        return AttributedString(attrStr)
    }
}

// ClipboardContentType 的显示名称
extension ClipboardContentType {
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .fileURL: return "文件"
        case .link: return "链接"
        case .html: return "富文本"
        case .rtfd: return "富文本"
        case .unknown: return "未知"
        }
    }
}
