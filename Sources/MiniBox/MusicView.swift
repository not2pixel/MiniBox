import SwiftUI

extension Color {
    /// Xanh dùng cho chữ (tên bài đang phát…): sáng ở giao diện tối, đậm hơn ở giao diện sáng cho dễ đọc.
    static let spotifyGreen = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255, alpha: 1)
            : NSColor(red: 0.07, green: 0.62, blue: 0.29, alpha: 1)
    })
}

/// Ảnh bìa vuông, không có thì hiện nốt nhạc.
struct ArtworkView: View {
    @ObservedObject private var remote = RemoteArt.shared
    let track: Track?
    var size: CGFloat = 48
    var radius: CGFloat = 4

    var body: some View {
        Group {
            if let img = MusicLibrary.shared.artwork(track) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                SP.elevated.overlay(Image(systemName: "music.note").font(.system(size: size * 0.36)).foregroundStyle(SP.subtext))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Màn chính

struct MusicView: View {
    enum Section: Hashable { case home, all, playlist(UUID), search, remote(HomeTarget) }
    enum SortKey: String, CaseIterable { case custom, title, artist, added, duration }

    @ObservedObject private var lib = MusicLibrary.shared
    @ObservedObject private var player = MusicPlayer.shared
    @State private var section: Section = .home
    @State private var link = ""
    @State private var renaming: Playlist?
    @State private var editing: Track?
    @State private var dropTargeted = false
    /// Bề rộng khung giữa — hẹp thì ẩn bớt cột như Spotify.
    @State private var mainWidth: CGFloat = 1000
    private var showSource: Bool { mainWidth > 820 }
    private var showDate: Bool { mainWidth > 660 }
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var lastQuery = ""
    @ObservedObject private var settings = MusicSettings.shared
    @AppStorage("musicRailExpanded") private var railExpanded = false
    @AppStorage("musicSort") private var sort: SortKey = .custom

    private var playlist: Playlist? {
        if case .playlist(let id) = section { return lib.playlists.first { $0.id == id } }
        return nil
    }

    private var shown: [Track] {
        let base = playlist.map(lib.tracks(in:)) ?? lib.tracks
        switch sort {
        case .custom: return base
        case .title: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: return base.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .added: return base.sorted { $0.addedAt > $1.addedAt }
        case .duration: return base.sorted { $0.duration < $1.duration }
        }
    }

    private var tint: Color {
        guard let p = playlist else { return Spotify.liked }
        return ArtColor.color(for: lib.tracks(in: p).first) ?? Color(white: 0.4)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 8) {
                rail
                    .frame(width: railExpanded ? 280 : 72)
                    .frame(maxHeight: .infinity)
                    .background(SP.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                ZStack {
                    if player.showLyrics, player.current != nil {
                        LyricsPanel()
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    } else if section == .home {
                        MusicHomeView(onOpen: { section = .remote($0) }, onAllSongs: { section = .all })
                            .transition(.opacity)
                    } else if case .remote(let target) = section {
                        RemotePageView(target: target).id(target).transition(.opacity)
                    } else if section == .search {
                        SearchResults(query: lastQuery, results: results, searching: searching, error: searchError)
                            .transition(.opacity)
                    } else {
                        mainPanel.transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(Spotify.spring, value: player.showLyrics)

                if player.showNowPlaying, player.current != nil {
                    NowPlayingPanel()
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                        .background(SP.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding([.horizontal, .bottom], 8)
            .animation(Spotify.spring, value: player.showNowPlaying)
            .animation(Spotify.spring, value: railExpanded)
        }
        .background(SP.base)
        .navigationTitle("Phát nhạc")
        .navigationSubtitle("\(lib.tracks.count) bài hát")
        .sheet(item: $renaming) { RenamePlaylistSheet(playlist: $0) }
        .sheet(item: $editing) { EditTrackSheet(track: $0) }
        .alert("Phát nhạc", isPresented: Binding(get: { lib.message != nil }, set: { if !$0 { lib.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lib.message ?? "")
        }
        .task(id: link) {
            let q = link.trimmed
            guard q.count >= 2, !Catalog.looksLikeLink(q), settings.provider != .off else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await runSearch(q)
        }
        .onChange(of: lib.playlists) {
            if case .playlist(let id) = section, !lib.playlists.contains(where: { $0.id == id }) { section = .all }
        }
    }

    // MARK: Thanh trên cùng (Home + ô dán link kiểu ô tìm kiếm)

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            HoverCircle(symbol: section == .home && !player.showLyrics ? "house.fill" : "house", size: 48) {
                section = .home
                player.showLyrics = false
            }
            .help("Trang chủ")

            SearchCapsule(link: $link, onSubmit: submit, onImport: lib.importWithPanel,
                          enabled: lib.toolState == .ready)
                .frame(maxWidth: 480)
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private func runSearch(_ q: String) async {
        lastQuery = q
        section = .search
        player.showLyrics = false
        searching = true
        searchError = nil
        do {
            let found = try await Catalog.search(q)
            guard q == lastQuery else { return }
            results = found
        } catch {
            guard q == lastQuery else { return }
            results = []
            searchError = error.localizedDescription
        }
        searching = false
    }

    private func submit() {
        guard !link.trimmed.isEmpty else { return }
        if !Catalog.looksLikeLink(link) {
            if settings.provider == .off {
                lib.message = "Bật kho nhạc online trong Cài đặt → Phát nhạc để tìm bài hát, hoặc dán link để tải."
            } else {
                let q = link.trimmed
                Task { await runSearch(q) }
            }
            return
        }
        if lib.toolState != .ready { lib.message = "Cài công cụ tải nhạc trước (banner trong danh sách)."; return }
        lib.importLink(link)
        link = ""
        section = .all
        player.showLyrics = false
    }

    // MARK: Thư viện bên trái

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { railExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 20))
                    if railExpanded {
                        Text("Thư viện của bạn").font(.system(size: 15, weight: .bold))
                        Spacer()
                    }
                }
                .foregroundStyle(SP.subtext)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(railExpanded ? "Thu gọn thư viện" : "Mở rộng thư viện")
            .frame(maxWidth: .infinity, alignment: railExpanded ? .leading : .center)
            .padding(.horizontal, railExpanded ? 16 : 0)
            .frame(height: 56)

            HoverCircle(symbol: "plus", size: 36) {
                let id = lib.newPlaylist()
                section = .playlist(id)
                player.showLyrics = false
                renaming = lib.playlists.first { $0.id == id }
            }
            .help("Tạo playlist")
            .frame(maxWidth: .infinity, alignment: railExpanded ? .leading : .center)
            .padding(.horizontal, railExpanded ? 12 : 0)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    railItem(.all, title: "Tất cả bài hát", subtitle: "Bộ sưu tập • \(lib.tracks.count) bài") {
                        LikedCover(size: 48)
                    }
                    ForEach(lib.playlists) { p in
                        railItem(.playlist(p.id), title: p.name, subtitle: "Playlist • \(p.trackIDs.count) bài") {
                            PlaylistCover(playlist: p, size: 48)
                        }
                        .contextMenu {
                            Button("Phát", systemImage: "play.fill") { player.play(lib.tracks(in: p)) }
                            Button("Đổi tên…", systemImage: "pencil") { renaming = p }
                            Divider()
                            Button("Xoá playlist", systemImage: "trash", role: .destructive) {
                                lib.playlists.removeAll { $0.id == p.id }
                            }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            lib.add(ids.compactMap(UUID.init(uuidString:)), to: p.id)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func railItem<Cover: View>(_ s: Section, title: String, subtitle: String,
                                       @ViewBuilder cover: () -> Cover) -> some View {
        RailItem(selected: section == s, expanded: railExpanded, title: title, subtitle: subtitle,
                 playing: isPlaying(s), cover: cover) {
            section = s
            player.showLyrics = false
        }
    }

    private func isPlaying(_ s: Section) -> Bool {
        guard player.isPlaying, let cur = player.current, case .playlist(let id) = s else { return false }
        return lib.playlists.first { $0.id == id }?.trackIDs.contains(cur.id) ?? false
    }

    // MARK: Khung giữa

    private var mainPanel: some View {
        List {
            VStack(alignment: .leading, spacing: 0) {
                header
                actionBar
                VStack(alignment: .leading, spacing: 12) {
                    if lib.toolState != .ready { toolBanner }
                    ForEach(lib.jobs) { JobRow(job: $0) }
                    if !shown.isEmpty { tableHeader }
                }
                .padding(.horizontal, 24)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(Array(shown.enumerated()), id: \.element.id) { i, track in
                TrackRow(number: i + 1, track: track, queue: shown, playlistID: playlist?.id,
                         showSource: showSource, showDate: showDate) { editing = track }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .onMove(perform: playlist != nil && sort == .custom
                    ? { lib.movePlaylistTracks(playlist!.id, from: $0, to: $1) } : nil)

            if shown.isEmpty && lib.jobs.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Color.clear.frame(height: 24).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(SP.panel)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { mainWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in mainWidth = w }
        })
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Spotify.green, lineWidth: 2)
                    .background(Spotify.green.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { lib.importFiles(files) }
            if let web = urls.first(where: { !$0.isFileURL }) { lib.importLink(web.absoluteString) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var header: some View {
        let total = Int(shown.reduce(0) { $0 + $1.duration })
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        let length = h > 0 ? "\(h) giờ \(m) phút" : "\(m) phút \(s) giây"
        return HStack(alignment: .bottom, spacing: 24) {
            Group {
                if let p = playlist { PlaylistCover(playlist: p, size: mainWidth < 760 ? 150 : 200) }
                else { LikedCover(size: mainWidth < 760 ? 150 : 200) }
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist == nil ? "Bộ sưu tập" : "Playlist")
                    .font(.system(size: 13, weight: .semibold))
                let name = playlist?.name ?? "Tất cả bài hát"
                Text(name)
                    .font(.system(size: name.count > 22 || mainWidth < 760 ? 44 : 64, weight: .heavy))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                    Text("MiniBox").fontWeight(.bold)
                    Text("• \(shown.count) bài\(total > 0 ? ", \(length)" : "")")
                        .foregroundStyle(.white.opacity(0.75))
                }
                .font(.system(size: 14))
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 48)
        .padding(.bottom, 24)
        .background(
            tint.overlay(LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom))
        )
        .animation(.easeInOut(duration: 0.4), value: section)
    }

    private var isShowingCurrentQueue: Bool {
        guard let cur = player.current else { return false }
        return shown.contains { $0.id == cur.id }
    }

    private var actionBar: some View {
        HStack(spacing: 22) {
            SpotifyPlayButton(isPlaying: isShowingCurrentQueue && player.isPlaying) {
                if isShowingCurrentQueue { player.toggle() } else { player.play(shown) }
            }
            .disabled(shown.isEmpty)
            .opacity(shown.isEmpty ? 0.5 : 1)

            SpotifyIconButton(symbol: "shuffle", active: player.shuffle, size: 26, help: "Phát ngẫu nhiên") {
                player.shuffle.toggle()
            }

            Menu {
                Button("Nhập tệp nhạc/video…", systemImage: "folder.badge.plus", action: lib.importWithPanel)
                if let p = playlist {
                    Divider()
                    Button("Đổi tên…", systemImage: "pencil") { renaming = p }
                    Button("Xoá playlist", systemImage: "trash", role: .destructive) {
                        lib.playlists.removeAll { $0.id == p.id }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 24, weight: .bold)).foregroundStyle(SP.subtext)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Menu {
                Picker("Sắp xếp theo", selection: $sort) {
                    Text(playlist == nil ? "Mới thêm trước" : "Thứ tự tuỳ chỉnh").tag(SortKey.custom)
                    Text("Tiêu đề").tag(SortKey.title)
                    Text("Nghệ sĩ").tag(SortKey.artist)
                    Text("Ngày thêm").tag(SortKey.added)
                    Text("Thời lượng").tag(SortKey.duration)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Text(sortTitle)
                    Image(systemName: "list.bullet")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SP.subtext)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.12), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var sortTitle: String {
        switch sort {
        case .custom: "Danh sách"
        case .title: "Tiêu đề"
        case .artist: "Nghệ sĩ"
        case .added: "Ngày thêm"
        case .duration: "Thời lượng"
        }
    }

    private var tableHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Text("#").frame(width: 20, alignment: .trailing)
                Text("Tiêu đề")
                Spacer()
                if showSource { Text("Nguồn").frame(width: 110, alignment: .leading) }
                if showDate { Text("Ngày thêm").frame(width: 110, alignment: .leading) }
                Image(systemName: "clock").frame(width: 52, alignment: .trailing)
            }
            .font(.system(size: 13))
            .foregroundStyle(SP.subtext)
            .padding(.horizontal, 16)
            Rectangle().fill(SP.divider).frame(height: 1)
        }
        .padding(.bottom, 8)
    }

    private var toolBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Spotify.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cài công cụ tải nhạc").font(.headline)
                Text("Cần cài thêm một công cụ nhỏ để nghe và tải nhạc online.")
                    .font(.caption)
                    .foregroundStyle(SP.subtext)
            }
            Spacer()
            if case .installing = lib.toolState {
                ProgressView().controlSize(.small)
            } else {
                Button("Cài đặt", action: lib.installTool).buttonStyle(.borderedProminent).tint(Spotify.green)
            }
        }
        .padding(14)
        .background(SP.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundStyle(SP.subtext)
            Text(playlist == nil ? "Chưa có bài hát nào" : "Playlist trống").font(.title3.bold())
            Text(playlist == nil ? "Dán link vào ô ở trên cùng, hoặc kéo thả tệp nhạc/video vào đây."
                                 : "Kéo bài hát từ “Tất cả bài hát” thả vào playlist ở cột trái, hoặc chuột phải → Thêm vào playlist.")
                .font(.callout)
                .foregroundStyle(SP.subtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

// MARK: - Thành phần nhỏ

/// Nút tròn nền xám (Home, ＋, đóng): rê chuột thì sáng hơn và to nhẹ.
private struct HoverCircle: View {
    let symbol: String
    var size: CGFloat = 40
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(hovering ? SP.text : SP.subtext)
                .frame(width: size, height: size)
                .background(hovering ? SP.elevatedHover : SP.elevated, in: Circle())
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
    }
}

/// Ô dán link giống ô tìm kiếm "What do you want to play?".
private struct SearchCapsule: View {
    @Binding var link: String
    let onSubmit: () -> Void
    let onImport: () -> Void
    let enabled: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(hovering ? SP.text : SP.subtext)
            PlainTextField(placeholder: "Bạn muốn phát gì? Tìm bài hát hoặc dán link…", text: $link, onSubmit: onSubmit)
            if !link.isEmpty {
                Button { link = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(SP.subtext)
                }
                .buttonStyle(PressScaleStyle())
                .help("Xoá")
                if Catalog.looksLikeLink(link) {
                    Button(action: onSubmit) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Spotify.green)
                    }
                    .buttonStyle(PressScaleStyle())
                    .help(enabled ? "Tải về" : "Cần cài công cụ tải nhạc trước")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            Rectangle().fill(SP.subtext.opacity(0.5)).frame(width: 1, height: 24)
            Button(action: onImport) {
                Image(systemName: "folder.badge.plus").font(.system(size: 18)).foregroundStyle(SP.subtext)
            }
            .buttonStyle(PressScaleStyle())
            .help("Nhập tệp nhạc/video từ máy")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(hovering ? SP.elevatedHover : SP.elevated, in: Capsule())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
        .animation(Spotify.quick, value: link.isEmpty)
    }
}

private struct RailItem<Cover: View>: View {
    let selected: Bool
    let expanded: Bool
    let title: String
    let subtitle: String
    let playing: Bool
    @ViewBuilder let cover: Cover
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                cover
                if expanded {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 15))
                            .foregroundStyle(playing ? Color.spotifyGreen : SP.text)
                            .lineLimit(1)
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(SP.subtext).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if playing { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Spotify.green) }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(selected ? Spotify.selected : hovering ? Spotify.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "" : title)
    }
}

// MARK: - Hàng bài hát

private struct TrackRow: View {
    @ObservedObject private var lib = MusicLibrary.shared
    @ObservedObject private var player = MusicPlayer.shared
    let number: Int
    let track: Track
    let queue: [Track]
    let playlistID: UUID?
    var showSource = true
    var showDate = true
    let onEdit: () -> Void
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = .vi
        f.unitsStyle = .full
        return f
    }()

    private var added: String {
        Date().timeIntervalSince(track.addedAt) < 7 * 86_400
            ? Self.relative.localizedString(for: track.addedAt, relativeTo: .now)
            : track.addedAt.formatted(.dateTime.day().month(.abbreviated).year().locale(.vi))
    }

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 16) {
            ZStack {
                if hovering {
                    Button { isCurrent ? player.toggle() : player.play(queue, startAt: track.id) } label: {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SP.text)
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.85))
                } else if isCurrent && player.isPlaying {
                    EqualizerBars()
                } else {
                    Text("\(number)")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? Color.spotifyGreen : SP.subtext)
                }
            }
            .frame(width: 20, alignment: .trailing)

            HStack(spacing: 12) {
                ArtworkView(track: track, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Color.spotifyGreen : SP.text)
                    Text(track.artist)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(hovering ? SP.text : SP.subtext)
                }
            }
            Spacer(minLength: 8)
            if showSource {
                Text(track.sourceHost ?? "Tệp trên máy").frame(width: 110, alignment: .leading)
            }
            if showDate {
                Text(added).frame(width: 110, alignment: .leading)
            }
            Text(formatTime(track.duration))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 13))
        .foregroundStyle(SP.subtext)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(hovering ? Spotify.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { player.play(queue, startAt: track.id) }
        .draggable(track.id.uuidString)
        .contextMenu {
            Button("Phát", systemImage: "play.fill") { player.play(queue, startAt: track.id) }
            AddToPlaylistMenu(trackID: track.id, title: track.title)
            if let playlistID {
                Button("Xoá khỏi playlist", systemImage: "minus.circle") { lib.remove(track.id, from: playlistID) }
            }
            Divider()
            Button("Sửa tên / nghệ sĩ…", systemImage: "pencil", action: onEdit)
            if let s = track.source, let url = URL(string: s) {
                Button("Mở nguồn", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Xoá bài hát", systemImage: "trash", role: .destructive) { lib.delete(track.id) }
        }
    }
}

struct AddToPlaylistMenu: View {
    @ObservedObject private var lib = MusicLibrary.shared
    let trackID: UUID
    let title: String

    var body: some View {
        Menu("Thêm vào playlist") {
            Button("Playlist mới") {
                let id = lib.newPlaylist(title)
                lib.add([trackID], to: id)
            }
            Divider()
            ForEach(lib.playlists) { p in
                Button(p.name) { lib.add([trackID], to: p.id) }
                    .disabled(p.trackIDs.contains(trackID))
            }
        }
    }
}

private struct JobRow: View {
    @ObservedObject private var lib = MusicLibrary.shared
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch job.status {
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .converting: EqualizerBars()
                default: ProgressView().controlSize(.small)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).lineLimit(1)
                switch job.status {
                case .failed: Text(job.error ?? "Lỗi").font(.caption).foregroundStyle(.orange).lineLimit(2)
                case .fetching: Text("Đang lấy thông tin…").font(.caption).foregroundStyle(SP.subtext)
                case .converting: Text("Đang chuyển thành bài nhạc…").font(.caption).foregroundStyle(SP.subtext)
                case .downloading: SpotifyBar(value: job.progress, onCommit: { _ in }).allowsHitTesting(false)
                }
            }
            Spacer()
            if job.status == .failed {
                Button("Thử lại") { lib.retry(job) }
                Button { lib.dismissJob(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(SP.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PlaylistCover: View {
    let playlist: Playlist
    let size: CGFloat

    var body: some View {
        let tracks = MusicLibrary.shared.tracks(in: playlist)
        Group {
            if tracks.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) { ArtworkView(track: tracks[0], size: half, radius: 0); ArtworkView(track: tracks[1], size: half, radius: 0) }
                    HStack(spacing: 0) { ArtworkView(track: tracks[2], size: half, radius: 0); ArtworkView(track: tracks[3], size: half, radius: 0) }
                }
            } else if let first = tracks.first {
                ArtworkView(track: first, size: size, radius: 0)
            } else {
                SP.elevated.overlay(Image(systemName: "music.note").font(.system(size: size * 0.36)).foregroundStyle(SP.subtext))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 6 : 4, style: .continuous))
    }
}

// MARK: - Kết quả tìm kiếm (kiểu Spotify)

private struct SearchResults: View {
    @ObservedObject private var lib = MusicLibrary.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var settings = MusicSettings.shared
    let query: String
    let results: [Track]
    let searching: Bool
    let error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 8) {
                    Text(settings.provider.title)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(SP.text, in: Capsule())
                        .foregroundStyle(SP.panel)
                    Spacer()
                    if searching { ProgressView().controlSize(.small) }
                }

                let local = lib.tracks.filter {
                    $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                }
                if !local.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Trong thư viện của bạn").font(.system(size: 24, weight: .bold))
                        VStack(spacing: 0) {
                            ForEach(local.prefix(5)) { t in ResultRow(track: t, queue: local) }
                        }
                    }
                }

                if let error {
                    message("Không tìm được", error)
                } else if results.isEmpty && !searching {
                    message("Không có kết quả cho “\(query)”", "Thử từ khoá khác, hoặc đổi kho nhạc trong Cài đặt → Phát nhạc.")
                } else if let top = results.first {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kết quả hàng đầu").font(.system(size: 24, weight: .bold))
                            TopResultCard(track: top) { player.play(results, startAt: top.id) }
                        }
                        .frame(minWidth: 280, maxWidth: 420)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Bài hát").font(.system(size: 24, weight: .bold))
                            VStack(spacing: 0) {
                                ForEach(results.prefix(4)) { t in ResultRow(track: t, queue: results) }
                            }
                        }
                    }

                    if results.count > 4 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Thêm kết quả").font(.system(size: 24, weight: .bold))
                            VStack(spacing: 0) {
                                ForEach(results.dropFirst(4)) { t in ResultRow(track: t, queue: results) }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .animation(Spotify.quick, value: results.map(\.id))
        }
        .background(SP.panel)
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(detail).font(.system(size: 14)).foregroundStyle(SP.subtext).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct TopResultCard: View {
    @ObservedObject private var player = MusicPlayer.shared
    let track: Track
    let onPlay: () -> Void
    @State private var hovering = false

    var body: some View {
        let isCurrent = player.current?.id == track.id
        VStack(alignment: .leading, spacing: 16) {
            ArtworkView(track: track, size: 92, radius: 6)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(track.title).font(.system(size: 30, weight: .bold)).lineLimit(2)
                    .foregroundStyle(isCurrent ? Color.spotifyGreen : SP.text)
                HStack(spacing: 6) {
                    Text("Bài hát").foregroundStyle(SP.subtext)
                    Text("•").foregroundStyle(SP.subtext)
                    Text(track.artist).fontWeight(.semibold).lineLimit(1)
                }
                .font(.system(size: 14))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? SP.elevatedHover : SP.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            SpotifyPlayButton(isPlaying: isCurrent && player.isPlaying, size: 48) {
                if isCurrent { player.toggle() } else { onPlay() }
            }
            .padding(20)
            .opacity(hovering || isCurrent ? 1 : 0)
            .offset(y: hovering || isCurrent ? 0 : 8)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
        .onTapGesture(count: 2, perform: onPlay)
    }
}

private struct ResultRow: View {
    @ObservedObject private var lib = MusicLibrary.shared
    @ObservedObject private var player = MusicPlayer.shared
    let track: Track
    let queue: [Track]
    @State private var hovering = false

    var body: some View {
        let isCurrent = player.current?.id == track.id
        let saved = lib.isSaved(track)
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(track: track, size: 40)
                if hovering || (isCurrent && player.isPlaying) {
                    Color.black.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 4))
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)
            .onTapGesture { isCurrent ? player.toggle() : player.play(queue, startAt: track.id) }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 15)).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.spotifyGreen : SP.text)
                Text(track.artist).font(.system(size: 13)).foregroundStyle(hovering ? SP.text : SP.subtext).lineLimit(1)
            }
            Spacer(minLength: 8)
            if track.isRemote {
                Button { lib.save(track) } label: {
                    Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(saved ? Spotify.green : SP.subtext)
                }
                .buttonStyle(PressScaleStyle(scale: 0.85))
                .disabled(saved)
                .opacity(hovering || saved ? 1 : 0)
                .help(saved ? "Đã lưu vào thư viện" : "Lưu vào thư viện (tải về máy)")
            }
            Text(formatTime(track.duration))
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(SP.subtext)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(hovering ? Spotify.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { player.play(queue, startAt: track.id) }
        .contextMenu {
            Button("Phát", systemImage: "play.fill") { player.play(queue, startAt: track.id) }
            if track.isRemote && !saved {
                Button("Lưu vào thư viện", systemImage: "arrow.down.circle") { lib.save(track) }
            }
            if let s = track.source, let url = URL(string: s) {
                Button("Mở trên \(track.catalog ?? "web")", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

// MARK: - Khung "Đang phát" bên phải

private struct NowPlayingPanel: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var lyrics = LyricsStore.shared

    var body: some View {
        let t = player.current
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(t?.title ?? "").font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Spacer()
                    HoverCircle(symbol: "xmark", size: 28) { player.showNowPlaying = false }
                        .help("Ẩn khung đang phát")
                }

                ArtworkView(track: t, size: 268, radius: 8)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t?.title ?? "").font(.system(size: 22, weight: .bold)).lineLimit(2)
                        Text(t?.artist ?? "").font(.system(size: 15)).foregroundStyle(SP.subtext).lineLimit(1)
                    }
                    Spacer()
                    if let t {
                        Menu {
                            AddToPlaylistMenu(trackID: t.id, title: t.title)
                        } label: {
                            Image(systemName: "plus.circle").font(.system(size: 20)).foregroundStyle(SP.subtext)
                        }
                        .menuStyle(.button)
                    .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Thêm vào playlist")
                    }
                }

                lyricsCard(t)
                queueCard
            }
            .padding(16)
        }
        .task(id: t?.id) {
            if let t, lyrics.trackID != t.id { lyrics.load(t) }
        }
    }

    @ViewBuilder
    private func lyricsCard(_ t: Track?) -> some View {
        let bg = ArtColor.color(for: t) ?? Color(white: 0.35)
        if case .found(let lines, let synced, _) = lyrics.state, lyrics.trackID == t?.id, !lines.isEmpty {
            let cur = synced ? lines.lastIndex { ($0.time ?? 0) <= player.time + 0.2 } ?? 0 : 0
            let preview = Array(lines[cur..<min(cur + 4, lines.count)])
            Button { withAnimation(Spotify.spring) { player.showLyrics = true } } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Xem trước lời bài hát").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preview) { line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(line.id == lines[cur].id ? Color.white : Color.black.opacity(0.75))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: cur)
                    Text("Hiện lời bài hát")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
        }
    }

    @ViewBuilder
    private var queueCard: some View {
        let next = Array(player.upNext.prefix(6))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tiếp theo trong danh sách chờ").font(.system(size: 15, weight: .bold))
                ForEach(next, id: \.index) { item in
                    QueueRow(track: item.track) { player.playQueueItem(at: item.index) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SP.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct QueueRow: View {
    let track: Track
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    ArtworkView(track: track, size: 44)
                    if hovering {
                        Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 4))
                        Image(systemName: "play.fill").foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 14)).foregroundStyle(SP.text).lineLimit(1)
                    Text(track.artist).font(.system(size: 12)).foregroundStyle(SP.subtext).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(hovering ? Spotify.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Sheets

private struct RenamePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tên playlist").font(.headline)
            TextField("Tên", text: $playlist.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(playlist.name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func save() {
        let lib = MusicLibrary.shared
        if let i = lib.playlists.firstIndex(where: { $0.id == playlist.id }) { lib.playlists[i].name = playlist.name.trimmed }
        dismiss()
    }
}

private struct EditTrackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var title = ""
    @State private var artist = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 56)
                Text("Sửa thông tin bài hát").font(.headline)
            }
            TextField("Tên bài", text: $title).textFieldStyle(.roundedBorder)
            TextField("Nghệ sĩ", text: $artist).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") {
                    MusicLibrary.shared.rename(track.id, title: title, artist: artist)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { title = track.title; artist = track.artist }
    }
}

