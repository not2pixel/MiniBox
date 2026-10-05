import SwiftUI

extension Color {
    /// Accent color của PlayCover (#60B6EB, Display P3).
    static let playBlue = Color(.displayP3, red: 0.376, green: 0.714, blue: 0.922)
}

enum Palette: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: .playBlue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .gray: .gray
        }
    }
}

extension Binding {
    /// Binding tới phần tử theo id. Khác `ForEach($array)` (theo chỉ số), binding này
    /// không bao giờ đọc ra ngoài mảng khi phần tử bị xoá/chèn trong lúc đang hiển thị.
    func element<E: Identifiable>(_ id: E.ID, fallback: E) -> Binding<E> where Value == [E] {
        Binding<E>(
            get: { wrappedValue.first { $0.id == id } ?? fallback },
            set: { new in
                if let i = wrappedValue.firstIndex(where: { $0.id == id }) { wrappedValue[i] = new }
            }
        )
    }
}

/// Icon tròn màu kiểu Reminders/Settings.
struct SymbolBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
    }
}

/// Nút dạng viên thuốc nhỏ cho thanh thông tin của note.
struct ChipStyle: ButtonStyle {
    var tint: Color = .secondary
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(active ? tint : .secondary)
            .background(
                Capsule().fill(active ? AnyShapeStyle(tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.6)))
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

struct CheckButton: View {
    let isOn: Bool
    var size: CGFloat = 18
    var tint: Color = .playBlue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Bỏ đánh dấu" : "Đánh dấu hoàn thành")
    }
}
