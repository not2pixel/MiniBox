// Icon MiniBox (phong cách Apple): khối hộp isometric, mặt trên là lưới 2×2 ô màu — các "mô-đun" trong hộp.
// Nền gradient xanh như logo cũ. Xuất AppIcon.icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let previewPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let u = s / 1024

    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }
    func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: P(pts[0].0, pts[0].1))
        pts.dropFirst().forEach { p.line(to: P($0.0, $0.1)) }
        p.close()
        p.lineJoinStyle = .round
        return p
    }
    func shadow(_ blur: CGFloat, _ dy: CGFloat, _ color: NSColor, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = color
        sh.shadowBlurRadius = blur * u
        sh.shadowOffset = NSSize(width: 0, height: -dy * u)
        sh.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Nền: lưới icon macOS (824/1024, bo 185) + gradient xanh cũ + ánh sáng nhẹ trên cùng
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u),
                          xRadius: 185 * u, yRadius: 185 * u)
    shadow(20, 10, NSColor.black.withAlphaComponent(0.25)) { NSColor.black.setFill(); bg.fill() }
    NSGradient(starting: rgb(0.48, 0.78, 0.97), ending: rgb(0.18, 0.48, 0.85))!.draw(in: bg, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 60 * u, y: 560 * u, width: 904 * u, height: 520 * u)),
              relativeCenterPosition: NSPoint(x: 0, y: 0.4))
    NSGraphicsContext.restoreGraphicsState()

    // Khối hộp isometric — đỉnh các mặt
    let T: (CGFloat, CGFloat) = (512, 790), R: (CGFloat, CGFloat) = (764, 645)
    let B: (CGFloat, CGFloat) = (512, 500), L: (CGFloat, CGFloat) = (260, 645)
    let depth: CGFloat = 270
    let Bd = (B.0, B.1 - depth), Ld = (L.0, L.1 - depth), Rd = (R.0, R.1 - depth)

    // Bóng đổ mềm dưới hộp
    shadow(60, 30, rgb(0.03, 0.15, 0.40, 0.45)) {
        rgb(0.1, 0.3, 0.6, 0.01).setFill()
        poly([L, B, R, Rd, Bd, Ld]).fill()
    }

    // Mặt trái & phải
    NSGradient(starting: rgb(0.97, 0.99, 1.0), ending: rgb(0.84, 0.91, 0.99))!
        .draw(in: poly([L, B, Bd, Ld]), angle: -90)
    NSGradient(starting: rgb(0.80, 0.88, 0.98), ending: rgb(0.66, 0.79, 0.95))!
        .draw(in: poly([B, R, Rd, Bd]), angle: -90)

    // Mặt trên (miệng hộp)
    NSGradient(starting: rgb(1, 1, 1), ending: rgb(0.93, 0.96, 1.0))!.draw(in: poly([L, T, R, B]), angle: -90)

    // Lưới 2×2 ô màu trên mặt trên: vẽ trong hệ toạ độ "vuông" rồi chiếu lên hình thoi
    cg.saveGState()
    let t = CGAffineTransform(a: (T.0 - L.0) * u, b: (T.1 - L.1) * u,
                              c: (B.0 - L.0) * u, d: (B.1 - L.1) * u,
                              tx: L.0 * u, ty: L.1 * u)
    cg.concatenate(t)
    let tiles: [(CGFloat, CGFloat, NSColor, NSColor)] = [
        (0, 0, rgb(1.00, 0.62, 0.20), rgb(1.00, 0.45, 0.18)),   // ghi chú — cam
        (1, 0, rgb(1.00, 0.40, 0.62), rgb(0.93, 0.23, 0.50)),   // trò chơi — hồng
        (0, 1, rgb(0.30, 0.86, 0.50), rgb(0.12, 0.70, 0.40)),   // nhạc — xanh lá
        (1, 1, rgb(0.66, 0.48, 1.00), rgb(0.50, 0.33, 0.95)),   // học tập — tím
    ]
    let pad: CGFloat = 0.075, gap: CGFloat = 0.05
    let size = (1 - pad * 2 - gap) / 2
    for (i, j, c1, c2) in tiles {
        let rect = NSRect(x: pad + i * (size + gap), y: pad + j * (size + gap), width: size, height: size)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 0.07, yRadius: 0.07)
        NSGradient(starting: c1, ending: c2)!.draw(in: tile, angle: 45)
        // điểm sáng nhỏ trên mỗi ô
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + size * 0.16, y: rect.minY + size * 0.16,
                                         width: size * 0.34, height: size * 0.12),
                     xRadius: 0.03, yRadius: 0.03).fill()
    }
    cg.restoreGState()

    // Viền sáng các cạnh trên cùng cho cảm giác khối
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let rim = poly([L, T, R, B])
    rim.lineWidth = 6 * u
    rim.stroke()
    NSColor.white.withAlphaComponent(0.55).setStroke()
    let edge = NSBezierPath()
    edge.move(to: P(B.0, B.1)); edge.line(to: P(Bd.0, Bd.1))
    edge.lineWidth = 4 * u
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
if let previewPath {
    try! render(512).write(to: URL(fileURLWithPath: previewPath))
    try! render(64).write(to: URL(fileURLWithPath: previewPath.replacingOccurrences(of: ".png", with: "-64.png")))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
print("Icon → \(out)")
