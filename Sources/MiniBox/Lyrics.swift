import SwiftUI

// MARK: - Lời bài hát từ LRCLIB (lrclib.net — miễn phí, không cần key)

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
}

private struct LyricsCache: Codable {
    var synced: String?
    var plain: String?
    var name: String?
    var artist: String?
    var instrumental = false
}

@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    enum State: Equatable {
        case idle, loading, notFound, instrumental
        case failed(String)
        case found(lines: [LyricLine], synced: Bool, match: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var trackID: UUID?

    private let dir: URL
    private var task: Task<Void, Never>?

    private init() {
        dir = MusicLibrary.shared.dir.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func cacheURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    /// Tên tìm kiếm đã làm sạch (bỏ "official", "lyric video", [..], (..)…).
    nonisolated static func searchTerms(for t: Track) -> (title: String, artist: String) {
        var title = t.title
        var artist = t.artist
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"【[^】]*】"#, #"\|.*$"#] {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for junk in ["official music video", "official video", "official audio", "official visualizer", "lyric visualizer",
                     "lyrics video", "lyric video", "lyrics", "visualizer", "mv", "audio", "m/v"] {
            title = title.replacingOccurrences(of: junk, with: "", options: [.caseInsensitive])
        }
        // "Ca sĩ - Tên bài" → tách ra
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2 {
            artist = parts[0]
            title = parts.dropFirst().joined(separator: " - ")
        }
        artist = artist.replacingOccurrences(of: #"\s*-\s*Topic$|VEVO$|Official$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return (title.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-–—·").union(.whitespaces)), artist.trimmed)
    }

    func load(_ track: Track, query: String? = nil) {
        trackID = track.id
        task?.cancel()

        if query == nil, let data = try? Data(contentsOf: cacheURL(track.id)),
           let cached = try? JSONDecoder().decode(LyricsCache.self, from: data) {
            apply(cached)
            return
        }

        state = .loading
        let terms = Self.searchTerms(for: track)
        let duration = track.duration
        let id = track.id
        task = Task {
            do {
                let result = try await Self.fetch(title: terms.title, artist: terms.artist, duration: duration, query: query)
                guard !Task.isCancelled, trackID == id else { return }
                let cache = result ?? LyricsCache()
                if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL(id)) }
                apply(cache)
            } catch {
                guard !Task.isCancelled, trackID == id else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ c: LyricsCache) {
        let match = [c.name, c.artist].compactMap { $0 }.joined(separator: " — ")
        if c.instrumental { state = .instrumental }
        else if let s = c.synced, !s.isEmpty { state = .found(lines: Self.parseLRC(s), synced: true, match: match) }
        else if let p = c.plain, !p.isEmpty {
            let lines = p.components(separatedBy: "\n").enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
            state = .found(lines: lines, synced: false, match: match)
        } else { state = .notFound }
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let tag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [(Double, String)] = []
        for raw in lrc.components(separatedBy: "\n") {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmed
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append((min * 60 + sec, text))
            }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    // MARK: Network

    private struct Item: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    nonisolated private static func request(_ path: String, _ items: [URLQueryItem]) async throws -> Data? {
        var c = URLComponents(string: "https://lrclib.net/api/\(path)")!
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.setValue("MiniBox/1.0 (macOS note app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw MusicError.message("LRCLIB lỗi \(http.statusCode).") }
        return data
    }

    nonisolated private static func fetch(title: String, artist: String, duration: Double, query: String?) async throws -> LyricsCache? {
        func cache(_ i: Item) -> LyricsCache {
            LyricsCache(synced: i.syncedLyrics, plain: i.plainLyrics, name: i.trackName, artist: i.artistName,
                        instrumental: i.instrumental ?? false)
        }
        // 1. Khớp chính xác theo tên + nghệ sĩ + thời lượng
        if query == nil, !title.isEmpty, !artist.isEmpty,
           let data = try await request("get", [
               .init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
               .init(name: "duration", value: String(Int(duration.rounded()))),
           ]), let item = try? JSONDecoder().decode(Item.self, from: data) {
            return cache(item)
        }
        // 2. Tìm kiếm, ưu tiên bản có lời chạy theo nhạc và thời lượng gần nhất
        let q = query ?? "\(artist) \(title)".trimmed
        guard let data = try await request("search", [.init(name: "q", value: q)]),
              let items = try? JSONDecoder().decode([Item].self, from: data), !items.isEmpty else { return nil }
        let best = items.min { a, b in
            func score(_ i: Item) -> Double {
                let diff = duration > 0 ? abs((i.duration ?? 0) - duration) : 0
                return diff + (i.syncedLyrics?.isEmpty == false ? 0 : 30) + (i.instrumental == true ? 100 : 0)
            }
            return score(a) < score(b)
        }
        return best.map(cache)
    }
}

// MARK: - View

struct LyricsPanel: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var store = LyricsStore.shared
    @State private var searching = false
    @State private var query = ""
    @State private var hoverLine: Int?

    /// Màu chữ cố định trên nền màu (giống Spotify, không đổi theo sáng/tối).
    private let sung = Color.white
    private let upcoming = Color.black.opacity(0.82)

    var body: some View {
        let track = player.current
        let bg = ArtColor.color(for: track) ?? Color(red: 0.33, green: 0.33, blue: 0.36)

        ZStack(alignment: .top) {
            bg.ignoresSafeArea()
            content
            topBar(track)
        }
        .animation(.easeInOut(duration: 0.6), value: track?.id)
        .task(id: track?.id) {
            searching = false
            if let t = track, store.trackID != t.id || store.state == .idle { store.load(t) }
        }
    }

    // MARK: Thanh trên cùng

    private func topBar(_ track: Track?) -> some View {
        HStack(spacing: 10) {
            Spacer()
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.8))
                    PlainTextField(placeholder: "Tên bài, ca sĩ…", text: $query) { search() }
                        .frame(width: 220)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.25), in: Capsule())
                pill("Tìm") { search() }
                pill("Huỷ") { searching = false }
            } else {
                pill("Sai bài? Tìm lại", symbol: "magnifyingglass") {
                    if let t = track {
                        let terms = LyricsStore.searchTerms(for: t)
                        query = "\(terms.artist) \(terms.title)".trimmed
                    }
                    withAnimation(Spotify.quick) { searching = true }
                }
            }
            CircleIcon(symbol: "xmark") { withAnimation(Spotify.spring) { player.showLyrics = false } }
                .help("Đóng lời bài hát")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private func pill(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.black.opacity(0.25), in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private func search() {
        guard let t = player.current, !query.trimmed.isEmpty else { return }
        store.load(t, query: query.trimmed)
        searching = false
    }

    // MARK: Nội dung

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView().controlSize(.large).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .instrumental:
            message("Bài này là nhạc không lời", detail: nil)
        case .notFound:
            message("Rất tiếc, chưa có lời cho bài hát này", detail: "Thử “Sai bài? Tìm lại” với tên chính xác hơn.")
        case .failed(let e):
            message("Không tải được lời bài hát", detail: e)
        case .found(let lines, let synced, let match):
            lyrics(lines, synced: synced, match: match)
        }
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(sung)
            if let detail { Text(detail).font(.system(size: 14, weight: .medium)).foregroundStyle(upcoming) }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyrics(_ lines: [LyricLine], synced: Bool, match: String) -> some View {
        let current = synced ? lines.lastIndex { ($0.time ?? 0) <= player.time + 0.2 } : nil

        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !synced {
                            Text("Lời bài hát này chưa được đồng bộ với bài hát.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(sung.opacity(0.85))
                                .padding(.bottom, 24)
                        }
                        ForEach(lines) { line in
                            lineView(line, current: current, synced: synced)
                                .id(line.id)
                        }
                        Text("Lời bài hát do LRCLIB cung cấp\(match.isEmpty ? "" : " · \(match)")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(upcoming.opacity(0.7))
                            .padding(.top, 48)
                    }
                    .padding(.horizontal, 64)
                    // Chừa khoảng trống để dòng đầu/cuối cũng cuộn được vào vị trí đọc.
                    .padding(.top, geo.size.height * 0.3)
                    .padding(.bottom, geo.size.height * 0.5)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    if let c = current { proxy.scrollTo(c, anchor: UnitPoint(x: 0.5, y: 0.33)) }
                }
                .onChange(of: current) {
                    guard let c = current else { return }
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                        proxy.scrollTo(c, anchor: UnitPoint(x: 0.5, y: 0.33))
                    }
                }
            }
        }
    }

    private func lineView(_ line: LyricLine, current: Int?, synced: Bool) -> some View {
        let isCurrent = line.id == current
        let isSung = synced && current.map { line.id < $0 } ?? false
        let hovered = hoverLine == line.id && synced
        let color: Color = isCurrent ? sung
            : hovered ? sung.opacity(0.9)
            : isSung ? sung.opacity(0.62)
            : synced ? upcoming : sung

        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.4)
            .lineSpacing(4)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onHover { h in
                withAnimation(Spotify.quick) { hoverLine = h ? line.id : (hoverLine == line.id ? nil : hoverLine) }
            }
            .onTapGesture {
                if let t = line.time { player.seek(to: t) }
            }
            .animation(.easeInOut(duration: 0.3), value: isCurrent)
            .animation(.easeInOut(duration: 0.3), value: isSung)
    }
}

/// Nút tròn mờ trên nền màu.
private struct CircleIcon: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(hovering ? 0.4 : 0.25), in: Circle())
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
    }
}

// MARK: - Ô nhập không đổi nền khi gõ

/// TextField gốc của AppKit, không vẽ nền và không có viền focus.
/// (TextField .plain của SwiftUI hiện nền đen của field editor khi đang gõ.)
struct PlainTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.backgroundColor = .clear
        f.focusRingType = .none
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainTextField
        init(_ p: PlainTextField) { parent = p }

        func controlTextDidBeginEditing(_ n: Notification) {
            if let editor = n.userInfo?["NSFieldEditor"] as? NSTextView {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
            }
        }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - Giao diện sáng / tối

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Tự động"
        case .light: "Sáng"
        case .dark: "Tối"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    @MainActor static func apply(_ raw: String) {
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
