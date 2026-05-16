import SwiftUI
import AppKit
import ServiceManagement

// ============================================================
// PreferencesView - 偏好设置窗口
// 包含：通用设置、快捷键、排除应用、存储、关于
// 所有功能均已连接到 DatabaseManager 实际生效
// ============================================================
struct PreferencesView: View {

    // MARK: - 通用设置
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("maxHistoryDays") private var maxHistoryDays = 30
    @AppStorage("maxHistoryCount") private var maxHistoryCount = 1000
    @AppStorage("showNotification") private var showNotification = true
    @AppStorage("autoCleanup") private var autoCleanup = true

    @State private var selectedSection: PreferencesSection = .general

    // MARK: - 排除应用数据
    @State private var exclusions: [AppExclusion] = []
    @State private var isLoadingExclusions = false

    // MARK: - 存储信息
    @State private var dbSizeMB: String = "计算中..."
    @State private var historyCount: Int = 0
    @State private var pinboardCount: Int = 0

    // MARK: - 依赖
    let databaseManager: DatabaseManager

    var body: some View {
        NavigationSplitView {
            // 侧边栏
            List(PreferencesSection.allCases, id: \.self, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160)
        } detail: {
            // 详情区域
            detailView
                .frame(minWidth: 320)
        }
        .frame(width: 560, height: 420)
        .onAppear {
            loadExclusions()
            loadStorageInfo()
        }
    }

