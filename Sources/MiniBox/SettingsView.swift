import SwiftUI
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Chung", systemImage: "gearshape") }
            AISettingsView()
                .tabItem { Label("Trợ lý AI", systemImage: "sparkles") }
            QuizSettingsView()
                .tabItem { Label("Trắc nghiệm", systemImage: "graduationcap") }
            MusicSettingsView()
                .tabItem { Label("Phát nhạc", systemImage: "music.note") }
            DiscordSettingsView()
                .tabItem { Label("Discord", systemImage: "bubble.left.and.text.bubble.right") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var features = Features.shared
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @State private var selectedID: UUID?
    @State private var editing: Category?
    @State private var pendingDelete: Category?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Giao diện").font(.headline)
                Spacer()
                Picker("Giao diện", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { m in
                        Label(m.title, systemImage: m.symbol).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 6)

            UpdateSection()
                .padding(.bottom, 6)

            Text("Hiển thị trên sidebar")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                featureGroup("Danh sách", Feature.lists)
                featureGroup("Tiện ích", Feature.utilities)
            }
            Text("Tắt một mục chỉ ẩn nó đi, dữ liệu vẫn được giữ nguyên.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Text("Danh mục")
                .font(.headline)
            Text("Kéo để sắp xếp thứ tự trên sidebar · nhấp đúp để sửa.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(store.categories) { cat in
                        HStack(spacing: 10) {
                            SymbolBadge(symbol: cat.symbol, color: cat.color.color, size: 24)
                            Text(cat.name)
                            Spacer()
                            Text("\(store.notes.filter { $0.categoryID == cat.id }.count) ghi chú")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 3)
                        .tag(cat.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = cat }
                        .contextMenu {
                            Button("Sửa…", systemImage: "pencil") { editing = cat }
                            Button("Xoá", systemImage: "trash", role: .destructive) { pendingDelete = cat }
                        }
                    }
                    .onMove(perform: store.moveCategory)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand {
                    if let id = selectedID { pendingDelete = store.category(id) }
                }
                .overlay {
                    if store.categories.isEmpty {
                        Text("Chưa có danh mục nào").foregroundStyle(.tertiary)
                    }
                }

                Divider()

                // Thanh + / − kiểu macOS ở chân danh sách.
                HStack(spacing: 0) {
                    Button {
                        editing = Category(name: "", symbol: "folder.fill", color: .blue)
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 22)
                    }
                    .help("Thêm danh mục")
                    Divider().frame(height: 16)
                    Button {
                        if let id = selectedID { pendingDelete = store.category(id) }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22)
                    }
                    .disabled(selectedID == nil)
                    .help("Xoá danh mục đã chọn")
                    Divider().frame(height: 16)
                    Button {
                        if let id = selectedID { editing = store.category(id) }
                    } label: {
                        Image(systemName: "pencil").frame(width: 24, height: 22)
                    }
                    .disabled(selectedID == nil)
                    .help("Sửa danh mục đã chọn")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.background)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding(20)
        .frame(height: 800)
        .sheet(item: $editing) { cat in
            CategoryEditor(category: cat, isNew: store.category(cat.id) == nil) { saved in
                store.upsert(saved, select: false)
                selectedID = saved.id
            }
        }
        .confirmationDialog(
            "Xoá danh mục “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Xoá", role: .destructive) {
                if let id = pendingDelete?.id {
                    store.deleteCategory(id)
                    if selectedID == id { selectedID = nil }
                }
            }
        } message: {
            Text("Các ghi chú bên trong vẫn được giữ lại.")
        }
    }
}

