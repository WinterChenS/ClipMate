import SwiftUI
import AppKit

// ============================================================
// PinboardListView - 固定板管理视图
// ============================================================
struct PinboardListView: View {

    let pinboards: [Pinboard]
    let onSelectPinboard: (Pinboard) -> Void
    let onItemSelected: (ClipboardItem) -> Void

    @State private var showingNewPinboardSheet = false
    @State private var newPinboardName = ""

    var body: some View {
        VStack(spacing: 12) {
            // 固定板列表（网格布局）
            if pinboards.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(pinboards, id: \.id) { pinboard in
                            PinboardCard(pinboard: pinboard)
                                .onTapGesture {
                                    onSelectPinboard(pinboard)
                                }
                        }

                        // 新建固定板按钮
                        newPinboardButton
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $showingNewPinboardSheet) {
            NewPinboardSheet(isPresented: $showingNewPinboardSheet)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pin.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))

            Text("还没有固定板")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("将常用内容固定，方便快速访问")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))

            Button("创建固定板") {
                showingNewPinboardSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newPinboardButton: some View {
        Button {
            showingNewPinboardSheet = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)

                Text("新建固定板")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(width: 140, height: 100)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                    .foregroundColor(.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }
}

// ============================================================
// PinboardCard - 固定板卡片
// ============================================================
struct PinboardCard: View {
    let pinboard: Pinboard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 颜色标签
            Circle()
                .fill(Color(hex: pinboard.colorHex) ?? .blue)
                .frame(width: 12, height: 12)

            Text(pinboard.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()

            // 预览缩略图（占位）
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 32)
                }
            }
        }
        .padding(12)
        .frame(width: 160, height: 120)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: pinboard.colorHex) ?? .blue, lineWidth: 1.5)
                .opacity(0.3)
        )
    }
}

// ============================================================
// NewPinboardSheet - 新建固定板弹窗
// ============================================================
struct NewPinboardSheet: View {

    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var selectedColor = Color.blue

    private let colors: [Color] = [
        .blue, .red, .orange, .yellow, .green, .purple, .pink
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("新建固定板")
                .font(.system(size: 16, weight: .semibold))

            TextField("固定板名称", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Text("颜色：")
                    .font(.system(size: 13))
                ForEach(colors, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                        )
                        .shadow(color: selectedColor == color ? color.opacity(0.5) : .clear, radius: 4)
                        .onTapGesture {
                            selectedColor = color
                        }
                }
            }

            HStack(spacing: 12) {
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("创建") {
                    // TODO: 调用 ViewModel 创建固定板
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// ============================================================
// Color 扩展：支持十六进制
// ============================================================
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
