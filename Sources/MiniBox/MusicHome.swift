import SwiftUI

// MARK: - YouTube Music (InnerTube) — trang chủ, bảng xếp hạng, playlist, bài tương tự

enum YTM {
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    static func call(_ endpoint: String, _ body: [String: Any]) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        var b = body
        b["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20241023.01.00", "hl": "vi", "gl": "VN"]]
        req.httpBody = try JSONSerialization.data(withJSONObject: b)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Đọc JSON

    static func all(_ key: String, in o: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] {
                if let v = d[key] as? [String: Any] { out.append(v) }
                d.values.forEach(walk)
            } else if let a = o as? [Any] { a.forEach(walk) }
        }
        walk(o)
        return out
    }

    static func runs(_ o: Any?) -> String {
        (((o as? [String: Any])?["runs"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    }

    static func thumb(_ o: Any?, size: Int = 544) -> String? {
        var urls: [String] = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] {
                if let t = d["thumbnails"] as? [[String: Any]] { urls += t.compactMap { $0["url"] as? String } }
                d.values.forEach(walk)
            } else if let a = o as? [Any] { a.forEach(walk) }
        }
        walk(o ?? [:])
        guard var u = urls.last else { return nil }
        if let r = u.range(of: #"=w\d+-h\d+"#, options: .regularExpression) { u.replaceSubrange(r, with: "=w\(size)-h\(size)") }
        else if let r = u.range(of: #"/(hq|mq|sd)default\.jpg"#, options: .regularExpression) { u.replaceSubrange(r, with: "/hqdefault.jpg") }
        return u
    }

    static func seconds(_ s: String) -> Double {
        s.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func track(videoID id: String, title: String, artist: String, duration: Double, art: String?) -> Track {
        let page = "https://music.youtube.com/watch?v=\(id)"
        return Track(title: title, artist: artist.isEmpty ? "Không rõ" : artist, duration: duration, file: "", artwork: nil,
                     source: page, remoteURL: "ytdlp:" + page, artworkURL: art, catalog: "YouTube Music")
    }

    /// Hàng bài hát (musicResponsiveListItemRenderer).
    static func song(row r: [String: Any]) -> Track? {
        let id = ((r["playlistItemData"] as? [String: Any])?["videoId"] as? String)
            ?? (all("watchEndpoint", in: r["flexColumns"] ?? []).first?["videoId"] as? String)
        guard let id else { return nil }
        let cols = (r["flexColumns"] as? [[String: Any]]) ?? []
        func col(_ i: Int) -> String {
            guard i < cols.count else { return "" }
            return runs((cols[i]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"])
        }
        let title = col(0)
        guard !title.isEmpty else { return nil }
        let meta = col(1).components(separatedBy: " • ")
        let fixed = ((r["fixedColumns"] as? [[String: Any]])?.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"]
        let dur = runs(fixed).nilIfEmpty ?? meta.last { $0.range(of: #"^\d+(:\d{2})+$"#, options: .regularExpression) != nil }
        return track(videoID: id, title: title, artist: meta.first ?? "", duration: dur.map(seconds) ?? 0, art: thumb(r["thumbnail"]))
    }

    /// Bài trong danh sách "tiếp theo" (playlistPanelVideoRenderer).
    static func song(panel p: [String: Any]) -> Track? {
        guard let id = p["videoId"] as? String else { return nil }
        let byline = runs(p["longBylineText"]).components(separatedBy: " • ")
        return track(videoID: id, title: runs(p["title"]), artist: byline.first ?? "",
                     duration: seconds(runs(p["lengthText"])), art: thumb(p["thumbnail"]))
    }

    static func videoID(of t: Track) -> String? {
        guard let s = t.source, let u = URL(string: s) else { return nil }
        if let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        if u.host?.contains("youtu.be") == true { return u.pathComponents.dropFirst().first }
        return nil
    }

    // MARK: API

    /// Khoảng 50 bài cùng gu với một bài (giống "radio" / mix của Spotify).
    static func related(to t: Track) async throws -> [Track] {
        var id = videoID(of: t)
        if id == nil {
            // Bài trên máy / SoundCloud: tìm bài tương ứng trên YouTube Music trước.
            let terms = await LyricsStore.searchTerms(for: t)
            let found = try await call("search", ["query": "\(terms.artist) \(terms.title)", "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="])
            id = all("musicResponsiveListItemRenderer", in: found).lazy.compactMap(song(row:)).first.flatMap(videoID(of:))
        }
        guard let id else { return [] }
        let obj = try await call("next", ["videoId": id, "playlistId": "RDAMVM\(id)", "isAudioOnly": true])
        var seen = Set<String>()
        return all("playlistPanelVideoRenderer", in: obj).compactMap(song(panel:)).filter { seen.insert($0.title + $0.artist).inserted }
    }

    struct Page {
        var title: String
        var subtitle: String
        var art: String?
        var tracks: [Track]
    }

    static func playlist(_ browseID: String) async throws -> Page {
        let obj = try await call("browse", ["browseId": browseID])
        let header = all("musicResponsiveHeaderRenderer", in: obj).first ?? all("musicDetailHeaderRenderer", in: obj).first ?? [:]
        let rows = all("musicResponsiveListItemRenderer", in: obj).compactMap(song(row:))
        return Page(title: runs(header["title"]).nilIfEmpty ?? "Playlist",
                    subtitle: runs(header["subtitle"]).nilIfEmpty ?? runs(header["secondSubtitle"]),
                    art: thumb(header["thumbnail"]), tracks: rows)
    }

    static func songs(of artist: String) async throws -> [Track] {
        let obj = try await call("search", ["query": artist, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="])
        return all("musicResponsiveListItemRenderer", in: obj).compactMap(song(row:))
    }
}

// MARK: - Mô hình trang chủ

enum HomeTarget: Hashable {
    case playlist(id: String, title: String)
    case mix(Track)
    case artist(String)

    var title: String {
        switch self {
        case .playlist(_, let t): t
        case .mix(let t): "Mix \(LyricsStore.searchTerms(for: t).artist)"
        case .artist(let a): a
        }
    }
}

struct HomeItem: Identifiable {
    enum Kind { case song(Track), open(HomeTarget) }
    let id = UUID()
    var title: String
    var subtitle: String
    var art: String?
    var localArt: Track?
    var kind: Kind
    var round = false
}

struct HomeShelf: Identifiable {
    enum Style { case cards, songs }
    let id = UUID()
    var title: String
    var subtitle: String?
    var style: Style = .cards
    var items: [HomeItem]
}

@MainActor
final class MusicHome: ObservableObject {
    static let shared = MusicHome()
    @Published private(set) var shelves: [HomeShelf] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var loadedAt: Date?

    func load(force: Bool = false) {
        if !force, let t = loadedAt, Date().timeIntervalSince(t) < 1800, !shelves.isEmpty { return }
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            var result: [HomeShelf] = []
            let seeds = seedTracks()

            // Dành cho bạn: mix theo nghệ sĩ bạn hay nghe
            if !seeds.isEmpty {
                result.append(HomeShelf(title: "Dành cho bạn", subtitle: "Mix tự tạo theo nhạc bạn nghe",
                                        items: seeds.prefix(6).map { s in
                    let terms = LyricsStore.searchTerms(for: s)
                    return HomeItem(title: "Mix \(terms.artist)", subtitle: "\(terms.title) và những bài tương tự",
                                    art: s.artworkURL, localArt: s, kind: .open(.mix(s)))
                }))
            }

            let firstSeed = seeds.first
            async let recommended: [Track]? = firstSeed == nil ? nil : try? await YTM.related(to: firstSeed!)
            async let home = try? YTM.call("browse", ["browseId": "FEmusic_home"])
            async let charts = try? YTM.call("browse", ["browseId": "FEmusic_charts", "formData": ["selectedValues": ["VN"]]])
            async let fresh = try? YTM.call("browse", ["browseId": "FEmusic_new_releases"])

            if let rec = await recommended, rec.count > 1 {
                result.append(HomeShelf(title: "Gợi ý cho bạn", subtitle: "Dựa trên \(LyricsStore.searchTerms(for: seeds[0]).title)", style: .songs,
                                        items: rec.dropFirst().prefix(12).map(Self.songItem)))
            }
            if let h = await home { result += Self.shelves(from: h) }
            if let c = await charts {
                for var s in Self.shelves(from: c) {
                    if s.title.lowercased().contains("nghệ sĩ") {
                        s.items = s.items.map { var i = $0; i.round = true; return i }
                    }
                    s.title = s.title.replacingOccurrences(of: "Bảng xếp hạng video", with: "Thịnh hành tại Việt Nam")
                    result.append(s)
                }
            }
            if let f = await fresh {
                for var s in Self.shelves(from: f) {
                    s.title = "Mới phát hành"
                    result.append(s)
                }
            }

            shelves = result
            loading = false
            loadedAt = .now
            if result.isEmpty { error = "Không tải được gợi ý. Kiểm tra kết nối mạng." }
        }
    }

    /// Bài gốc để gợi ý: nghe gần đây, rồi tới thư viện; mỗi nghệ sĩ một bài.
    private func seedTracks() -> [Track] {
        var seen = Set<String>()
        let pool = MusicPlayer.shared.history + MusicLibrary.shared.tracks
        return pool.filter { seen.insert(LyricsStore.searchTerms(for: $0).artist.lowercased()).inserted }
    }

    private static func songItem(_ t: Track) -> HomeItem {
        HomeItem(title: t.title, subtitle: t.artist, art: t.artworkURL, kind: .song(t))
    }

    /// Các kệ ngang (musicCarouselShelfRenderer) của một trang YouTube Music.
    private static func shelves(from obj: Any) -> [HomeShelf] {
        YTM.all("musicCarouselShelfRenderer", in: obj).compactMap { shelf in
            let header = (shelf["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            let title = YTM.runs(header?["title"])
            let contents = shelf["contents"] as? [[String: Any]] ?? []
            var songs = 0
            let items: [HomeItem] = contents.compactMap { c in
                if let r = c["musicResponsiveListItemRenderer"] as? [String: Any] {
                    if let t = YTM.song(row: r) { songs += 1; return songItem(t) }
                    // Nghệ sĩ dạng hàng
                    let cols = (r["flexColumns"] as? [[String: Any]]) ?? []
                    let name = cols.first.map { YTM.runs(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]) } ?? ""
                    guard !name.isEmpty else { return nil }
                    let sub = cols.count > 1 ? YTM.runs((cols[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]) : ""
                    return HomeItem(title: name, subtitle: sub.isEmpty ? "Nghệ sĩ" : sub, art: YTM.thumb(r["thumbnail"], size: 360),
                                    kind: .open(.artist(name)), round: true)
                }
                guard let r = c["musicTwoRowItemRenderer"] as? [String: Any] else { return nil }
                let name = YTM.runs(r["title"])
                let sub = YTM.runs(r["subtitle"])
                let art = YTM.thumb(r["thumbnailRenderer"])
                let nav = r["navigationEndpoint"] as? [String: Any] ?? [:]
                if let w = nav["watchEndpoint"] as? [String: Any], let vid = w["videoId"] as? String {
                    songs += 1
                    // Dòng phụ dạng "Bài hát • Nghệ sĩ • 1,2 Tr lượt xem" → lấy phần là tên nghệ sĩ
                    let skip = ["bài hát", "video", "đĩa đơn", "song", "single", "ep", "album"]
                    let artist = sub.components(separatedBy: " • ").first {
                        let l = $0.lowercased()
                        return !skip.contains(l) && !l.contains("lượt") && !l.contains("view")
                            && l.range(of: #"^\d{4}$"#, options: .regularExpression) == nil
                    } ?? sub
                    return songItem(YTM.track(videoID: vid, title: name, artist: artist, duration: 0, art: art))
                }
                if let b = nav["browseEndpoint"] as? [String: Any], let id = b["browseId"] as? String {
                    let type = ((b["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"]
                        as? [String: Any])?["pageType"] as? String ?? ""
                    if type.contains("ARTIST") {
                        return HomeItem(title: name, subtitle: "Nghệ sĩ", art: art, kind: .open(.artist(name)), round: true)
                    }
                    return HomeItem(title: name, subtitle: sub, art: art, kind: .open(.playlist(id: id, title: name)))
                }
                return nil
            }
            guard !items.isEmpty, !title.isEmpty else { return nil }
            let allSongs = songs == items.count && contents.first?["musicResponsiveListItemRenderer"] != nil
            return HomeShelf(title: title, style: allSongs ? .songs : .cards, items: items)
        }
    }
}

// MARK: - Giao diện trang chủ

struct MusicHomeView: View {
    @ObservedObject private var home = MusicHome.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var lib = MusicLibrary.shared
    @ObservedObject private var settings = MusicSettings.shared
    let onOpen: (HomeTarget) -> Void
    let onAllSongs: () -> Void

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Chào buổi sáng"
        case 12..<18: "Chào buổi chiều"
        default: "Chào buổi tối"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Text(greeting).font(.system(size: 30, weight: .bold))
                    Spacer()
                    if home.loading { ProgressView().controlSize(.small) }
                    Button { home.load(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(SP.subtext)
                        .help("Làm mới gợi ý")
                }

                quickGrid

                if settings.provider == .off {
                    Text("Bật YouTube Music trong Cài đặt → Phát nhạc để xem gợi ý và bảng xếp hạng.")
                        .foregroundStyle(SP.subtext)
                } else {
                    if let e = home.error, home.shelves.isEmpty { Text(e).foregroundStyle(SP.subtext) }
                    ForEach(home.shelves) { shelf in
                        ShelfView(shelf: shelf, onOpen: onOpen)
                    }
                    if home.loading && home.shelves.isEmpty { placeholder }
                }
            }
            .padding(24)
        }
        .background(
            LinearGradient(colors: [Spotify.liked.opacity(0.45), SP.panel], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
        )
        .onAppear { if settings.provider != .off { home.load() } }
    }

    /// Ô truy cập nhanh (giống 8 ô đầu trang Spotify).
    private var quickGrid: some View {
        let recent = Array(player.history.prefix(7))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
            QuickTile(title: "Tất cả bài hát", cover: AnyView(LikedCover(size: 56)), playing: false,
                      onOpen: onAllSongs, onPlay: { player.play(lib.tracks) })
            ForEach(recent) { t in
                QuickTile(title: t.title, cover: AnyView(ArtworkView(track: t, size: 56, radius: 0)),
                          playing: player.current?.id == t.id && player.isPlaying,
                          onOpen: { onOpen(.mix(t)) }, onPlay: { player.play([t]) })
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(SP.elevated).frame(width: 220, height: 24)
            HStack(spacing: 16) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).fill(SP.elevated).frame(width: 164, height: 210)
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}

private struct QuickTile: View {
    let title: String
    let cover: AnyView
    let playing: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            cover.frame(width: 56, height: 56).clipped()
            Text(title).font(.system(size: 14, weight: .bold)).lineLimit(2)
            Spacer(minLength: 4)
            if hovering || playing {
                SpotifyPlayButton(isPlaying: playing, size: 34, action: onPlay)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(height: 56)
        .background(hovering ? SP.elevatedHover : SP.elevated, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
        .onTapGesture(perform: onOpen)
    }
}

private struct ShelfView: View {
    @ObservedObject private var player = MusicPlayer.shared
    let shelf: HomeShelf
    let onOpen: (HomeTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title).font(.system(size: 22, weight: .bold))
                if let s = shelf.subtitle { Text(s).font(.system(size: 13)).foregroundStyle(SP.subtext) }
            }
            switch shelf.style {
            case .cards:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(shelf.items) { item in HomeCard(item: item, siblings: shelf.items, onOpen: onOpen) }
                    }
                }
            case .songs:
                let songs = shelf.items.compactMap { if case .song(let t) = $0.kind { return t } else { return nil } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8)], spacing: 2) {
                    ForEach(songs) { t in SongTile(track: t, queue: songs) }
                }
            }
        }
    }
}

/// Thẻ vuông kiểu Spotify: rê chuột nền sáng lên + nút Play xanh trượt lên.
private struct HomeCard: View {
    @ObservedObject private var player = MusicPlayer.shared
    let item: HomeItem
    let siblings: [HomeItem]
    let onOpen: (HomeTarget) -> Void
    @State private var hovering = false

    private var song: Track? { if case .song(let t) = item.kind { return t } else { return nil } }

    var body: some View {
        let playing = song.map { player.current?.id == $0.id && player.isPlaying } ?? false
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                cover
                    .frame(width: 156, height: 156)
                    .clipShape(item.round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                if !item.round {
                    SpotifyPlayButton(isPlaying: playing, size: 46) { play() }
                        .padding(8)
                        .opacity(hovering || playing ? 1 : 0)
                        .offset(y: hovering || playing ? 0 : 8)
                }
            }
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 156, alignment: item.round ? .center : .leading)
            Text(item.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(SP.subtext)
                .lineLimit(2)
                .frame(maxWidth: 156, alignment: item.round ? .center : .leading)
        }
        .padding(10)
        .frame(width: 176, alignment: .topLeading)
        .background(hovering ? SP.elevated : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
        .onTapGesture { open() }
    }

    @ViewBuilder
    private var cover: some View {
        if let t = item.localArt, MusicLibrary.shared.artwork(t) != nil {
            ArtworkView(track: t, size: 156, radius: 0)
        } else if let img = RemoteArt.shared.image(item.art) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            SP.elevatedHover.overlay(Image(systemName: item.round ? "person.fill" : "music.note.list")
                .font(.system(size: 40)).foregroundStyle(SP.subtext))
        }
    }

    private func open() {
        switch item.kind {
        case .song(let t): player.play(siblings.compactMap { if case .song(let s) = $0.kind { s } else { nil } }, startAt: t.id)
        case .open(let target): onOpen(target)
        }
    }

    private func play() {
        switch item.kind {
        case .song: open()
        case .open(let target):
            Task {
                let tracks = (try? await MusicHome.tracks(for: target)) ?? []
                player.play(tracks)
            }
        }
    }
}

private struct SongTile: View {
    @ObservedObject private var player = MusicPlayer.shared
    let track: Track
    let queue: [Track]
    @State private var hovering = false

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 10) {
            ZStack {
                ArtworkView(track: track, size: 48)
                if hovering || (isCurrent && player.isPlaying) {
                    Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 4))
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 14)).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.spotifyGreen : SP.text)
                Text(track.artist).font(.system(size: 12)).foregroundStyle(SP.subtext).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(hovering ? Spotify.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { isCurrent ? player.toggle() : player.play(queue, startAt: track.id) }
        .contextMenu {
            Button("Phát", systemImage: "play.fill") { player.play(queue, startAt: track.id) }
            Button("Lưu vào thư viện", systemImage: "arrow.down.circle") { MusicLibrary.shared.save(track) }
                .disabled(MusicLibrary.shared.isSaved(track))
        }
    }
}

extension MusicHome {
    static func tracks(for target: HomeTarget) async throws -> [Track] {
        switch target {
        case .playlist(let id, _): try await YTM.playlist(id).tracks
        case .mix(let t): try await YTM.related(to: t)
        case .artist(let a): try await YTM.songs(of: a)
        }
    }
}

// MARK: - Trang playlist / mix / nghệ sĩ

struct RemotePageView: View {
    @ObservedObject private var player = MusicPlayer.shared
    let target: HomeTarget
    @State private var page: YTM.Page?
    @State private var error: String?

    var body: some View {
        let tint = ArtColor.color(for: page?.tracks.first) ?? Spotify.liked
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 24) {
                    Group {
                        if case .mix(let t) = target { ArtworkView(track: t, size: 190, radius: 6) }
                        else if let img = RemoteArt.shared.image(page?.art) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 190, height: 190)
                                .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
                        } else { ArtworkView(track: page?.tracks.first, size: 190, radius: isArtist ? 95 : 6) }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kindLabel).font(.system(size: 13, weight: .semibold))
                        Text(page?.title ?? target.title)
                            .font(.system(size: 52, weight: .heavy)).tracking(-0.8).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(page.map { "\($0.subtitle.isEmpty ? "" : "\($0.subtitle) • ")\($0.tracks.count) bài" } ?? "Đang tải…")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 24)
                .background(tint.overlay(LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)))

                HStack(spacing: 22) {
                    let tracks = page?.tracks ?? []
                    let current = tracks.contains { $0.id == player.current?.id }
                    SpotifyPlayButton(isPlaying: current && player.isPlaying) {
                        if current { player.toggle() } else { player.play(tracks) }
                    }
                    .disabled(tracks.isEmpty)
                    SpotifyIconButton(symbol: "shuffle", active: player.shuffle, size: 26, help: "Phát ngẫu nhiên") { player.shuffle.toggle() }
                    Spacer()
                }
                .padding(24)
                .background(LinearGradient(colors: [tint.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))

                VStack(spacing: 0) {
                    if let error { Text(error).foregroundStyle(SP.subtext).padding(40) }
                    else if page == nil { ProgressView().padding(40) }
                    ForEach(Array((page?.tracks ?? []).enumerated()), id: \.element.id) { i, t in
                        NumberedRow(number: i + 1, track: t, queue: page?.tracks ?? [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(SP.panel)
        .task(id: target) {
            page = nil
            error = nil
            do {
                switch target {
                case .playlist(let id, _): page = try await YTM.playlist(id)
                case .mix(let t): page = YTM.Page(title: target.title, subtitle: "Bắt đầu từ \(LyricsStore.searchTerms(for: t).title)", art: t.artworkURL,
                                                   tracks: try await YTM.related(to: t))
                case .artist(let a): page = YTM.Page(title: a, subtitle: "Bài hát phổ biến", art: nil, tracks: try await YTM.songs(of: a))
                }
                if page?.tracks.isEmpty == true { error = "Không có bài nào." }
            } catch {
                self.error = "Không tải được: \(error.localizedDescription)"
            }
        }
    }

    private var isArtist: Bool { if case .artist = target { true } else { false } }
    private var kindLabel: String {
        switch target {
        case .playlist: "Playlist"
        case .mix: "Mix dành cho bạn"
        case .artist: "Nghệ sĩ"
        }
    }
}

private struct NumberedRow: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var lib = MusicLibrary.shared
    let number: Int
    let track: Track
    let queue: [Track]
    @State private var hovering = false

    var body: some View {
        let isCurrent = player.current?.id == track.id
        let saved = lib.isSaved(track)
        HStack(spacing: 16) {
            ZStack {
                if hovering {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                } else if isCurrent && player.isPlaying {
                    EqualizerBars()
                } else {
                    Text("\(number)").monospacedDigit().foregroundStyle(isCurrent ? Color.spotifyGreen : SP.subtext)
                }
            }
            .frame(width: 22, alignment: .trailing)
            ArtworkView(track: track, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 15)).lineLimit(1).foregroundStyle(isCurrent ? Color.spotifyGreen : SP.text)
                Text(track.artist).font(.system(size: 13)).lineLimit(1).foregroundStyle(hovering ? SP.text : SP.subtext)
            }
            Spacer(minLength: 8)
            Button { lib.save(track) } label: {
                Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(saved ? Spotify.green : SP.subtext)
            }
            .buttonStyle(PressScaleStyle(scale: 0.85))
            .disabled(saved)
            .opacity(hovering || saved ? 1 : 0)
            .help(saved ? "Đã lưu" : "Lưu vào thư viện")
            Text(track.duration > 0 ? formatTime(track.duration) : "")
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(SP.subtext)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(hovering ? Spotify.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { player.play(queue, startAt: track.id) }
        .onTapGesture { if hovering { isCurrent ? player.toggle() : player.play(queue, startAt: track.id) } }
    }
}
