import CoreImage
import SwiftUI

// MARK: - Bảng màu & chuyển động kiểu Spotify

/// Bảng màu Spotify (tối) và bản tương ứng cho giao diện sáng.
enum SP {
    private static func dyn(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    /// Nền ngoài cùng (giữa các khung).
    static let base = dyn(hex(0x000000), hex(0xE9E9EB))
    /// Khung nội dung.
    static let panel = dyn(hex(0x121212), hex(0xFFFFFF))
    /// Thẻ, ô tìm kiếm, nút tròn.
    static let elevated = dyn(hex(0x1F1F1F), hex(0xF0F0F2))
    static let elevatedHover = dyn(hex(0x2A2A2A), hex(0xE4E4E7))
    static let text = dyn(hex(0xFFFFFF), hex(0x000000))
    static let subtext = dyn(hex(0xB3B3B3), hex(0x6A6A6A))
    static let divider = dyn(hex(0xFFFFFF, 0.1), hex(0x000000, 0.08))
    /// Thanh phát dưới cùng.
    static let bar = dyn(hex(0x000000), hex(0xFFFFFF))
}

enum Spotify {
    static let green = Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)       // #1ED760
    static let greenHover = Color(red: 0x3B / 255, green: 0xE4 / 255, blue: 0x77 / 255)  // #3BE477
    static let likedTop = Color(red: 0x45 / 255, green: 0x0A / 255, blue: 0xF5 / 255)    // #450AF5
    static let likedBottom = Color(red: 0xC4 / 255, green: 0xEF / 255, blue: 0xD9 / 255) // #C4EFD9
    static let liked = Color(red: 0x50 / 255, green: 0x38 / 255, blue: 0xA0 / 255)       // nền đầu trang Liked Songs

    /// Nền khi rê chuột: trắng 10% ở giao diện tối, đen 5% ở giao diện sáng.
    static let hover = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.05)
    })
    static let selected = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.08)
    })

    static let quick = Animation.easeOut(duration: 0.15)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

/// Co nhẹ khi bấm.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Spotify.quick, value: configuration.isPressed)
    }
}

/// Nút Play tròn xanh lá: rê chuột phóng to 1.04 + sáng hơn, bấm co lại.
struct SpotifyPlayButton: View {
    let isPlaying: Bool
    var size: CGFloat = 56
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.black)
                .offset(x: isPlaying ? 0 : size * 0.03)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(hovering ? Spotify.greenHover : Spotify.green, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 8)
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
    }
}

/// Nút điều khiển nhỏ: xám → rõ khi rê chuột; đang bật thì xanh + chấm nhỏ bên dưới.
struct SpotifyIconButton: View {
    let symbol: String
    var active = false
    var size: CGFloat = 15
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(hovering ? Spotify.greenHover : Spotify.green)
                                 : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .scaleEffect(hovering ? 1.04 : 1)
                .frame(width: 32, height: 32)
                .overlay(alignment: .bottom) {
                    if active {
                        Circle().fill(Spotify.green).frame(width: 4, height: 4).offset(y: -1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
        .animation(Spotify.quick, value: active)
        .help(help)
    }
}

/// Thanh tiến độ / âm lượng đúng kiểu Spotify:
/// cao 4pt bo tròn, rãnh #4D4D4D, phần đã chạy trắng; rê chuột (hoặc kéo) thì phần đã chạy chuyển #1DB954
/// và hiện núm tròn trắng 12pt ở đầu. Vùng bắt chuột cao hơn thanh để dễ trúng.
struct SpotifyBar: View {
    let value: Double
    var onChanged: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void
    @State private var hovering = false
    @State private var drag: Double?

    static let track = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0x4D / 255, alpha: 1) : NSColor(white: 0xD4 / 255, alpha: 1)
    })
    static let fill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : NSColor(white: 0.1, alpha: 1)
    })
    static let active = Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255) // #1DB954

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let v = min(max(drag ?? value, 0), 1)
            let on = hovering || drag != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Self.track)
                Capsule()
                    .fill(on ? Self.active : Self.fill)
                    .frame(width: max(w * v, v > 0 ? 4 : 0))
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .offset(x: min(max(w * v - 6, -6), w - 6))
                    .opacity(on ? 1 : 0)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let p = min(max(g.location.x / w, 0), 1)
                        drag = p
                        onChanged(p)
                    }
                    .onEnded { g in
                        onCommit(min(max(g.location.x / w, 0), 1))
                        drag = nil
                    }
            )
        }
        .frame(height: 12)
        .onHover { hovering = $0 }
    }
}

/// Cột sóng âm xanh nhảy theo nhạc (bài đang phát).
struct EqualizerBars: View {
    var animating = true
    var color: Color = Spotify.green

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let speed = [5.1, 7.3, 4.2, 6.4][i]
                    let h = animating ? 0.3 + 0.7 * abs(sin(t * speed + Double(i) * 1.3)) : 0.3
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 2.5, height: 14 * h)
                }
            }
            .frame(width: 16, height: 14, alignment: .bottom)
        }
    }
}

/// Ảnh bìa "Tất cả bài hát" kiểu Liked Songs.
struct LikedCover: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size > 60 ? 6 : 4, style: .continuous)
            .fill(LinearGradient(colors: [Spotify.likedTop, Spotify.likedBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "heart.fill").font(.system(size: size * 0.36)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

// MARK: - Màu chủ đạo của ảnh bìa

enum ArtColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    @MainActor private static var cache: [String: Color] = [:]

    /// Màu trung bình của ảnh, chỉnh lại cho đủ đậm để chữ trắng/đen đều đọc được (giống nền lời bài hát Spotify).
    @MainActor static func color(for track: Track?) -> Color? {
        guard let t = track, let key = t.artwork else { return nil }
        if let c = cache[key] { return c }
        guard let img = MusicLibrary.shared.artwork(t),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let color = Color(hue: Double(h), saturation: Double(s < 0.12 ? s : min(max(s, 0.45), 0.8)),
                          brightness: Double(min(max(b, 0.38), 0.55)))
        cache[key] = color
        return color
    }
}
