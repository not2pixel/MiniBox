import AppKit
import AVFoundation
import MediaPlayer
import SwiftUI

// MARK: - Model

struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var artist: String
    var duration: Double = 0
    var file: String
    var artwork: String?
    var source: String?
    var addedAt = Date()
    /// Bài từ kho nhạc online (chưa lưu về máy): phát trực tiếp từ link này.
    var remoteURL: String?
    /// Ảnh bìa trên mạng (dùng cho bài online và Discord).
    var artworkURL: String?
    /// Tên kho nhạc (YouTube Music, SoundCloud…).
    var catalog: String?

    var isRemote: Bool { file.isEmpty && remoteURL != nil }

    var sourceHost: String? {
        guard let s = source, let host = URL(string: s)?.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "")
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var createdAt = Date()
}

struct DownloadJob: Identifiable {
    enum Status { case fetching, downloading, converting, failed }
    let id = UUID()
    let link: String
    var title: String
    var progress: Double = 0
    var status: Status = .fetching
    var error: String?
}

enum MusicError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Library

@MainActor
final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()

    enum ToolState: Equatable { case missing, installing(Double), ready }

    let dir: URL
    let tracksDir: URL
    let artDir: URL
    let binDir: URL
    private let indexURL: URL

    @Published var tracks: [Track] = [] { didSet { save() } }
    @Published var playlists: [Playlist] = [] { didSet { save() } }
    @Published var jobs: [DownloadJob] = []
    @Published private(set) var toolState: ToolState = .missing
    @Published var message: String?

    private var artCache: [String: NSImage] = [:]
    /// Bài online đang nằm trong hàng đợi (không lưu vào thư viện).
    private var transient: [UUID: Track] = [:]

    private var resolved: [String: (url: URL, headers: [String: String], at: Date)] = [:]

    /// Link phát thật của bài cần yt-dlp (SoundCloud…). Lưu 20 phút vì link có hạn.
    func resolveStream(_ t: Track) async -> URL? { await streamInfo(t)?.url }

    /// Link phát thật + HTTP header cần gửi kèm (link YouTube chỉ mở được với đúng User-Agent yt-dlp đã dùng).
    func streamInfo(_ t: Track) async -> (url: URL, headers: [String: String])? {
        guard let r = t.remoteURL else { return nil }
        if let c = resolved[r], Date().timeIntervalSince(c.at) < 1200 { return (c.url, c.headers) }
        if r.hasPrefix("sc:") {
            guard let url = await SoundCloudAPI.shared.stream(String(r.dropFirst(3))) else { return nil }
            resolved[r] = (url, [:], .now)
            return (url, [:])
        }
        guard r.hasPrefix("ytdlp:") else { return URL(string: r).map { ($0, [:]) } }
        guard let tool = ytdlpPath() else { return nil }
        let fmt = "http_mp3_1_0/http_mp3_128/hls_mp3_1_0/hls_mp3_128/bestaudio[ext=mp3]/bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]"
        let lines = await Self.outputLines(tool, ["--no-warnings", "--no-playlist", "-f", fmt,
                                                   "--print", "%(url)s", "--print", "%(http_headers)j", String(r.dropFirst(6))])
        guard let first = lines.first, let url = URL(string: first) else { return nil }
        let headers = lines.count > 1
            ? ((try? JSONSerialization.jsonObject(with: Data(lines[1].utf8))) as? [String: String] ?? [:]) : [:]
        resolved[r] = (url, headers, .now)
        return (url, headers)
    }

    nonisolated static func outputLines(_ tool: String, _ args: [String]) async -> [String] {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: text.split(separator: "\n").map(String.init))
            }
            do { try p.run() } catch { cont.resume(returning: []) }
        }
    }

    nonisolated static func firstLine(_ tool: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: text.split(separator: "\n").first.map(String.init))
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }

    /// Ảnh thumbnail công khai của video YouTube (luôn tồn tại bản hqdefault).
    nonisolated static func youTubeThumb(_ source: String?) -> String? {
        guard let s = source, let u = URL(string: s), let host = u.host?.lowercased() else { return nil }
        var id: String?
        if host.hasSuffix("youtu.be") {
            id = u.pathComponents.dropFirst().first
        } else if host.contains("youtube.com") {
            if let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
                id = v
            } else if let i = u.pathComponents.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }),
                      i + 1 < u.pathComponents.count {
                id = u.pathComponents[i + 1]
            }
        }
        guard let id, id.count >= 6, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }

    private var artworkLookups = Set<UUID>()

    /// Link ảnh bìa công khai (cho Discord). Bài trên máy không có link → tìm ảnh bìa trên iTunes theo tên + nghệ sĩ.
    func publicArtworkURL(_ t: Track) async -> String? {
        if let u = t.artworkURL, u.hasPrefix("http") { return u }
        if let yt = Self.youTubeThumb(t.source) { setArtworkURL(t.id, yt); return yt }
        guard !artworkLookups.contains(t.id) else { return nil }
        artworkLookups.insert(t.id)
        let terms = LyricsStore.searchTerms(for: t)
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(terms.artist) \(terms.title)"), .init(name: "media", value: "music"),
                        .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["results"] as? [[String: Any]])?.first,
              let art = (first["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "512x512bb")
        else { return nil }
        setArtworkURL(t.id, art)
        return art
    }

    private func setArtworkURL(_ id: UUID, _ url: String) {
        if let i = tracks.firstIndex(where: { $0.id == id }) { tracks[i].artworkURL = url }
        else if var t = transient[id] { t.artworkURL = url; transient[id] = t }
    }

    func remember(_ list: [Track]) { for t in list where t.isRemote { transient[t.id] = t } }

    private init() {
        let fm = FileManager.default
        dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MiniBox/Music", isDirectory: true)
        tracksDir = dir.appendingPathComponent("Tracks", isDirectory: true)
        artDir = dir.appendingPathComponent("Artwork", isDirectory: true)
        binDir = dir.appendingPathComponent("bin", isDirectory: true)
        indexURL = dir.appendingPathComponent("library.json")
        for d in [tracksDir, artDir, binDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }

        struct Snapshot: Codable { var tracks: [Track]; var playlists: [Playlist] }
        if let data = try? Data(contentsOf: indexURL), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            tracks = snap.tracks.filter { fm.fileExists(atPath: tracksDir.appendingPathComponent($0.file).path) }
            playlists = snap.playlists
        }
        toolState = ytdlpPath() == nil ? .missing : .ready
        repairDurations()
        warmUpTool()
        // Bài YouTube tải trước đây chưa có link ảnh công khai → suy ra từ ID video.
        for i in tracks.indices where tracks[i].artworkURL == nil {
            if let u = Self.youTubeThumb(tracks[i].source) { tracks[i].artworkURL = u }
        }
    }

    /// Sửa các bài đã tải trước đây bị sai thời lượng.
    private func repairDurations() {
        let items = tracks.filter { $0.file.lowercased().hasSuffix(".m4a") }.map { ($0.id, fileURL($0)) }
        guard !items.isEmpty else { return }
        Task {
            for (id, url) in items {
                await Self.fixDuration(url)
                let d = await Self.duration(of: url)
                if let i = tracks.firstIndex(where: { $0.id == id }), d > 0, abs(tracks[i].duration - d) > 0.5 {
                    tracks[i].duration = d
                }
            }
        }
    }

    private func save() {
        struct Snapshot: Codable { var tracks: [Track]; var playlists: [Playlist] }
        guard let data = try? JSONEncoder().encode(Snapshot(tracks: tracks, playlists: playlists)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: Lookups

    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } ?? transient[id] }
    func fileURL(_ t: Track) -> URL {
        if t.isRemote, let r = t.remoteURL, let u = URL(string: r) { return u }
        return tracksDir.appendingPathComponent(t.file)
    }

    /// Đã lưu bài online này về thư viện chưa (so theo link nguồn).
    func isSaved(_ t: Track) -> Bool { tracks.contains { $0.source != nil && $0.source == t.source } }

    /// Lưu bài online về máy để nghe offline.
    func save(_ remote: Track) {
        if remote.remoteURL?.hasPrefix("ytdlp:") == true, let page = remote.source {
            if !isSaved(remote) { importLink(page) }
            return
        }
        guard remote.isRemote, !isSaved(remote), let r = remote.remoteURL else { return }
        let job = DownloadJob(link: remote.source ?? r, title: "\(remote.title) — \(remote.artist)", status: .downloading)
        jobs.insert(job, at: 0)
        let jobID = job.id
        Task {
            do {
                guard let url = await resolveStream(remote) else { throw MusicError.message("Không lấy được link tải.") }
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                let mime = (resp as? HTTPURLResponse)?.mimeType ?? ""
                let ext = mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") ? "m4a" : "mp3"
                let stem = UUID().uuidString
                let dest = tracksDir.appendingPathComponent("\(stem).\(ext)")
                try FileManager.default.moveItem(at: tmp, to: dest)
                updateJob(jobID) { $0.status = .converting }
                let playable = try await Self.ensurePlayable(dest, stem: stem)
                let art = await saveArtwork(from: remote.artworkURL, name: stem)
                var t = remote
                t.id = UUID()
                t.file = playable.lastPathComponent
                t.remoteURL = nil
                t.artwork = art
                t.addedAt = .now
                t.duration = await Self.duration(of: playable)
                tracks.insert(t, at: 0)
                jobs.removeAll { $0.id == jobID }
            } catch {
                updateJob(jobID) { $0.status = .failed; $0.error = error.localizedDescription }
            }
        }
    }

    func artwork(_ t: Track?) -> NSImage? {
        guard let name = t?.artwork else { return RemoteArt.shared.image(t?.artworkURL) }
        if let img = artCache[name] { return img }
        guard let img = NSImage(contentsOf: artDir.appendingPathComponent(name)) else { return nil }
        artCache[name] = img
        return img
    }

    func tracks(in playlist: Playlist) -> [Track] { playlist.trackIDs.compactMap(track) }

    // MARK: Tools

    /// Bản yt-dlp dạng thư mục: giải nén 1 lần nên khởi động ~0.2s (bản 1 tệp mất ~7s mỗi lần).
    var ytdlpDirPath: String { binDir.appendingPathComponent("ytdlp/yt-dlp_macos").path }
    var ytdlpIsLegacy: Bool { !FileManager.default.isExecutableFile(atPath: ytdlpDirPath) && ytdlpPath() != nil }

    func ytdlpPath() -> String? {
        let candidates = [ytdlpDirPath, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", binDir.appendingPathComponent("yt-dlp").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Chạy thử 1 lần lúc mở app để macOS quét xong, lần dùng thật sẽ nhanh.
    func warmUpTool() {
        guard let tool = ytdlpPath() else { return }
        Task.detached(priority: .background) { _ = await Self.firstLine(tool, ["--version"]) }
    }

    func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Tải bản yt-dlp chính thức (GitHub) vào thư mục riêng của MiniBox.
    func installTool() {
        if case .installing = toolState { return }
        toolState = .installing(0)
        let src = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!
        let dest = binDir.appendingPathComponent("ytdlp")
        Task {
            do {
                let (tmp, response) = try await URLSession.shared.download(from: src)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.message("GitHub trả về lỗi.") }
                try? FileManager.default.removeItem(at: dest)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", tmp.path, dest.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: ytdlpDirPath) else {
                    throw MusicError.message("Giải nén yt-dlp không thành công.")
                }
                try? FileManager.default.removeItem(at: binDir.appendingPathComponent("yt-dlp")) // bản 1 tệp cũ
                toolState = .ready
                warmUpTool()
            } catch {
                toolState = .missing
                message = "Không cài được yt-dlp: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Import from link

    func importLink(_ raw: String) {
        let link = raw.trimmed
        guard let url = URL(string: link), let host = url.host, url.scheme?.hasPrefix("http") == true else {
            message = "Link không hợp lệ."
            return
        }
        guard let tool = ytdlpPath() else {
            message = "Cần cài yt-dlp trước khi tải từ link."
            return
        }
        if host.contains("spotify.com"), !url.path.contains("/track/") {
            message = "Hiện chỉ hỗ trợ link một bài hát Spotify (open.spotify.com/track/…)."
            return
        }

        let job = DownloadJob(link: link, title: link)
        jobs.insert(job, at: 0)
        let jobID = job.id
        let ffmpeg = ffmpegPath()
        let tracksDir = tracksDir

        Task {
            do {
                var target = link
                var meta: (title: String, artist: String, image: String?)?
                if host.contains("spotify.com") {
                    guard let info = await Self.spotifyInfo(url) else {
                        throw MusicError.message("Không đọc được thông tin bài hát từ Spotify.")
                    }
                    meta = info
                    updateJob(jobID) { $0.title = "\(info.title) — \(info.artist)" }
                    // Nhạc Spotify có DRM: tìm bản tương ứng trên YouTube.
                    target = "ytsearch1:\(info.artist) - \(info.title) audio"
                }

                let stem = UUID().uuidString
                var args = ["--no-playlist", "--no-warnings", "--dump-json", "--no-simulate", "--progress", "--newline",
                            "--progress-template", "download:NOTER %(progress._percent_str)s",
                            "-o", tracksDir.appendingPathComponent("\(stem).%(ext)s").path]
                if let ffmpeg {
                    args += ["-f", "bestaudio/best", "-x", "--audio-format", "m4a", "--ffmpeg-location", ffmpeg]
                } else {
                    args += ["-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio[ext=mp3]/best[ext=mp4]/best"]
                }
                args.append(target)

                updateJob(jobID) { $0.status = .downloading }
                let info = try await Self.run(tool, args) { [weak self] p in
                    Task { @MainActor in self?.updateJob(jobID) { $0.progress = p } }
                }

                let title = meta?.title ?? (info["track"] as? String) ?? (info["title"] as? String) ?? "Không tên"
                let artist = meta?.artist ?? (info["artist"] as? String) ?? (info["uploader"] as? String)
                    ?? (info["channel"] as? String) ?? "Không rõ"
                updateJob(jobID) { $0.title = "\(title) — \(artist)"; $0.status = .converting }

                guard var file = try FileManager.default.contentsOfDirectory(atPath: tracksDir.path).first(where: { $0.hasPrefix(stem + ".") })
                else { throw MusicError.message("Không tìm thấy tệp đã tải.") }
                file = try await Self.ensurePlayable(tracksDir.appendingPathComponent(file), stem: stem).lastPathComponent

                let duration = await Self.duration(of: tracksDir.appendingPathComponent(file))
                let thumb = meta?.image ?? (info["thumbnail"] as? String)
                let art = await saveArtwork(from: thumb, name: stem)
                var track = Track(title: title, artist: artist, duration: duration, file: file, artwork: art, source: link)
                track.artworkURL = thumb
                tracks.insert(track, at: 0)
                jobs.removeAll { $0.id == jobID }
            } catch {
                updateJob(jobID) { $0.status = .failed; $0.error = error.localizedDescription }
            }
        }
    }

    private func updateJob(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    func dismissJob(_ id: UUID) { jobs.removeAll { $0.id == id } }

    func retry(_ job: DownloadJob) {
        dismissJob(job.id)
        importLink(job.link)
    }

    private func saveArtwork(from urlString: String?, name: String) async -> String? {
        guard let s = urlString, let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url),
              NSImage(data: data) != nil else { return nil }
        let file = "\(name).img"
        try? data.write(to: artDir.appendingPathComponent(file))
        return file
    }

    // MARK: Import local files

    func importFiles(_ urls: [URL]) {
        Task {
            for src in urls {
                let stem = UUID().uuidString
                let dest = tracksDir.appendingPathComponent("\(stem).\(src.pathExtension.lowercased())")
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                    let playable = try await Self.ensurePlayable(dest, stem: stem)
                    let asset = AVURLAsset(url: playable)
                    let items = (try? await asset.load(.commonMetadata)) ?? []
                    func string(_ key: AVMetadataKey) async -> String? {
                        guard let item = items.first(where: { $0.commonKey == key }) else { return nil }
                        return try? await item.load(.stringValue)
                    }
                    let title = await string(.commonKeyTitle) ?? src.deletingPathExtension().lastPathComponent
                    let artist = await string(.commonKeyArtist) ?? "Không rõ"
                    var art: String?
                    if let item = items.first(where: { $0.commonKey == .commonKeyArtwork }),
                       let data = try? await item.load(.dataValue), NSImage(data: data) != nil {
                        art = "\(stem).img"
                        try? data.write(to: artDir.appendingPathComponent(art!))
                    }
                    let duration = await Self.duration(of: playable)
                    tracks.insert(Track(title: title, artist: artist, duration: duration,
                                        file: playable.lastPathComponent, artwork: art), at: 0)
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                    message = "Không nhập được \(src.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.prompt = "Thêm vào Phát nhạc"
        panel.begin { [weak self] in
            if $0 == .OK { self?.importFiles(panel.urls) }
        }
    }

    // MARK: Editing

    func delete(_ id: UUID) {
        guard let t = track(id) else { return }
        MusicPlayer.shared.removeFromQueue(id)
        try? FileManager.default.removeItem(at: fileURL(t))
        if let art = t.artwork { try? FileManager.default.removeItem(at: artDir.appendingPathComponent(art)) }
        tracks.removeAll { $0.id == id }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { $0 == id } }
    }

    func rename(_ id: UUID, title: String, artist: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        if !title.trimmed.isEmpty { tracks[i].title = title.trimmed }
        if !artist.trimmed.isEmpty { tracks[i].artist = artist.trimmed }
    }

    @discardableResult
    func newPlaylist(_ name: String = "Playlist mới") -> UUID {
        let p = Playlist(name: name)
        playlists.append(p)
        return p.id
    }

    func add(_ trackIDs: [UUID], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in trackIDs where !playlists[i].trackIDs.contains(id) { playlists[i].trackIDs.append(id) }
    }

    func remove(_ trackID: UUID, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { $0 == trackID }
    }

    func movePlaylistTracks(_ playlistID: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to)
    }

    // MARK: Helpers (chạy ngoài main thread)

    /// Chạy yt-dlp, trả về JSON thông tin bài; báo tiến độ 0…1.
    nonisolated static func run(_ tool: String, _ args: [String],
                                progress: @escaping @Sendable (Double) -> Void) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err

            /// Bộ đệm dùng chung giữa các luồng đọc (có khoá).
            final class State: @unchecked Sendable {
                let lock = NSLock()
                var buffer = ""
                var json: [String: Any]?
                var errText = ""

                func feed(_ chunk: String, progress: (Double) -> Void, flush: Bool = false) {
                    lock.lock()
                    buffer += chunk
                    var lines = buffer.components(separatedBy: "\n")
                    buffer = flush ? "" : lines.removeLast()
                    lock.unlock()
                    for line in lines {
                        if line.hasPrefix("NOTER ") {
                            let pct = Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: "%", with: "")) ?? 0
                            progress(min(1, pct / 100))
                        } else if line.hasPrefix("{"), let d = line.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            lock.lock(); json = obj; lock.unlock()
                        }
                    }
                }
            }
            let state = State()

            out.fileHandleForReading.readabilityHandler = { h in
                state.feed(String(decoding: h.availableData, as: UTF8.self), progress: progress)
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let chunk = String(decoding: h.availableData, as: UTF8.self)
                state.lock.lock(); state.errText += chunk; state.lock.unlock()
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // Đọc nốt phần chưa kịp xử lý.
                let rest = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                state.feed(rest, progress: progress, flush: true)
                let restErr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                state.lock.lock(); state.errText += restErr
                let j = state.json; let e = state.errText; state.lock.unlock()
                if proc.terminationStatus == 0, let j {
                    cont.resume(returning: j)
                } else {
                    let msg = e.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? e.trimmed
                    cont.resume(throwing: MusicError.message(msg.isEmpty ? "yt-dlp lỗi (mã \(proc.terminationStatus))." : msg))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Tệp video (mp4/mov) → tách âm thanh ra m4a bằng AVFoundation.
    nonisolated static func ensurePlayable(_ url: URL, stem: String) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if ["m4a", "aac"].contains(ext) { await fixDuration(url); return url }
        if ["mp3", "wav", "aiff", "aif", "flac", "caf"].contains(ext) { return url }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else {
            try? FileManager.default.removeItem(at: url)
            throw MusicError.message("Định dạng .\(ext) không phát được. Cài ffmpeg (brew install ffmpeg) để MiniBox tự chuyển đổi.")
        }
        guard ["mp4", "m4v", "mov"].contains(ext),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return url }
        let out = url.deletingLastPathComponent().appendingPathComponent("\(stem).m4a")
        session.outputURL = out
        session.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        guard session.status == .completed else { return url }
        try? FileManager.default.removeItem(at: url)
        return out
    }

    nonisolated static func duration(of url: URL) async -> Double {
        if let real = realDuration(url) { return real }
        let d = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
        return d.isFinite ? d : 0
    }

    /// Độ dài thật = số khung âm thanh / tần số lấy mẫu (không tin phần đầu tệp).
    nonisolated static func realDuration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0, f.length > 0 else { return nil }
        let d = Double(f.length) / f.fileFormat.sampleRate
        return d.isFinite ? d : nil
    }

    /// m4a dạng DASH (YouTube, tải không có ffmpeg) ghi sai tổng thời lượng — thường gấp đôi.
    /// Đóng gói lại (không mã hoá lại, giữ nguyên chất lượng) với đúng độ dài thật.
    /// Trả về true nếu đã sửa.
    @discardableResult
    nonisolated static func fixDuration(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let real = realDuration(url),
              let reported = try? await asset.load(.duration).seconds, reported.isFinite,
              reported > real + 1,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".fix-\(UUID().uuidString).m4a")
        session.outputURL = tmp
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: real, preferredTimescale: 44100))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        guard session.status == .completed,
              let fixed = try? await AVURLAsset(url: tmp).load(.duration).seconds, abs(fixed - real) < 1 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return true
    }

    /// Đọc tên bài, nghệ sĩ, ảnh bìa từ trang open.spotify.com.
    nonisolated static func spotifyInfo(_ url: URL) async -> (title: String, artist: String, image: String?)? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ key: String) -> String? {
            for pattern in ["property=\"\(key)\" content=\"", "name=\"\(key)\" content=\""] {
                if let r = html.range(of: pattern), let end = html[r.upperBound...].firstIndex(of: "\"") {
                    return decodeEntities(String(html[r.upperBound..<end]))
                }
            }
            return nil
        }
        guard let title = meta("og:title") else { return nil }
        var artist = meta("music:musician_description")
        if artist == nil, let desc = meta("og:description") {
            // "Artist · Song · 2020" hoặc "Listen to … on Spotify. Song · Artist · 2020"
            let parts = desc.components(separatedBy: " · ")
            artist = parts.count >= 3 ? (parts[0].contains("Spotify") ? parts[1] : parts[0]) : parts.first
        }
        return (title, artist ?? "", meta("og:image"))
    }

    nonisolated private static func decodeEntities(_ s: String) -> String {
        var r = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }
}

