import SwiftUI

// ============================================================
// SearchBarView - 搜索栏组件（备用，主要搜索已集成到 HistoryContentView）
// ============================================================
struct SearchBarView: View {

    @Binding var text: String
    var onSearch: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            TextField("搜索...", text: $text)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .foregroundColor(.primary)
                .onSubmit { onSearch() }
                .onChange(of: text) { _, _ in onSearch() }

            if !text.isEmpty {
                Button {
                    text = ""
                    onSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTextFieldFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isTextFieldFocused = true
        }
    }
}