    // MARK: - 详情视图

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .general:
            generalSettings
        case .shortcuts:
            shortcutSettings
        case .exclusions:
            exclusionSettings
        case .storage:
            storageSettings
        case .about:
            aboutView
        }
    }

    // MARK: - 通用设置

    private var generalSettings: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                Toggle("在 Dock 中显示图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        toggleDockIcon(newValue)
                    }
            } header: {
                Text("启动")
            }

            Section {
                Toggle("复制成功时显示通知", isOn: $showNotification)
            } header: {
                Text("通知")
            }

            Section {
                HStack {
                    Text("最大历史记录数")
                    Spacer()
                    Stepper("\(maxHistoryCount) 条", value: $maxHistoryCount, in: 100...10000, step: 100)
                        .frame(width: 180)
                }

                HStack {
                    Text("历史保留天数")
                    Spacer()
                    Stepper("\(maxHistoryDays) 天", value: $maxHistoryDays, in: 1...365)
                }

                Toggle("自动清理旧记录", isOn: $autoCleanup)
                    .onChange(of: autoCleanup) { _, newValue in
                        if newValue {
                            cleanupOldRecords()
                        }
                    }
            } header: {
                Text("历史记录")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - 快捷键设置

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("快捷键设置")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("打开历史面板")
                    Spacer()
                    Text("⌘⇧V")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                }

                Divider()

                HStack {
                    Text("搜索")
                    Spacer()
                    Text("⌘F")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                }

                Divider()

                HStack {
                    Text("偏好设置")
                    Spacer()
                    Text("⌘,")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                }
            }
            .padding()
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            Text("快捷键当前为固定配置，后续版本将支持自定义")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - 排除应用设置

    private var exclusionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("排除的应用")
                    .font(.headline)

                Spacer()

                Button("添加应用...") {
                    openAppPicker()
                }
                .buttonStyle(.bordered)
            }

            Text("以下应用的剪贴板内容不会被记录（如密码管理器）")
                .font(.caption)
                .foregroundColor(.secondary)

            if isLoadingExclusions {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if exclusions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("没有排除规则")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("点击「添加应用...」排除密码管理器等应用")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(exclusions) { exclusion in
                        ExclusionRow(
                            exclusion: exclusion,
                            databaseManager: databaseManager,
                            onToggle: {
                                toggleExclusion(exclusion)
                            },
                            onRemove: {
                                removeExclusion(exclusion)
                            }
                        )
                    }
                    .onDelete(perform: deleteExclusions)
                }
                .listStyle(.inset)
                .frame(maxHeight: 200)
            }
        }
        .padding()
    }

    // MARK: - 存储设置

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("存储设置")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("数据库大小")
                    Spacer()
                    Text(dbSizeMB)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("历史记录数")
                    Spacer()
                    Text("\(historyCount) 条")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("收藏栏数量")
                    Spacer()
                    Text("\(pinboardCount) 个")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            Spacer()

            HStack(spacing: 12) {
                Button("导出数据...") {
                    exportData()
                }

                Button("清空所有数据", role: .destructive) {
                    clearAllData()
                }
            }
        }
        .padding()
    }

    // MARK: - 关于

    private var aboutView: some View {
        VStack(spacing: 16) {
            Spacer()

            // 使用 app icon
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
            }

            Text("ClipMate")
                .font(.title2.bold())

            Text("版本 1.0.0")
                .foregroundColor(.secondary)

            Text("一个高保真的 macOS 剪贴板管理器")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text("Made with Swift + AppKit")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 功能实现

    // --- 开机自启动 ---
    private func setLaunchAtLogin(_ enabled: Bool) {
        // 使用 SMAppService (macOS 13+) 管理开机启动
        // 如果系统版本不支持，提示用户手动添加
        if #available(macOS 13.0, *) {
            do {
                let service = SMAppService.mainApp
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                print("[Preferences] 设置开机启动失败: \(error)")
                launchAtLogin = false
            }
        } else {
            // fallback: 使用 AppleScript 添加 Login Item
            let script: String
            if enabled {
                script = """
                tell application "System Events"
                    make login item at end with properties {name:"ClipMate", path:"\(Bundle.main.bundlePath)", hidden:false}
                end tell
                """
            } else {
                script = """
                tell application "System Events"
                    delete login item "ClipMate"
                end tell
                """
            }
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[Preferences] 设置开机启动失败: \(error)")
                launchAtLogin = false
            }
        }
    }

    // --- Dock 图标切换 ---
    private func toggleDockIcon(_ show: Bool) {
        if show {
            // 设置 applicationIconImage
            if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let icon = NSImage(contentsOfFile: iconPath) {
                NSApp.applicationIconImage = icon
            }
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // --- 自动清理 ---
    private func cleanupOldRecords() {
        do {
            try databaseManager.cleanupOldItems(keepCount: maxHistoryCount)
        } catch {
            print("[Preferences] 自动清理失败: \(error)")
        }
    }

    // --- 排除应用 ---
    private func loadExclusions() {
        isLoadingExclusions = true
        let db = databaseManager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try db.fetchAllExclusions()
                DispatchQueue.main.async {
                    exclusions = list
                    isLoadingExclusions = false
                }
            } catch {
                print("[Preferences] 加载排除规则失败: \(error)")
                DispatchQueue.main.async {
                    isLoadingExclusions = false
                }
            }
        }
    }

    private func openAppPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择一个要排除的应用"

        if panel.runModal() == .OK, let url = panel.url {
            let appName = url.deletingPathExtension().lastPathComponent
            let bundleId = Bundle(url: url)?.bundleIdentifier ?? ""

            if !bundleId.isEmpty {
                do {
                    try databaseManager.addExclusion(bundleIdentifier: bundleId, appName: appName)
                    loadExclusions()
                    // 通知 ClipboardMonitor 刷新排除规则
                    NotificationCenter.default.post(name: .exclusionRulesDidChange, object: nil)
                } catch {
                    print("[Preferences] 添加排除规则失败: \(error)")
                }
            }
        }
    }

    private func toggleExclusion(_ exclusion: AppExclusion) {
        do {
            try databaseManager.toggleExclusion(exclusion)
            loadExclusions()
            NotificationCenter.default.post(name: .exclusionRulesDidChange, object: nil)
        } catch {
            print("[Preferences] 切换排除规则失败: \(error)")
        }
    }

    private func removeExclusion(_ exclusion: AppExclusion) {
        do {
            try databaseManager.removeExclusion(exclusion)
            loadExclusions()
            NotificationCenter.default.post(name: .exclusionRulesDidChange, object: nil)
        } catch {
            print("[Preferences] 移除排除规则失败: \(error)")
        }
    }

    private func deleteExclusions(at offsets: IndexSet) {
        for index in offsets {
            let exclusion = exclusions[index]
            try? databaseManager.removeExclusion(exclusion)
        }
        loadExclusions()
        NotificationCenter.default.post(name: .exclusionRulesDidChange, object: nil)
    }

    // --- 存储信息 ---
    private func loadStorageInfo() {
        let db = databaseManager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 获取历史记录数
                let items = try db.fetchHistory(limit: 100000)
                let boards = try db.fetchAllPinboards()

                // 获取数据库文件大小
                let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!
                let dbPath = appSupport
                    .appendingPathComponent("ClipMate", isDirectory: true)
                    .appendingPathComponent("ClipMate.sqlite")
                let attrs = try FileManager.default.attributesOfItem(atPath: dbPath.path)
                let fileSize = attrs[.size] as? Int64 ?? 0
                let sizeMB = String(format: "%.1f MB", Double(fileSize) / (1024 * 1024))

                DispatchQueue.main.async {
                    historyCount = items.count
                    pinboardCount = boards.count
                    dbSizeMB = sizeMB
                }
            } catch {
                DispatchQueue.main.async {
                    dbSizeMB = "获取失败"
                }
            }
        }
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ClipMate_Export_\(Date().timeIntervalSince1970).json"
        panel.message = "导出剪贴板数据"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let items = try databaseManager.fetchHistory(limit: 100000)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(items)
                try data.write(to: url)
                print("[Preferences] 数据已导出到: \(url.path)")
            } catch {
                print("[Preferences] 导出失败: \(error)")
            }
        }
    }

    private func clearAllData() {
        let alert = NSAlert()
        alert.messageText = "确定要清空所有数据？"
        alert.informativeText = "此操作将删除所有剪贴板历史、收藏栏和排除规则，且无法恢复。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空所有数据")

        if alert.runModal() == .alertSecondButtonReturn {
            do {
                try databaseManager.clearHistory()
                loadStorageInfo()
            } catch {
                print("[Preferences] 清空数据失败: \(error)")
            }
        }
    }
}

// ============================================================
// ExclusionRow - 排除应用行（可交互：切换启用/删除）
// ============================================================
struct ExclusionRow: View {
    let exclusion: AppExclusion
    let databaseManager: DatabaseManager
    let onToggle: () -> Void
    let onRemove: () -> Void

    @State private var enabled: Bool

    init(exclusion: AppExclusion, databaseManager: DatabaseManager, onToggle: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.exclusion = exclusion
        self.databaseManager = databaseManager
        self.onToggle = onToggle
        self.onRemove = onRemove
        self._enabled = State(initialValue: exclusion.isEnabled)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exclusion.appName)
                    .font(.system(size: 13))
                Text(exclusion.bundleIdentifier)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $enabled)
                .labelsHidden()
                .onChange(of: enabled) { _, newValue in
                    onToggle()
                }

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("移除")
        }
    }
}

// ============================================================
// PreferencesSection - 设置分区
// ============================================================
enum PreferencesSection: String, CaseIterable {
    case general = "通用"
    case shortcuts = "快捷键"
    case exclusions = "排除应用"
    case storage = "存储"
    case about = "关于"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .exclusions: return "xmark.app"
        case .storage: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}
