import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var timer: FocusTimer
    @ObservedObject private var ai = AISettings.shared
    @ObservedObject private var features = Features.shared
    @ObservedObject private var games = GameBox.shared
    @ObservedObject private var player = MusicPlayer.shared
    @State private var editing: Category?
    @State private var pendingDelete: Category?

    var body: some View {
        List(selection: $store.selection) {
            Section {
                ForEach(SidebarItem.smart.filter(features.isVisible), id: \.self) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        SymbolBadge(symbol: item.symbol, color: item.palette.color)
                    }
                    .badge(store.count(for: item))
                    .tag(item)
                }
            }

            Section("Danh mục") {
                if features.isOn(.timetable) {
                    Label {
                        Text("Thời khoá biểu")
                    } icon: {
                        SymbolBadge(symbol: "calendar.badge.clock", color: .red)
                    }
                    .badge(store.timetable.filter { $0.weekday == TT.today && !$0.isRest }.count)
                    .tag(SidebarItem.timetable)
                }
                ForEach(store.categories) { cat in
                    Label {
                        Text(cat.name)
                    } icon: {
                        SymbolBadge(symbol: cat.symbol, color: cat.color.color)
                    }
                    .badge(store.count(for: .category(cat.id)))
                    .tag(SidebarItem.category(cat.id))
                    .contextMenu {
                        Button("Sửa danh mục…", systemImage: "pencil") { editing = cat }
                        Divider()
                        Button("Xoá danh mục", systemImage: "trash", role: .destructive) { pendingDelete = cat }
                    }
                }
                .onMove(perform: store.moveCategory)
            }

            if Feature.utilities.contains(where: features.isOn) {
                Section("Tiện ích") {
                    if features.isOn(.focus) {
                        Label {
                            HStack {
                                Text("Pomodoro")
                                Spacer()
                                if timer.isRunning || timer.progress > 0 {
                                    Text(timer.timeString)
                                        .monospacedDigit()
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            SymbolBadge(symbol: "timer", color: .indigo)
                        }
                        .tag(SidebarItem.focus)
                    }

                    if features.isOn(.quiz) {
                        Label {
                            Text("Trắc nghiệm")
                        } icon: {
                            SymbolBadge(symbol: "graduationcap.fill", color: .purple)
                        }
                        .badge(store.quizzes.count)
                        .tag(SidebarItem.quiz)
                    }

                    if features.isOn(.ai) {
                        Label {
                            HStack {
                                Text(ai.current.name)
                                Spacer()
                                if ai.openMode == .safari {
                                    Image(systemName: "safari")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } icon: {
                            ProviderIcon(provider: ai.current)
                        }
                        .tag(SidebarItem.ai)
                        .contextMenu {
                            ForEach(ai.enabled) { p in
                                Button { ai.currentID = p.id } label: { Label { Text(p.name) } icon: { p.menuIcon } }
                            }
                            Divider()
                            SettingsLink { Label("Cài đặt trợ lý…", systemImage: "gearshape") }
                        }
                    }

                    if features.isOn(.storage) {
                        Label {
                            Text("Thư viện")
                        } icon: {
                            SymbolBadge(symbol: "externaldrive.fill", color: .teal)
                        }
                        .tag(SidebarItem.storage)
                    }

                    if features.isOn(.gamebox) {
                        Label {
                            HStack {
                                Text("Trò chơi")
                                Spacer()
                                if games.session != nil {
                                    Text(games.remainingText)
                                        .monospacedDigit()
                                        .font(.callout)
                                        .foregroundStyle(.pink)
                                }
                            }
                        } icon: {
                            SymbolBadge(symbol: "gamecontroller.fill", color: .pink)
                        }
                        .tag(SidebarItem.gamebox)
                    }

                    if features.isOn(.music) {
                        Label {
                            HStack {
                                Text("Phát nhạc")
                                Spacer()
                                if player.isPlaying {
                                    Image(systemName: "waveform")
                                        .symbolEffect(.variableColor.iterative, isActive: true)
                                        .foregroundStyle(.green)
                                        .help(player.current?.title ?? "")
                                }
                            }
                        } icon: {
                            SymbolBadge(symbol: "music.note", color: .green)
                        }
                        .tag(SidebarItem.music)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                editing = Category(name: "", symbol: "folder.fill", color: .blue)
            } label: {
                Label("Danh mục mới", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(item: $editing) { cat in
            CategoryEditor(category: cat, isNew: store.category(cat.id) == nil) { store.upsert($0) }
        }
        .confirmationDialog(
            "Xoá danh mục “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Xoá", role: .destructive) {
                if let id = pendingDelete?.id { store.deleteCategory(id) }
            }
        } message: {
            Text("Các ghi chú bên trong vẫn được giữ lại.")
        }
    }
}

struct CategoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var category: Category
    let isNew: Bool
    let onSave: (Category) -> Void

    private let symbols = [
        "folder.fill", "person.fill", "briefcase.fill", "lightbulb.fill", "book.fill", "graduationcap.fill",
        "cart.fill", "heart.fill", "star.fill", "house.fill", "dumbbell.fill", "airplane",
        "gamecontroller.fill", "music.note", "paintbrush.fill", "leaf.fill", "creditcard.fill", "gift.fill",
        "fork.knife", "camera.fill", "film.fill", "pawprint.fill", "sparkles", "flag.fill",
    ]

    init(category: Category, isNew: Bool, onSave: @escaping (Category) -> Void) {
        _category = State(initialValue: category)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 20) {
            SymbolBadge(symbol: category.symbol, color: category.color.color, size: 64)
                .shadow(color: category.color.color.opacity(0.4), radius: 10, y: 4)

            TextField("Tên danh mục", text: $category.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                ForEach(Palette.allCases) { p in
                    Circle()
                        .fill(p.color.gradient)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if p == category.color {
                                Circle().strokeBorder(.white, lineWidth: 2).padding(2)
                            }
                        }
                        .onTapGesture { category.color = p }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 6), spacing: 8) {
                ForEach(symbols, id: \.self) { s in
                    Image(systemName: s)
                        .font(.system(size: 15))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(s == category.symbol ? .white : .secondary)
                        .background(
                            Circle().fill(s == category.symbol
                                          ? AnyShapeStyle(category.color.color.gradient)
                                          : AnyShapeStyle(.quaternary.opacity(0.6)))
                        )
                        .contentShape(Circle())
                        .onTapGesture { category.symbol = s }
                }
            }

            HStack {
                Button("Huỷ", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Tạo" : "Lưu") {
                    category.name = category.name.trimmed
                    onSave(category)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(category.name.trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
