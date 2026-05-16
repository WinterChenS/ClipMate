import AppKit
import SwiftUI

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
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false // 手动管理隐藏逻辑

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ]

        // 深色毛玻璃
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
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

    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// ============================================================
// HistoryContentView - 主内容视图
// Paste 风格：顶部搜索 → 侧边栏 Tab → 右侧垂直列表
// ============================================================
struct HistoryContentView: View {

    @ObservedObject var viewModel: HistoryViewModel
    @State private var selectedTab: HistoryTab = .history
    @FocusState private var isSearchFocused: Bool

    var onItemSelected: (ClipboardItem) -> Void
    var onClose: () -> Void

    init(
        databaseManager: DatabaseManager,
        onItemSelected: @escaping (ClipboardItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = HistoryViewModel(databaseManager: databaseManager)
        self.onItemSelected = onItemSelected
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // ---- 搜索栏 ----
            searchBar

            Divider()
                .background(Color.white.opacity(0.08))

            // ---- 主内容区：左侧 Tab + 右侧列表 ----
            HStack(spacing: 0) {
                // 左侧 Tab 侧栏
                sidebar
                    .frame(width: 52)

                Divider()
                    .frame(width: 1)
                    .background(Color.white.opacity(0.06))

                // 右侧内容
                contentArea
            }
            .frame(maxHeight: .infinity)

            // ---- 底部状态栏 ----
            bottomBar
        }
        .frame(width: 720, height: 420)
        .background(Color.clear)
        .onAppear {
            viewModel.loadHistory()
            viewModel.loadPinboards()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardDidChange)) { _ in
            viewModel.loadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isSearchFocused = true
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color.white.opacity(0.4))

            TextField("搜索...", text: $viewModel.searchQuery)
                .font(.system(size: 13, weight: .regular))
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .foregroundColor(.primary)
                .onSubmit { viewModel.performSearch() }
                .onChange(of: viewModel.searchQuery) { _, _ in
                    viewModel.performSearch()
                }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSearchFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 左侧 Tab 侧栏

    private var sidebar: some View {
        VStack(spacing: 4) {
            sidebarButton(
                icon: "clock",
                tooltip: "历史记录",
                isActive: selectedTab == .history
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = .history
                    viewModel.loadHistory()
                }
            }

            sidebarButton(
                icon: "pin",
                tooltip: "固定板",
                isActive: selectedTab == .pinboard
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = .pinboard
                    viewModel.loadPinboards()
                }
            }

            sidebarButton(
                icon: "star",
                tooltip: "收藏",
                isActive: selectedTab == .favorites
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = .favorites
                    viewModel.loadFavorites()
                }
            }

            Spacer()

            // 设置按钮
            sidebarButton(
                icon: "gearshape",
                tooltip: "偏好设置",
                isActive: false
            ) {
                NotificationCenter.default.post(name: .openPreferences, object: nil)
            }
        }
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    private func sidebarButton(icon: String, tooltip: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                    .frame(width: 36, height: 32)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color.accentColor : Color.white.opacity(0.45))
                    .frame(width: 36, height: 32)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .history:
            PasteClipList(
                items: viewModel.filteredItems,
                onItemSelected: onItemSelected,
                onItemAction: { item, action in
                    handleItemAction(item, action: action)
                }
            )
        case .pinboard:
            PasteClipList(
                items: viewModel.pinboardItems,
                onItemSelected: onItemSelected,
                onItemAction: { item, action in
                    handleItemAction(item, action: action)
                }
            )
        case .favorites:
            PasteClipList(
                items: viewModel.favorites,
                onItemSelected: onItemSelected,
                onItemAction: { item, action in
                    handleItemAction(item, action: action)
                }
            )
        }
    }

    // MARK: - 底部状态栏

    private var bottomBar: some View {
        HStack {
            Text("\(viewModel.filteredItems.count) 条")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Color.white.opacity(0.3))

            Spacer()

            Text("⌘⇧V  打开  ·  ↑↓  浏览  ·  ↵  粘贴  ·  esc  关闭")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(Color.white.opacity(0.2))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.02))
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
            onItemSelected(item)
        }
    }
}

// MARK: - Tab 枚举

enum HistoryTab {
    case history
    case pinboard
    case favorites
}
