import SwiftUI

struct NoteEditor: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var ai = AISettings.shared
    @Binding var note: Note
    @State private var showReminder = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, body, item(UUID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    CheckButton(isOn: note.isDone, size: 22) {
                        withAnimation(.snappy) { note.isDone.toggle() }
                    }
                    TextField("Tiêu đề", text: $note.title)
                        .font(.system(size: 26, weight: .bold))
                        .textFieldStyle(.plain)
                        .strikethrough(note.isDone, color: .secondary)
                        .focused($focus, equals: .title)
                        .onSubmit { focus = .body }
                }

                metaBar

                if !note.checklist.isEmpty { checklist }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 28)

            TextEditor(text: $note.body)
                .font(.system(size: 14))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 23)
                .padding(.vertical, 12)
                .overlay(alignment: .topLeading) {
                    if note.body.isEmpty {
                        Text("Viết gì đó…")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            footer
        }
        .onAppear {
            if note.title.isEmpty && note.body.isEmpty { focus = .title }
        }
    }

    // MARK: Meta chips

    private var metaBar: some View {
        let cat = store.category(note.categoryID)
        return HStack(spacing: 8) {
            Menu {
                Button("Không có") { note.categoryID = nil }
                Divider()
                ForEach(store.categories) { c in
                    Button(c.name, systemImage: c.symbol) { note.categoryID = c.id }
                }
            } label: {
                Label(cat?.name ?? "Danh mục", systemImage: cat?.symbol ?? "folder")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ChipStyle(tint: cat?.color.color ?? .secondary, active: cat != nil))
            .fixedSize()

            Button {
                showReminder = true
            } label: {
                Label(note.reminder?.reminderText ?? "Nhắc nhở",
                      systemImage: note.reminder == nil ? "bell" : "bell.fill")
            }
            .buttonStyle(ChipStyle(tint: note.isOverdue ? .red : .orange, active: note.reminder != nil))
            .popover(isPresented: $showReminder, arrowEdge: .bottom) {
                ReminderPicker(date: $note.reminder)
            }

            Button {
                addItem(after: nil)
            } label: {
                Label("Checklist", systemImage: "checklist")
            }
            .buttonStyle(ChipStyle(tint: .green, active: !note.checklist.isEmpty))

            Button {
                withAnimation(.snappy) { note.isPinned.toggle() }
            } label: {
                Label(note.isPinned ? "Đã ghim" : "Ghim", systemImage: note.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(ChipStyle(tint: .orange, active: note.isPinned))

            Spacer(minLength: 0)

            Button(action: askAI) {
                Label { Text("Hỏi \(ai.current.name)") } icon: { ai.current.menuIcon }
            }
            .buttonStyle(ChipStyle(tint: ai.current.color.color, active: true))
            .help("Gửi nội dung note sang \(ai.current.name) (đồng thời copy vào clipboard)")
        }
        .labelStyle(CompactLabel())
    }

    private func askAI() {
        var text = note.displayTitle
        if !note.checklist.isEmpty {
            text += "\n\n" + note.checklist.map { "- [\($0.isDone ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
        }
        if !note.body.trimmed.isEmpty { text += "\n\n" + note.body }
        store.askAI(text)
    }

    // MARK: Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Checklist").font(.subheadline.weight(.semibold))
                Text("\(note.checklistDone)/\(note.checklist.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: Double(note.checklistDone), total: Double(max(note.checklist.count, 1)))
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .frame(maxWidth: 120)
                Spacer()
                if note.checklistDone > 0 {
                    Button("Xoá mục đã xong") {
                        withAnimation(.snappy) { note.checklist.removeAll(where: \.isDone) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            let rows = VStack(alignment: .leading, spacing: 2) {
                ForEach(note.checklist) { item in
                    ChecklistRow(item: $note.checklist.element(item.id, fallback: item), focus: $focus,
                                 onSubmit: { addItem(after: item.id) },
                                 onDelete: { removeItem(item.id) })
                }
            }
            if note.checklist.count > 8 {
                ScrollView { rows }.frame(maxHeight: 260)
            } else {
                rows
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func addItem(after id: UUID?) {
        let item = ChecklistItem()
        withAnimation(.snappy) {
            if let id, let i = note.checklist.firstIndex(where: { $0.id == id }) {
                note.checklist.insert(item, at: i + 1)
            } else {
                note.checklist.append(item)
            }
        }
        DispatchQueue.main.async { focus = .item(item.id) }
    }

    private func removeItem(_ id: UUID) {
        guard let i = note.checklist.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { note.checklist.removeAll { $0.id == id } }
        if i > 0, note.checklist.indices.contains(i - 1) { focus = .item(note.checklist[i - 1].id) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Sửa lần cuối \(note.updatedAt.formatted(.relative(presentation: .named).locale(.vi)))")
            Spacer()
            Text("\(note.body.split { $0.isWhitespace || $0.isNewline }.count) từ")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
    }
}

private struct ChecklistRow: View {
    @Binding var item: ChecklistItem
    var focus: FocusState<NoteEditor.Field?>.Binding
    let onSubmit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            CheckButton(isOn: item.isDone, size: 15, tint: .green) {
                withAnimation(.snappy) { item.isDone.toggle() }
            }
            TextField("Việc cần làm", text: $item.text)
                .textFieldStyle(.plain)
                .strikethrough(item.isDone, color: .secondary)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .focused(focus, equals: .item(item.id))
                .onSubmit(onSubmit)
                .onKeyPress(.delete) {
                    guard item.text.isEmpty else { return .ignored }
                    onDelete()
                    return .handled
                }
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}

struct ReminderPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date?
    @State private var draft: Date

    init(date: Binding<Date?>) {
        _date = date
        _draft = State(initialValue: date.wrappedValue ?? .nextHour)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nhắc tôi").font(.headline)

            HStack(spacing: 6) {
                quick("1 giờ nữa", Date().addingTimeInterval(3600))
                quick("Tối nay", .today(at: 20))
                quick("Sáng mai", .today(at: 9, dayOffset: 1))
            }

            DatePicker("", selection: $draft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            DatePicker("Giờ", selection: $draft, displayedComponents: .hourAndMinute)

            HStack {
                if date != nil {
                    Button("Xoá nhắc", role: .destructive) {
                        date = nil
                        dismiss()
                    }
                }
                Spacer()
                Button("Đặt nhắc") {
                    date = draft
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private func quick(_ title: String, _ value: Date) -> some View {
        Button(title) { draft = value }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(value < .now)
    }
}
