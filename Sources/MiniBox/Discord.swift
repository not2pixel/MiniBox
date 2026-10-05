import AppKit
import Darwin
import SwiftUI

// MARK: - Kết nối Discord qua IPC cục bộ ($TMPDIR/discord-ipc-N)

/// Giao thức: mỗi gói = opcode (Int32 LE) + độ dài (Int32 LE) + JSON.
/// op 0 = handshake, op 1 = frame (lệnh), op 2 = close.
final class DiscordIPC {
    private var fd: Int32 = -1
    private(set) var connected = false

    deinit { close() }

    func connect(clientID: String) -> Bool {
        close()
        let dirs = [ProcessInfo.processInfo.environment["TMPDIR"], NSTemporaryDirectory(), "/tmp/"].compactMap { $0 }
        for dir in dirs {
            for i in 0..<10 {
                let path = (dir as NSString).appendingPathComponent("discord-ipc-\(i)")
                guard FileManager.default.fileExists(atPath: path), open(path) else { continue }
                if handshake(clientID) { connected = true; return true }
                close()
            }
        }
        return false
    }

    private func open(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { Darwin.close(s); return false }
        fd = s
        return true
    }

    private func handshake(_ clientID: String) -> Bool {
        guard send(op: 0, ["v": 1, "client_id": clientID]),
              let reply = receive(), (reply["evt"] as? String) == "READY" else { return false }
        return true
    }

    /// nil = xoá trạng thái.
    @discardableResult
    func setActivity(_ activity: [String: Any]?) -> Bool {
        let ok = send(op: 1, [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(getpid()), "activity": activity ?? NSNull()] as [String: Any],
            "nonce": UUID().uuidString,
        ])
        if ok { _ = receive() } else { close() }
        return ok
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        connected = false
    }

    private func send(op: Int32, _ payload: [String: Any]) -> Bool {
        guard fd >= 0, let json = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var packet = Data()
        withUnsafeBytes(of: op.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(json.count).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(json)
        let written = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, packet.count) }
        return written == packet.count
    }

    private func receive() -> [String: Any]? {
        guard fd >= 0 else { return nil }
        var header = [UInt8](repeating: 0, count: 8)
        guard Darwin.read(fd, &header, 8) == 8 else { return nil }
        let length = Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
        guard length > 0, length < 1 << 20 else { return nil }
        var body = [UInt8](repeating: 0, count: length)
        var got = 0
        while got < length {
            let n = body.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, length - got) }
            if n <= 0 { return nil }
            got += n
        }
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }
}

// MARK: - Trạng thái hiển thị trên Discord