extension GeneralSettingsView {
    fileprivate func featureGroup(_ title: String, _ list: [Feature]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(list) { f in
                Toggle(isOn: features.binding(f)) {
                    Label {
                        Text(f.title)
                    } icon: {
                        SymbolBadge(symbol: f.item.symbol, color: f.item.palette.color, size: 22)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }
}

private struct AISettingsView: View {
    @ObservedObject private var ai = AISettings.shared
    @State private var newName = ""
    @State private var newURL = ""
    @State private var confirmClear = false
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Picker("Mở trợ lý", selection: $ai.openMode) {
                    ForEach(AIOpenMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Trợ lý mặc định", selection: $ai.currentID) {
                    ForEach(ai.enabled) { p in
                        Label { Text(p.name) } icon: { p.menuIcon }.tag(p.id)
                    }
                }
            } footer: {
                Text("Mở bằng Safari sẽ dùng luôn tài khoản đã đăng nhập trong Safari.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dịch vụ") {
                ForEach(ai.providers) { p in
                    HStack(spacing: 10) {
                        ProviderIcon(provider: p, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !p.builtIn {
                            Button {
                                ai.remove(p.id)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Xoá dịch vụ")
                        }
                        Toggle("Bật \(p.name)", isOn: $ai.providers.element(p.id, fallback: p).enabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(p.enabled && ai.enabled.count == 1)
                    }
                }
            }

            Section("Thêm dịch vụ khác") {
                TextField("Tên", text: $newName, prompt: Text("VD: HuggingChat"))
                TextField("Địa chỉ", text: $newURL, prompt: Text("VD: huggingface.co/chat"))
                HStack {
                    Spacer()
                    Button("Thêm") {
                        ai.addCustom(name: newName, url: newURL)
                        newName = ""
                        newURL = ""
                    }
                    .disabled(newName.trimmed.isEmpty || AIProvider(id: "", name: "", url: newURL, symbol: "", color: .gray).home?.host == nil)
                }
            }

            Section {
                HStack {
                    Button("Khôi phục danh sách mặc định") { ai.resetDefaults() }
                    Spacer()
                    Button(cleared ? "Đã đăng xuất" : "Đăng xuất tất cả…", role: .destructive) { confirmClear = true }
                        .disabled(cleared)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .confirmationDialog("Đăng xuất khỏi tất cả trợ lý AI trong MiniBox?", isPresented: $confirmClear) {
            Button("Đăng xuất", role: .destructive) {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    cleared = true
                }
            }
        } message: {
            Text("Cookie và dữ liệu đăng nhập của các trang AI trong MiniBox sẽ bị xoá. Safari không bị ảnh hưởng.")
        }
    }
}

private struct QuizSettingsView: View {
    @AppStorage("quizCount") private var count = 10
    @AppStorage("quizChoices") private var choices = 4
    @AppStorage("quizDifficulty") private var difficulty: QuizDifficulty.RawValue = QuizDifficulty.medium.rawValue
    @AppStorage("quizLanguage") private var language = "Tiếng Việt"
    @AppStorage("quizShuffleQuestions") private var shuffleQuestions = false
    @AppStorage("quizShuffleOptions") private var shuffleOptions = false

    var body: some View {
        Form {
            Section("Prompt mẫu") {
                Stepper("Số câu mặc định: \(count)", value: $count, in: 3...50)
                Stepper("Số lựa chọn: \(choices)", value: $choices, in: 2...6)
                Picker("Độ khó", selection: $difficulty) {
                    ForEach(QuizDifficulty.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Ngôn ngữ", selection: $language) {
                    Text("Tiếng Việt").tag("Tiếng Việt")
                    Text("English").tag("English")
                }
            }
            Section("Khi làm bài") {
                Toggle("Trộn thứ tự câu hỏi", isOn: $shuffleQuestions)
                Toggle("Trộn thứ tự đáp án", isOn: $shuffleOptions)
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}

// MARK: - Phát nhạc

private struct MusicSettingsView: View {
    @ObservedObject private var settings = MusicSettings.shared
    @ObservedObject private var lib = MusicLibrary.shared

    var body: some View {
        Form {
            Section {
                Picker("Kho nhạc", selection: $settings.provider) {
                    ForEach(CatalogProvider.allCases) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title)
                            Text(p.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(p)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Tìm kiếm & nghe online")
            } footer: {
                Text("Tìm bài hát hoặc dán link vào ô tìm kiếm trong Phát nhạc.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.provider == .custom {
                Section("API riêng") {
                    TextField("Địa chỉ tìm kiếm", text: $settings.customURL,
                              prompt: Text("https://api.example.com/search?q={query}"))
                    Text("""
                    MiniBox gọi GET tới địa chỉ trên ({query} = từ khoá) và đọc mảng JSON \
                    (hoặc {"results": [...]}). Mỗi bài cần: "title", "artist", "url" (link âm thanh mp3/m4a), \
                    tuỳ chọn "artwork", "duration" (giây).
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Nhạc trên máy") {
                LabeledContent("Số bài đã lưu", value: "\(lib.tracks.count)")
                LabeledContent("Công cụ tải từ link", value: lib.toolState == .ready ? "yt-dlp đã sẵn sàng" : "Chưa cài")
                Button("Mở thư mục nhạc trong Finder") { NSWorkspace.shared.open(lib.dir) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

// MARK: - Discord

private struct DiscordSettingsView: View {
    @ObservedObject private var rpc = Presence.shared

    var body: some View {
        Form {
            Section {
                Toggle("Hiện hoạt động trên Discord", isOn: $rpc.enabled)
                TextField("Application ID", text: $rpc.appID, prompt: Text("VD: 1234567890123456789"))
                    .disabled(!rpc.enabled)
                LabeledContent("Trạng thái") {
                    HStack(spacing: 6) {
                        Circle().fill(rpc.status == "Đã kết nối" ? Color.green : .secondary).frame(width: 8, height: 8)
                        Text(rpc.status)
                    }
                }
                if let p = rpc.preview, rpc.enabled {
                    LabeledContent("Đang hiển thị") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(p.details)
                            if !p.state.isEmpty { Text(p.state).foregroundStyle(.secondary) }
                        }
                    }
                }
            } footer: {
                Text("""
                Cách lấy Application ID (1 lần, miễn phí):
                1. Vào discord.com/developers/applications → New Application, đặt tên “MiniBox” (tên này hiện trên Discord).
                2. Mục Rich Presence → Art Assets: tải ảnh icon lên với tên “logo”.
                3. Copy Application ID ở mục General Information và dán vào ô trên.
                Cần mở app Discord trên máy.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Hiển thị") {
                Toggle("Bài nhạc đang nghe (kèm thanh thời gian)", isOn: $rpc.showMusic)
                Toggle("Game đang chơi trong mục Trò chơi", isOn: $rpc.showGames)
                Toggle("Đang làm gì trong MiniBox (ghi chú, trắc nghiệm…)", isOn: $rpc.showActivity)
                Toggle("Hiện tên ghi chú / bộ câu hỏi / tài liệu", isOn: $rpc.showTitles)
                    .disabled(!rpc.showActivity)
            }
            .disabled(!rpc.enabled)

            Section {
                Link("Mở Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}