// MARK: - Player

@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    enum RepeatMode { case off, all, one }

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var showLyrics = false
    /// Nghe gần đây (mới nhất trước) — dùng cho trang chủ & gợi ý.
    @Published private(set) var history: [Track] = UserDefaults.standard.data(forKey: "musicHistory")
        .flatMap { try? JSONDecoder().decode([Track].self, from: $0) } ?? []

    private func addToHistory(_ t: Track) {
        history.removeAll { $0.id == t.id || ($0.source != nil && $0.source == t.source) }
        history.insert(t, at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "musicHistory")
    }
    /// Đang lấy link phát (SoundCloud…).
    @Published private(set) var isResolving = false
    @Published var showNowPlaying: Bool = UserDefaults.standard.object(forKey: "musicNowPlaying") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNowPlaying, forKey: "musicNowPlaying") }
    }

    /// Các bài tiếp theo trong hàng đợi.
    var upNext: [(index: Int, track: Track)] {
        guard !queue.isEmpty else { return [] }
        return queue.indices.filter { $0 > index }.compactMap { i in
            MusicLibrary.shared.track(queue[i]).map { (i, $0) }
        }
    }

    func playQueueItem(at i: Int) { load(at: i, autoplay: true) }
    @Published var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "musicVolume")
        }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {
        volume = UserDefaults.standard.object(forKey: "musicVolume") as? Float ?? 0.8
        player.volume = volume
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                let known = self.current?.duration ?? 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    // Luồng m4a dạng DASH có thể báo gấp đôi — tin thời lượng từ kho nhạc nếu có.
                    self.duration = known > 0 && d > known * 1.3 ? known : d
                }
                if self.isPlaying, known > 0, self.current?.isRemote == true, self.time >= known - 0.3,
                   (self.player.currentItem?.duration.seconds ?? 0) > known * 1.3 {
                    self.trackEnded()
                }
                self.updateNowPlaying()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.trackEnded()
            }
        }
        setupRemoteCommands()
    }

    var current: Track? { queue.indices.contains(index) ? MusicLibrary.shared.track(queue[index]) : nil }

    // MARK: Controls

    func play(_ tracks: [Track], startAt id: UUID? = nil) {
        guard !tracks.isEmpty else { return }
        MusicLibrary.shared.remember(tracks)
        var ids = tracks.map(\.id)
        var start = id.flatMap { ids.firstIndex(of: $0) } ?? 0
        if shuffle {
            let first = ids.remove(at: start)
            ids.shuffle()
            ids.insert(first, at: 0)
            start = 0
        }
        queue = ids
        load(at: start, autoplay: true)
    }

    func toggle() {
        guard current != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { load(at: index + 1, autoplay: true) }
        else if repeatMode == .all { load(at: 0, autoplay: true) }
        else { player.pause(); isPlaying = false; seek(to: 0) }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if time > 3 || index == 0 { seek(to: 0) } else { load(at: index - 1, autoplay: isPlaying) }
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        time = t
        updateNowPlaying()
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    func removeFromQueue(_ id: UUID) {
        guard let i = queue.firstIndex(of: id) else { return }
        let wasCurrent = i == index
        queue.remove(at: i)
        if i < index { index -= 1 }
        if wasCurrent {
            if queue.isEmpty { stop() } else { load(at: min(index, queue.count - 1), autoplay: isPlaying) }
        }
    }

    func stop() {
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        isPlaying = false
        time = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func load(at i: Int, autoplay: Bool) {
        guard queue.indices.contains(i) else { return }
        index = i
        guard let t = current else { removeFromQueue(queue[i]); return }
        if autoplay { addToHistory(t) }
        time = 0
        duration = t.duration
        isPlaying = autoplay
        if let r = t.remoteURL, r.hasPrefix("ytdlp:") || r.hasPrefix("sc:") {
            player.replaceCurrentItem(with: nil)
            isResolving = true
            updateNowPlaying()
            Task {
                let info = await MusicLibrary.shared.streamInfo(t)
                guard queue.indices.contains(index), queue[index] == t.id else { return }
                isResolving = false
                guard let info else {
                    MusicLibrary.shared.message = "Không lấy được bài “\(t.title)” từ \(t.catalog ?? "nguồn")."
                    isPlaying = false
                    return
                }
                let asset = AVURLAsset(url: info.url, options: info.headers.isEmpty ? nil
                                       : ["AVURLAssetHTTPHeaderFieldsKey": info.headers])
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                if isPlaying { player.play() }
            }
            return
        }
        isResolving = false
        player.replaceCurrentItem(with: AVPlayerItem(url: MusicLibrary.shared.fileURL(t)))
        if autoplay { player.play() }
        updateNowPlaying()
    }

    private func trackEnded() {
        if repeatMode == .one { seek(to: 0); player.play() } else { next() }
    }

    // MARK: Now Playing (phím media, Trung tâm điều khiển)

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == false { self?.toggle() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == true { self?.toggle() } }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let img = MusicLibrary.shared.artwork(t) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