@MainActor
final class Presence: ObservableObject {
    static let shared = Presence()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "rpcEnabled"); restart() } }
    @Published var appID: String { didSet { d.set(appID, forKey: "rpcAppID"); restart() } }
    @Published var showMusic: Bool { didSet { d.set(showMusic, forKey: "rpcMusic"); push() } }
    @Published var showGames: Bool { didSet { d.set(showGames, forKey: "rpcGames"); push() } }
    @Published var showActivity: Bool { didSet { d.set(showActivity, forKey: "rpcActivity"); push() } }
    @Published var showTitles: Bool { didSet { d.set(showTitles, forKey: "rpcTitles"); push() } }
    @Published private(set) var status = "Chưa bật"
    @Published private(set) var preview: (details: String, state: String)?

    private let ipc = DiscordIPC()
    private let queue = DispatchQueue(label: "minibox.discord")
    private var ticker: Timer?
    private var lastKey = ""
    private var lastSent = Date.distantPast
    private let sessionStart = Date()
    private weak var store: Store?
    private weak var timer: FocusTimer?

    private init() {
        enabled = d.bool(forKey: "rpcEnabled")
        appID = d.string(forKey: "rpcAppID") ?? ""
        showMusic = d.object(forKey: "rpcMusic") as? Bool ?? true
        showGames = d.object(forKey: "rpcGames") as? Bool ?? true
        showActivity = d.object(forKey: "rpcActivity") as? Bool ?? true
        showTitles = d.bool(forKey: "rpcTitles")
    }

    func attach(store: Store, timer: FocusTimer) {
        self.store = store
        self.timer = timer
        restart()
    }

    private func restart() {
        ticker?.invalidate()
        lastKey = ""
        let clear = !enabled || appID.trimmed.isEmpty
        queue.async { [ipc] in
            if ipc.connected { ipc.setActivity(nil) }
            if clear { ipc.close() }
        }
        guard !clear else { status = enabled ? "Chưa nhập Application ID" : "Chưa bật"; preview = nil; return }
        status = "Đang kết nối…"
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        push()
    }

    /// Gửi trạng thái mới nếu có thay đổi (Discord giới hạn ~5 lần / 20 giây).
    func push() {
        guard enabled, !appID.trimmed.isEmpty else { return }
        let activity = buildActivity()
        let details = activity["details"] as? String ?? ""
        let state = activity["state"] as? String ?? ""
        preview = (details, state)
        let ts = activity["timestamps"] as? [String: Int]
        let key = "\(details)|\(state)|\(activity["type"] ?? 0)|\((ts?["start"] ?? 0) / 10)|\((ts?["end"] ?? 0) / 10)"
        let now = Date()
        guard key != lastKey || now.timeIntervalSince(lastSent) > 60, now.timeIntervalSince(lastSent) > 4 else { return }
        lastKey = key
        lastSent = now

        let id = appID.trimmed
        queue.async { [weak self, ipc] in
            if !ipc.connected { _ = ipc.connect(clientID: id) }
            let ok = ipc.connected && ipc.setActivity(activity)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.status = ok ? "Đã kết nối" : "Không thấy Discord — hãy mở app Discord"
                    if !ok { self?.lastKey = "" }
                }
            }
        }
    }

    private func buildActivity() -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970)
        var a: [String: Any] = [:]
        var assets: [String: Any] = ["large_image": "logo", "large_text": "MiniBox"]

        let player = MusicPlayer.shared
        let games = GameBox.shared

        if showGames, let game = games.activeGame, let s = games.session {
            a["type"] = 0
            a["details"] = "Đang chơi \(game.name)"
            a["state"] = "Phiên chơi có hẹn giờ"
            a["timestamps"] = ["start": Int(s.start.timeIntervalSince1970), "end": Int(s.end.timeIntervalSince1970)]
        } else if showMusic, player.isPlaying, let t = player.current {
            a["type"] = 2 // Listening
            a["details"] = String(t.title.prefix(120))
            a["state"] = "của \(t.artist)".prefix(120).description
            let start = now - Int(player.time)
            a["timestamps"] = ["start": start, "end": start + Int(max(player.duration, t.duration))]
            if let art = t.artworkURL, art.hasPrefix("http") {
                assets["large_image"] = art
            } else {
                // Chưa có link ảnh công khai → tìm rồi cập nhật lại ngay.
                Task { [weak self] in
                    if await MusicLibrary.shared.publicArtworkURL(t) != nil { self?.lastKey = ""; self?.push() }
                }
            }
            assets["large_text"] = String(t.title.prefix(120))
            assets["small_image"] = "logo"
            assets["small_text"] = "MiniBox"
        } else if let timer, timer.isRunning {
            a["type"] = 0
            a["details"] = timer.phase == .focus ? "Đang tập trung" : "Đang nghỉ giải lao"
            a["state"] = "Pomodoro · \(timer.phase.title)"
            a["timestamps"] = ["end": now + Int(timer.remaining)]
        } else if showActivity {
            a["type"] = 0
            let (details, state) = describeSection()
            a["details"] = details
            if let state { a["state"] = state }
            a["timestamps"] = ["start": Int(sessionStart.timeIntervalSince1970)]
        } else {
            a["type"] = 0
            a["details"] = "Đang dùng MiniBox"
        }
        a["assets"] = assets
        return a
    }

    private func describeSection() -> (String, String?) {
        guard let store else { return ("Đang dùng MiniBox", nil) }
        let title: (String?) -> String? = { [showTitles] s in showTitles ? s.map { String($0.prefix(100)) } : nil }
        switch store.selection ?? .all {
        case .quiz:
            return ("Đang làm trắc nghiệm", title(store.quizzes.first { $0.id == store.selectedQuizID }?.title))
        case .ai:
            return ("Đang hỏi \(AISettings.shared.current.name)", nil)
        case .storage:
            return ("Đang xem tài liệu", title(StorageModel.shared.selection?.lastPathComponent))
        case .gamebox:
            return ("Đang chọn game", nil)
        case .music:
            return ("Đang chọn nhạc", nil)
        case .timetable:
            let now = TT.nowMinutes
            if let c = store.timetable.first(where: { $0.weekday == TT.today && !$0.isRest && $0.start <= now && now < $0.end }) {
                return ("Đang học", title(c.title.isEmpty ? "Tiết học" : c.title))
            }
            return ("Đang xem thời khoá biểu", nil)
        case .focus:
            return ("Chuẩn bị tập trung", "Pomodoro")
        default:
            let note = store.notes.first { $0.id == store.selectedNoteID }
            return ("Đang ghi chú", title(note?.displayTitle))
        }
    }
}
