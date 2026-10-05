import SwiftUI

@main
struct MiniBoxApp: App {
    init() {
        // Bản cũ tên Noter: chuyển dữ liệu sang thư mục mới một lần.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Noter"), new = support.appendingPathComponent("MiniBox")
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.moveItem(at: old, to: new)
        }
    }

    @StateObject private var store = Store()
    @StateObject private var timer = FocusTimer()
    @ObservedObject private var ai = AISettings.shared
    @ObservedObject private var features = Features.shared
    @ObservedObject private var games = GameBox.shared
    @ObservedObject private var player = MusicPlayer.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(timer)
                .environment(\.locale, .vi)
                .tint(.playBlue)
                .frame(minWidth: 920, minHeight: 580)
                .onAppear {
                    Notifier.shared.setup()
                    // Khởi động sớm để theo dõi game/app ngay cả khi chưa mở tab.
                    _ = GameBox.shared
                    _ = MusicLibrary.shared
                    Presence.shared.attach(store: store, timer: timer)
                    Updater.shared.checkOnLaunch()
                    Notifier.shared.onOpenNote = { [store] id in store.reveal(id) }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Kiểm tra cập nhật…") { Updater.shared.checkInteractive() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Ghi chú mới") { store.addNote() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Tập trung") {
                Button(timer.isRunning ? "Tạm dừng" : "Bắt đầu") { timer.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Đặt lại") { timer.reset() }
                Button("Bỏ qua phiên") { timer.skip() }
                Divider()
                Button("Mở Pomodoro") { store.selection = .focus }
                    .keyboardShortcut("0")
                    .disabled(!features.isOn(.focus))
            }
            CommandMenu("Trợ lý AI") {
                Button("Mở \(ai.current.name)") { store.openAI() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Cuộc trò chuyện mới") {
                    store.openAI()
                    AIWebStore.shared.page(for: ai.current)?.goHome()
                }
                Button("Mở trong Safari") {
                    let page = AIWebStore.shared.page(for: ai.current)
                    if let url = page?.webView.url ?? ai.current.home { Safari.open(url) }
                }
                Divider()
                ForEach(Array(ai.enabled.prefix(9).enumerated()), id: \.element.id) { i, p in
                    Button(p.name) {
                        ai.currentID = p.id
                        store.openAI()
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
            }
            CommandGroup(after: .pasteboard) {
                Button("Mở Trắc nghiệm") { store.selection = .quiz }
                    .keyboardShortcut("9")
                    .disabled(!features.isOn(.quiz))
                Button("Mở Thư viện") { store.selection = .storage }
                    .keyboardShortcut("8")
                    .disabled(!features.isOn(.storage))
                Button("Mở Trò chơi") { store.selection = .gamebox }
                    .keyboardShortcut("7")
                    .disabled(!features.isOn(.gamebox))
                Button("Mở Thời khoá biểu") { store.selection = .timetable }
                    .keyboardShortcut("5")
                    .disabled(!features.isOn(.timetable))
                Button("Mở Phát nhạc") { store.selection = .music }
                    .keyboardShortcut("6")
                    .disabled(!features.isOn(.music))
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environment(\.locale, .vi)
                .tint(.playBlue)
        }

        MenuBarExtra(isInserted: Binding(get: { features.isOn(.focus) || games.session != nil || player.current != nil }, set: { _ in })) {
            if let game = games.activeGame {
                Text("Đang chơi \(game.name) · còn \(games.remainingText)")
                Button("Thêm 5 phút") { games.extend() }
                Button("Kết thúc phiên chơi") { games.stop() }
                Divider()
            }
            if let t = player.current {
                Text("♪ \(t.title) — \(t.artist)")
                Button(player.isPlaying ? "Tạm dừng nhạc" : "Phát nhạc") { player.toggle() }
                Button("Bài tiếp theo") { player.next() }
                Divider()
            }
            Button(timer.isRunning ? "Tạm dừng" : "Bắt đầu \(timer.phase.title.lowercased())") { timer.toggle() }
            Button("Bỏ qua phiên") { timer.skip() }
            Divider()
            Button("Thoát MiniBox") { NSApp.terminate(nil) }
        } label: {
            if games.session != nil {
                Text("\(Image(systemName: "gamecontroller.fill")) \(games.remainingText)")
            } else if timer.isRunning {
                Text("\(Image(systemName: timer.phase.symbol)) \(timer.timeString)")
            } else {
                Image(systemName: "timer")
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var features = Features.shared

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            Group {
                switch store.selection {
                case .focus: FocusView()
                case .quiz: QuizBrowser()
                case .ai: AIView()
                case .storage: StorageBrowser()
                case .gamebox: GameBoxView()
                case .music: MusicView()
                case .timetable: TimetableView()
                default: NotesBrowser()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil, features.isOn(.music) {
                    MiniPlayer().transition(.move(edge: .bottom))
                }
            }
        }
        .onAppear { AppearanceMode.apply(appearance) }
        .onChange(of: appearance) { AppearanceMode.apply(appearance) }
        .onReceive(Features.shared.$hidden) { _ in
            // Tắt mục đang mở → quay về Tất cả.
            if !Features.shared.isVisible(store.selection) { store.selection = .all }
            if !Features.shared.isOn(.music) { MusicPlayer.shared.stop() }
        }
        .onChange(of: store.selection) { old, new in
            // Chế độ Safari: bấm mục AI chỉ mở Safari, giữ nguyên màn hình hiện tại.
            if new == .ai, AISettings.shared.openMode == .safari {
                store.openAI()
                store.selection = old
                return
            }
            store.searchText = ""
            if let id = store.selectedNoteID,
               !store.notes(for: store.selection).contains(where: { $0.id == id }) {
                store.selectedNoteID = nil
            }
        }
    }
}
