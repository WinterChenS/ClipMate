import SwiftUI
import AppKit

// ============================================================
// PreferencesView - 偏好设置窗口
// 包含：通用设置、历史设置、快捷键、排除应用等
// ============================================================
struct PreferencesView: View {

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("maxHistoryDays") private var maxHistoryDays = 30
    @AppStorage("maxHistoryCount") private var maxHistoryCount = 1000
    @AppStorage("autoCleanup") private var autoCleanup = true

    @State private var selectedSection: PreferencesSection = .general

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
        .frame(width: 520, height: 400)
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
                Toggle("在 Dock 中显示图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        // 切换 LSUIElement
                        setLSUIElement(!newValue)
                    }
            } header: {
                Text("启动")
            }

            Section {
                HStack {
                    Text("显示历史记录数")
                    Spacer()
                    Stepper("\(maxHistoryCount) 条", value: $maxHistoryCount, in: 100...10000, step: 100)
                        .frame(width: 180)
                }

                HStack {
                    Text("历史保留天数")
                    Spacer()
                    Stepper("\(maxHistoryDays) 天", value: $maxHistoryDays, in: 1...365)
                        .frame(width: 180)
                }

                Toggle("自动清理旧记录", isOn: $autoCleanup)
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
                    ShortcutRecorder(enabled: .constant(true))
                }

                Divider()

                HStack {
                    Text("清除历史")
                    Spacer()
                    Text("⌘⇧Delete")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                Divider()

                HStack {
                    Text("搜索")
                    Spacer()
                    Text("⌘F")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .padding()
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            Text("提示：点击录制区域后，按下你想要的快捷键组合")
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

            List {
                ExclusionRow(
                    appName: "1Password",
                    bundleId: "com.1password.1password",
                    isEnabled: true
                )
                ExclusionRow(
                    appName: "Safari",
                    bundleId: "com.apple.Safari",
                    isEnabled: false
                )
            }
            .listStyle(.inset)
            .frame(maxHeight: 200)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
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
                    Text("12.4 MB")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("历史记录数")
                    Spacer()
                    Text("342 条")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("固定板数量")
                    Spacer()
                    Text("3 个")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            Spacer()

            HStack {
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

            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

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

    // MARK: - 辅助方法

    private func setLSUIElement(_ hidden: Bool) {
        // 动态修改 Info.plist 或使用 SMLoginItemSetEnabled
        // 这里简化处理，实际需要通过 ServiceManagement 框架
        print("[Preferences] LSUIElement = \(hidden)")
    }

    private func openAppPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择一个要排除的应用"

        if panel.runModal() == .OK, let url = panel.url {
            print("选择的应用: \(url.path)")
        }
    }

    private func exportData() {
        print("[Preferences] 导出数据")
    }

    private func clearAllData() {
        print("[Preferences] 清空所有数据")
    }
}

// ============================================================
// ExclusionRow - 排除应用行
// ============================================================
struct ExclusionRow: View {
    let appName: String
    let bundleId: String
    let isEnabled: Bool

    @State private var enabled: Bool

    init(appName: String, bundleId: String, isEnabled: Bool) {
        self.appName = appName
        self.bundleId = bundleId
        self.isEnabled = isEnabled
        self._enabled = State(initialValue: isEnabled)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(appName)
                    .font(.system(size: 13))
                Text(bundleId)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $enabled)
                .labelsHidden()
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

// ============================================================
// ShortcutRecorder - 快捷键录制组件（纯 SwiftUI，无第三方依赖）
// ============================================================
struct ShortcutRecorder: View {
    @Binding var enabled: Bool

    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "circle.dashed" : "keyboard")
                    .font(.system(size: 12))
                Text(isRecording ? "点击按下快捷键..." : "⌘⇧V")
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isRecording ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06))
            .foregroundColor(isRecording ? .orange : .secondary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
