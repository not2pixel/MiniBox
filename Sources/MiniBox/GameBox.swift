import AppKit
import SwiftUI

struct Game: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var bundleID: String
    /// Giới hạn mỗi ngày (phút), nil = không giới hạn.
    var dailyLimit: Int?
    var defaultMinutes = 30

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct GameSession: Codable, Equatable {
    var gameID: UUID
    var start: Date
    var end: Date
}

/// Mở game theo phiên có giới hạn thời gian; hết giờ tự đóng game.
@MainActor
final class GameBox: ObservableObject {
    static let shared = GameBox()
    static let playCoverApps = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/io.playcover.PlayCover/Applications")

    @Published var games: [Game] { didSet { save() } }
    @Published private(set) var session: GameSession? { didSet { save() } }
    /// Chỉ cho mở game qua GameBox (mở ngoài sẽ bị đóng).
    @Published var guardMode: Bool { didSet { defaults.set(guardMode, forKey: "gbGuard") } }
    @Published private(set) var now = Date()
    @Published var message: String?

    private var usageDay = ""
    private var usage: [String: Int] = [:] // gameID → giây đã chơi hôm nay
    private var warned = false
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard

    private init() {
        games = defaults.data(forKey: "gbGames").flatMap { try? JSONDecoder().decode([Game].self, from: $0) } ?? []
        session = defaults.data(forKey: "gbSession").flatMap { try? JSONDecoder().decode(GameSession.self, from: $0) }
        guardMode = defaults.bool(forKey: "gbGuard")
        usageDay = defaults.string(forKey: "gbUsageDay") ?? ""
        usage = (defaults.dictionary(forKey: "gbUsage") as? [String: Int]) ?? [:]
        rollDay()

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appLaunched(app) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appQuit(app) }
        })

        // Phiên còn dở từ lần trước (MiniBox bị tắt giữa chừng).
        if let s = session {
            if s.end <= .now { endSession(timeUp: true) } else { startTicker() }
        }
    }

    // MARK: Persistence

    private func save() {
        defaults.set(try? JSONEncoder().encode(games), forKey: "gbGames")
        defaults.set(session.flatMap { try? JSONEncoder().encode($0) }, forKey: "gbSession")
    }

    private var today: String { Date().formatted(.iso8601.year().month().day()) }

    private func rollDay() {
        if usageDay != today {
            usageDay = today
            usage = [:]
            saveUsage()
        }
    }

    private func saveUsage() {
        defaults.set(usageDay, forKey: "gbUsageDay")
        defaults.set(usage, forKey: "gbUsage")
    }

    // MARK: Queries

    func game(_ id: UUID?) -> Game? { games.first { $0.id == id } }
    var activeGame: Game? { game(session?.gameID) }

    var remaining: TimeInterval { max(0, (session?.end ?? now).timeIntervalSince(now)) }

    var remainingText: String {
        let s = Int(remaining.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Số phút đã chơi hôm nay (tính cả phiên đang chạy).
    func minutesToday(_ game: Game) -> Int {
        var secs = usage[game.id.uuidString] ?? 0
        if let s = session, s.gameID == game.id { secs += Int(now.timeIntervalSince(s.start)) }
        return secs / 60
    }

    var totalMinutesToday: Int { games.reduce(0) { $0 + minutesToday($1) } }

    func minutesLeftToday(_ game: Game) -> Int? {
        game.dailyLimit.map { max(0, $0 - minutesToday(game)) }
    }

    func icon(_ game: Game) -> NSImage { NSWorkspace.shared.icon(forFile: game.path) }

    /// Lý do không chơi được (nil = chơi được).
    func blockReason(_ game: Game) -> String? {
        if !game.exists { return "Không tìm thấy ứng dụng" }
        if session != nil { return "Đang có phiên chơi khác" }
        if let left = minutesLeftToday(game), left <= 0 { return "Hết giờ chơi hôm nay" }
        return nil
    }

    // MARK: Library

    func add(_ urls: [URL]) {
        var added = 0
        for url in urls where url.pathExtension == "app" {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            guard !games.contains(where: { $0.bundleID == id }) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            games.append(Game(name: name, path: url.path, bundleID: id))
            added += 1
        }
        if added == 0, !urls.isEmpty { message = "Không có game mới nào được thêm (có thể đã có trong Trò chơi)." }
    }

    func addWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Thêm vào Trò chơi"
        panel.begin { [weak self] in
            if $0 == .OK { self?.add(panel.urls) }
        }
    }

    /// Thêm các game đã cài bằng PlayCover.
    func scanPlayCover() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.playCoverApps, includingPropertiesForKeys: nil)) ?? []
        let apps = urls.filter { $0.pathExtension == "app" }
        if apps.isEmpty {
            message = "Không tìm thấy game PlayCover nào."
        } else {
            add(apps)
        }
    }

    func remove(_ id: UUID) {
        if session?.gameID == id { endSession(timeUp: false) }
        games.removeAll { $0.id == id }
    }

    func update(_ id: UUID, _ change: (inout Game) -> Void) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[i])
    }

    // MARK: Sessions

    func play(_ game: Game, minutes: Int) {
        if let reason = blockReason(game) { message = reason; return }
        var mins = minutes
        if let left = minutesLeftToday(game) { mins = min(mins, left) }
        guard mins > 0 else { return }

        rollDay()
        session = GameSession(gameID: game.id, start: .now, end: .now.addingTimeInterval(TimeInterval(mins * 60)))
        warned = false
        now = .now
        startTicker()

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: game.url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.message = "Không mở được \(game.name): \(error.localizedDescription)"
                self?.endSession(timeUp: false, closeGame: false)
            }
        }
    }

    func extend(minutes: Int = 5) {
        guard var s = session, let game = activeGame else { return }
        var add = minutes
        if let limit = game.dailyLimit {
            let used = (usage[game.id.uuidString] ?? 0) / 60
            let planned = Int(s.end.timeIntervalSince(s.start) / 60)
            add = min(add, max(0, limit - used - planned))
        }
        guard add > 0 else { message = "Đã chạm giới hạn chơi hôm nay."; return }
        s.end = s.end.addingTimeInterval(TimeInterval(add * 60))
        session = s
        if remaining > 60 { warned = false }
    }

    func stop() { endSession(timeUp: false) }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        now = .now
        guard let s = session, let game = activeGame else { return }
        let left = s.end.timeIntervalSince(now)
        if left <= 60, !warned {
            warned = true
            Notifier.shared.post("Còn 1 phút chơi \(game.name)", "Lưu game lại nhé — hết giờ MiniBox sẽ đóng game.")
            NSSound(named: "Ping")?.play()
        }
        if left <= 0 { endSession(timeUp: true) }
    }

    private func endSession(timeUp: Bool, closeGame: Bool = true) {
        ticker?.invalidate()
        ticker = nil
        guard let s = session else { return }
        let game = game(s.gameID)
        session = nil
        now = .now

        rollDay()
        let played = Int(min(Date.now, s.end).timeIntervalSince(s.start))
        usage[s.gameID.uuidString, default: 0] += max(0, played)
        saveUsage()

        guard let game else { return }
        if closeGame { quit(bundleID: game.bundleID) }
        if timeUp {
            Notifier.shared.post("Hết giờ chơi \(game.name)", "Phiên chơi đã kết thúc. Quay lại học thôi!")
            NSSound(named: "Glass")?.play()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Đóng game lịch sự, sau 10 giây vẫn chạy thì buộc đóng.
    func quit(bundleID: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        guard !apps.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
                .forEach { $0.forceTerminate() }
        }
    }

    // MARK: Workspace events

    private func appLaunched(_ app: NSRunningApplication?) {
        guard let id = app?.bundleIdentifier, let game = games.first(where: { $0.bundleID == id }) else { return }
        if session?.gameID == game.id { return }
        let overLimit = (minutesLeftToday(game) ?? 1) <= 0
        guard guardMode || overLimit else { return }
        app?.terminate()
        Notifier.shared.post("\(game.name) bị đóng",
                             overLimit ? "Hôm nay đã hết giờ chơi game này." : "Hãy mở game qua mục Trò chơi trong MiniBox để đặt giờ chơi.")
    }

    private func appQuit(_ app: NSRunningApplication?) {
        guard let id = app?.bundleIdentifier, let game = activeGame, game.bundleID == id else { return }
        endSession(timeUp: false, closeGame: false)
    }
}