// MARK: - Thanh phát dưới cùng

struct MiniPlayer: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var player = MusicPlayer.shared
    @State private var scrub: Double?
    @State private var hoverTitle = false
    @State private var lastVolume: Float = 0.8

    private var onMusic: Bool { store.selection == .music }

    var body: some View {
        let t = player.current
        HStack(spacing: 16) {
            // Trái
            HStack(spacing: 12) {
                ArtworkView(track: t, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t?.title ?? "")
                        .font(.system(size: 14))
                        .foregroundStyle(SP.text)
                        .underline(hoverTitle)
                        .lineLimit(1)
                    Text(t?.artist ?? "").font(.system(size: 12)).foregroundStyle(SP.subtext).lineLimit(1)
                }
                .onHover { hoverTitle = $0 }
                .onTapGesture { store.selection = .music; player.showLyrics = false }
                if let t {
                    Menu {
                        AddToPlaylistMenu(trackID: t.id, title: t.title)
                    } label: {
                        Image(systemName: "plus.circle").font(.system(size: 16)).foregroundStyle(SP.subtext)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Thêm vào playlist")
                }
            }
            .frame(minWidth: 180, maxWidth: 300, alignment: .leading)

            Spacer(minLength: 0)

            // Giữa
            VStack(spacing: 4) {
                HStack(spacing: 14) {
                    SpotifyIconButton(symbol: "shuffle", active: player.shuffle, size: 15, help: "Phát ngẫu nhiên") { player.shuffle.toggle() }
                    SpotifyIconButton(symbol: "backward.end.fill", size: 16, help: "Bài trước") { player.previous() }
                    MiniPlayButton()
                    SpotifyIconButton(symbol: "forward.end.fill", size: 16, help: "Bài tiếp") { player.next() }
                    SpotifyIconButton(symbol: player.repeatMode == .one ? "repeat.1" : "repeat",
                                      active: player.repeatMode != .off, size: 15, help: "Lặp lại") { player.cycleRepeat() }
                }
                HStack(spacing: 8) {
                    Text(formatTime(scrub ?? player.time)).frame(width: 40, alignment: .trailing)
                    SpotifyBar(value: player.duration > 0 ? (scrub ?? player.time) / player.duration : 0,
                               onChanged: { scrub = $0 * player.duration },
                               onCommit: { player.seek(to: $0 * player.duration); scrub = nil })
                    Text(formatTime(player.duration)).frame(width: 40, alignment: .leading)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(SP.subtext)
            }
            .frame(maxWidth: 620)

            Spacer(minLength: 0)

            // Phải
            HStack(spacing: 2) {
                SpotifyIconButton(symbol: "music.mic", active: player.showLyrics && onMusic, size: 15, help: "Lời bài hát") {
                    withAnimation(Spotify.spring) {
                        if onMusic { player.showLyrics.toggle() } else { store.selection = .music; player.showLyrics = true }
                    }
                }
                SpotifyIconButton(symbol: "play.rectangle", active: player.showNowPlaying && onMusic,
                                  size: 15, help: "Khung đang phát") {
                    withAnimation(Spotify.spring) {
                        if onMusic { player.showNowPlaying.toggle() } else { store.selection = .music; player.showNowPlaying = true }
                    }
                }
                SpotifyIconButton(symbol: volumeSymbol, size: 15, help: "Tắt/bật tiếng") { toggleMute() }
                SpotifyBar(value: Double(player.volume),
                           onChanged: { player.volume = Float($0) },
                           onCommit: { player.volume = Float($0) })
                    .frame(width: 93)
            }
            .frame(minWidth: 180, maxWidth: 300, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(SP.bar)
    }

    private var volumeSymbol: String {
        switch player.volume {
        case 0: "speaker.slash"
        case ..<0.34: "speaker.wave.1"
        case ..<0.67: "speaker.wave.2"
        default: "speaker.wave.3"
        }
    }

    private func toggleMute() {
        if player.volume > 0 { lastVolume = player.volume; player.volume = 0 } else { player.volume = max(lastVolume, 0.2) }
    }
}

/// Nút play tròn của thanh phát: nền trắng/đen theo giao diện, rê chuột phóng to.
private struct MiniPlayButton: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var hovering = false

    var body: some View {
        Button(action: player.toggle) {
            Group {
                if player.isResolving {
                    ProgressView().controlSize(.small).tint(SP.bar)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SP.bar)
                        .offset(x: player.isPlaying ? 0 : 1)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
                .frame(width: 34, height: 34)
                .background(SP.text, in: Circle())
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(Spotify.quick) { hovering = h } }
        .keyboardShortcut(.space, modifiers: .option)
        .help(player.isPlaying ? "Tạm dừng (⌥Space)" : "Phát (⌥Space)")
    }
}
