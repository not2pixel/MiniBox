import SwiftUI

struct NotesBrowser: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HSplitView {
            NoteListView()
                .frame(minWidth: 260, idealWidth: 310, maxWidth: 440)

            Group {
                if let id = store.selectedNoteID, let note = store.binding(for: id) {
                    NoteEditor(note: note).id(id)
                } else {
                    ContentUnavailableView {
                        Label("Chưa chọn ghi chú", systemImage: "note.text")
                    } description: {
                        Text("Chọn một ghi chú bên trái hoặc nhấn ⌘N để tạo mới.")
                    } actions: {
                        Button("Ghi chú mới") { store.addNote() }
                    }
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(title)
        .navigationSubtitle("\(store.notes(for: store.selection).count) ghi chú")
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Tìm kiếm")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.addNote() } label: {
                    Label("Ghi chú mới", systemImage: "square.and.pencil")
                }
                .help("Ghi chú mới (⌘N)")
            }
        }
    }

    private var title: String {
        if case .category(let id) = store.selection { return store.category(id)?.name ?? "Danh mục" }
        return (store.selection ?? .all).title
    }
}

struct NoteListView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let notes = store.notes(for: store.selection)
        List(selection: $store.selectedNoteID) {
            ForEach(notes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .contextMenu { menu(for: note) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.background.secondary)
        .animation(.snappy, value: notes.map(\.id))
        .onDeleteCommand {
            if let id = store.selectedNoteID { store.delete(id) }
        }
        .overlay {
            if notes.isEmpty {
                if store.searchText.trimmed.isEmpty {
                    ContentUnavailableView("Trống trơn", systemImage: emptySymbol,
                                           description: Text("Không có ghi chú nào ở đây."))
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            }
        }
    }

    private var emptySymbol: String {
        store.selection == .done ? "checkmark.circle" : "tray"
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        Button(note.isDone ? "Đánh dấu chưa xong" : "Đánh dấu hoàn thành",
               systemImage: note.isDone ? "circle" : "checkmark.circle") { store.toggleDone(note.id) }
        Button(note.isPinned ? "Bỏ ghim" : "Ghim", systemImage: note.isPinned ? "pin.slash" : "pin") {
            store.togglePin(note.id)
        }
        Menu("Chuyển tới danh mục") {
            Button("Không có") { store.mutate(note.id) { $0.categoryID = nil } }
            Divider()
            ForEach(store.categories) { cat in
                Button(cat.name, systemImage: cat.symbol) { store.mutate(note.id) { $0.categoryID = cat.id } }
            }
        }
        Divider()
        Button("Xoá", systemImage: "trash", role: .destructive) { store.delete(note.id) }
    }
}

struct NoteRow: View {
    @EnvironmentObject private var store: Store
    let note: Note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            CheckButton(isOn: note.isDone, size: 17) { store.toggleDone(note.id) }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(note.displayTitle)
                        .font(.headline)
                        .strikethrough(note.isDone, color: .secondary)
                        .foregroundStyle(note.isDone ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                meta
            }
        }
        .padding(.vertical, 6)
        .opacity(note.isDone ? 0.7 : 1)
    }

    @ViewBuilder
    private var meta: some View {
        let cat = store.category(note.categoryID)
        if cat != nil || note.reminder != nil || !note.checklist.isEmpty {
            HStack(spacing: 10) {
                if let cat {
                    Label(cat.name, systemImage: cat.symbol)
                        .foregroundStyle(cat.color.color)
                }
                if let r = note.reminder {
                    Label(r.reminderText, systemImage: "bell.fill")
                        .foregroundStyle(note.isOverdue ? .red : .secondary)
                }
                if !note.checklist.isEmpty {
                    Label("\(note.checklistDone)/\(note.checklist.count)", systemImage: "checklist")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .labelStyle(CompactLabel())
            .lineLimit(1)
        }
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