// MARK: - Views

struct GameBoxView: View {
    @ObservedObject private var box = GameBox.shared
    @State private var launching: Game?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let game = box.activeGame, let s = box.session {
                    ActiveSessionCard(game: game, session: s)
                }

                if box.games.isEmpty {
                    ContentUnavailableView {
                        Label("Chưa có game nào", systemImage: "gamecontroller")
                    } description: {
                        Text("Thêm game để chơi theo phiên có giờ giấc. Hết giờ MiniBox sẽ tự đóng game.")
                    } actions: {
                        Button("Quét game PlayCover", action: box.scanPlayCover)
                        Button("Thêm ứng dụng…", action: box.addWithPanel)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 16)], spacing: 16) {
                        ForEach(box.games) { game in
                            GameCard(game: game) { launching = game }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color.pink.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
        )
        .navigationTitle("Trò chơi")
        .navigationSubtitle("Hôm nay đã chơi \(box.totalMinutesToday) phút")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Chọn ứng dụng…", systemImage: "app.badge.plus", action: box.addWithPanel)
                    Button("Quét game PlayCover", systemImage: "arrow.triangle.2.circlepath", action: box.scanPlayCover)
                } label: {
                    Label("Thêm game", systemImage: "plus")
                }
                .help("Thêm game")

                Button { showSettings.toggle() } label: {
                    Label("Tuỳ chỉnh", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    Form {
                        Toggle("Chỉ cho chơi qua MiniBox", isOn: $box.guardMode)
                        Text("Mở game theo cách khác (Launchpad, Dock…) sẽ bị đóng ngay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                    .frame(width: 320, height: 130)
                }
            }
        }
        .sheet(item: $launching) { PlaySheet(game: $0) }
        .alert("Trò chơi", isPresented: Binding(get: { box.message != nil }, set: { if !$0 { box.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(box.message ?? "")
        }
    }
}

private struct ActiveSessionCard: View {
    @ObservedObject private var box = GameBox.shared
    let game: Game
    let session: GameSession

    var body: some View {
        let total = session.end.timeIntervalSince(session.start)
        let progress = total > 0 ? 1 - box.remaining / total : 1
        let tint: Color = box.remaining <= 60 ? .red : .pink

        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                Image(nsImage: box.icon(game))
                    .resizable()
                    .frame(width: 56, height: 56)
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 4) {
                Text("Đang chơi \(game.name)")
                    .font(.headline)
                Text(box.remainingText)
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(countsDown: true))
                Text("Kết thúc lúc \(session.end.formatted(.dateTime.hour().minute().locale(.vi))) · MiniBox sẽ tự đóng game")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                Button { box.extend() } label: {
                    Label("Thêm 5 phút", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { box.stop() } label: {
                    Label("Kết thúc", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .fixedSize()
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct GameCard: View {
    @ObservedObject private var box = GameBox.shared
    let game: Game
    let onPlay: () -> Void
    @State private var hovering = false

    var body: some View {
        let reason = box.blockReason(game)
        let used = box.minutesToday(game)
        let playing = box.session?.gameID == game.id

        Button(action: onPlay) {
            VStack(spacing: 10) {
                Image(nsImage: box.icon(game))
                    .resizable()
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .overlay(alignment: .bottomTrailing) {
                        if reason != nil && !playing {
                            Image(systemName: "lock.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.red.gradient, in: Circle())
                        }
                    }

                Text(game.name)
                    .font(.headline)
                    .lineLimit(1)

                VStack(spacing: 4) {
                    if let limit = game.dailyLimit {
                        ProgressView(value: Double(min(used, limit)), total: Double(max(limit, 1)))
                            .tint(used >= limit ? .red : .pink)
                        Text("\(used)/\(limit) phút hôm nay")
                    } else {
                        Text(used > 0 ? "Hôm nay \(used) phút" : "Chưa chơi hôm nay")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(playing ? "Đang chơi" : reason ?? "Chơi \(game.defaultMinutes) phút")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(playing ? .pink : reason == nil ? Color.playBlue : .secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(playing ? Color.pink : hovering ? Color.primary.opacity(0.12) : .clear, lineWidth: 1.5)
            )
            .scaleEffect(hovering && reason == nil ? 1.02 : 1)
            .animation(.snappy, value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .onHover { hovering = $0 }
        .contextMenu {
            Menu("Giới hạn mỗi ngày") {
                Button("Không giới hạn") { box.update(game.id) { $0.dailyLimit = nil } }
                ForEach([30, 60, 90, 120, 180], id: \.self) { m in
                    Button("\(m) phút") { box.update(game.id) { $0.dailyLimit = m } }
                }
            }
            Menu("Thời lượng mặc định") {
                ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) phút") { box.update(game.id) { $0.defaultMinutes = m } }
                }
            }
            Divider()
            Button("Xoá khỏi Trò chơi", systemImage: "trash", role: .destructive) { box.remove(game.id) }
        }
    }
}

private struct PlaySheet: View {
    @ObservedObject private var box = GameBox.shared
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var minutes = 30

    var body: some View {
        let left = box.minutesLeftToday(game)

        VStack(spacing: 18) {
            Image(nsImage: box.icon(game))
                .resizable()
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            VStack(spacing: 4) {
                Text(game.name).font(.title2.bold())
                Text(left.map { "Hôm nay còn \($0) phút" } ?? "Không giới hạn mỗi ngày")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Thời lượng", selection: $minutes) {
                ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) phút").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Stepper("Tuỳ chỉnh: \(minutes) phút", value: $minutes, in: 5...240, step: 5)

            Label("Hết giờ MiniBox sẽ đóng game — nhớ lưu tiến trình trước nhé.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Huỷ") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    box.play(game, minutes: minutes)
                    dismiss()
                } label: {
                    Label("Bắt đầu chơi \(left.map { min($0, minutes) } ?? minutes) phút", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .keyboardShortcut(.defaultAction)
                .disabled(box.blockReason(game) != nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { minutes = game.defaultMinutes }
    }
}
