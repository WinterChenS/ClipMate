import SwiftUI

// ============================================================
// SearchBarView - 搜索栏组件
// 支持实时搜索、内容类型快速过滤
// ============================================================
struct SearchBarView: View {

    @Binding var text: String
    var onSearch: () -> Void

    @State private var isFocused = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // 搜索框
            HStack(spacing: 8) {
                // 搜索图标
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                // 文本输入框
                TextField("搜索剪贴板历史...", text: $text)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        onSearch()
                    }
                    .onChange(of: text) { _, _ in
                        onSearch()
                    }

                // 清除按钮
                if !text.isEmpty {
                    Button {
                        text = ""
                        onSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1)
            )

            // 内容类型快捷过滤
            HStack(spacing: 6) {
                FilterChip(text: "文本", icon: "doc.text", isSelected: false) { }
                FilterChip(text: "图片", icon: "photo", isSelected: false) { }
                FilterChip(text: "文件", icon: "folder", isSelected: false) { }
                Spacer()
            }
        }
        .onAppear {
            // 监听全局搜索焦点通知
            NotificationCenter.default.addObserver(
                forName: .focusSearchField,
                object: nil,
                queue: .main
            ) { _ in
                isTextFieldFocused = true
            }
        }
    }
}

// ============================================================
// FilterChip - 快捷过滤标签
// ============================================================
struct FilterChip: View {
    let text: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(text)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ============================================================
// ItemAction - 条目操作枚举
// ============================================================
enum ItemAction {
    case pin
    case favorite
    case delete
    case copy
}
