import SwiftUI
import UniformTypeIdentifiers

struct StorageBrowser: View {
    @ObservedObject private var model = StorageModel.shared
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PathBar()
                Divider()
                Group {
                    if model.viewMode == .grid { StorageGrid() } else { StorageList() }
                }
                .overlay {
                    if model.items.isEmpty { emptyState }
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.playBlue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .background(Color.playBlue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.receive(urls)
                    return true
                } isTargeted: { dropTargeted = $0 }

                Divider()
                Text(model.search.trimmed.isEmpty ? model.summary : "\(model.items.count) kết quả trong Thư viện")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .background(.background.secondary)
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)

            Group {
                if let item = model.selectedItem, !item.isFolder {
                    FilePreview(item: item)
                } else {
                    ContentUnavailableView {
                        Label("Chưa chọn tệp", systemImage: "doc.viewfinder")
                    } description: {
                        Text("Chọn một tệp để xem. PDF và ảnh mở bằng trình xem riêng, các loại khác xem nhanh bằng Quick Look.")
                    }
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(model.displayName(model.current))
        .navigationSubtitle(model.relativePath(model.current))
        .searchable(text: $model.search, placement: .toolbar, prompt: "Tìm trong Thư viện")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: model.goUp) { Label("Lên thư mục cha", systemImage: "chevron.backward") }
                    .disabled(model.isAtRoot)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Lên thư mục cha (⌘↑)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Kiểu xem", selection: $model.viewMode) {
                    Label("Danh sách", systemImage: "list.bullet").tag(StorageModel.ViewMode.list)
                    Label("Lưới", systemImage: "square.grid.2x2").tag(StorageModel.ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Kiểu xem")

                Menu {
                    Picker("Sắp xếp theo", selection: $model.sort) {
                        ForEach(StorageModel.SortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sắp xếp", systemImage: "arrow.up.arrow.down")
                }
                .help("Sắp xếp")

                Button(action: model.newFolder) { Label("Thư mục mới", systemImage: "folder.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Thư mục mới (⇧⌘N)")

                Button(action: model.importWithPanel) { Label("Thêm tệp", systemImage: "plus") }
                    .keyboardShortcut("o")
                    .help("Thêm tệp vào Thư viện (⌘O)")
            }
        }
        .onAppear { model.reload() }
        .alert("Không thực hiện được",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.search.trimmed.isEmpty {
            ContentUnavailableView {
                Label(model.isAtRoot ? "Thư viện trống" : "Thư mục trống", systemImage: "tray.and.arrow.down")
            } description: {
                Text("Kéo thả tệp vào đây hoặc bấm Thêm tệp. Tệp được copy vào kho riêng của MiniBox.")
            } actions: {
                Button("Thêm tệp…", action: model.importWithPanel)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView.search(text: model.search)
        }
    }
}

// MARK: - Path bar

private struct PathBar: View {
    @ObservedObject private var model = StorageModel.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.breadcrumb.enumerated()), id: \.element) { i, url in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button { model.go(to: url) } label: {
                        Label(model.displayName(url), systemImage: i == 0 ? "externaldrive.fill" : "folder.fill")
                            .labelStyle(CompactLabel())
                            .font(.callout.weight(i == model.breadcrumb.count - 1 ? .semibold : .regular))
                            .foregroundStyle(i == model.breadcrumb.count - 1 ? .primary : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.receive(urls, into: url)
                        return true
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Shared context menu

private struct ItemMenu: View {
    let item: StorageItem
    @ObservedObject private var model = StorageModel.shared

    var body: some View {
        Button(item.isFolder ? "Mở" : "Xem", systemImage: "eye") { model.open(item) }
        if !item.isFolder {
            Button("Mở bằng ứng dụng mặc định", systemImage: "arrow.up.forward.app") { model.openExternally(item.url) }
        }
        Divider()
        Button("Đổi tên", systemImage: "pencil") {
            model.selection = item.url
            model.renaming = item.url
        }
        Button("Nhân bản", systemImage: "plus.square.on.square") { model.duplicate(item.url) }
        Menu("Chuyển tới") {
            ForEach(model.allFolders().filter {
                $0.path != item.url.deletingLastPathComponent().standardizedFileURL.path
                    && $0.path != item.url.path && !$0.path.hasPrefix(item.url.path + "/")
            }, id: \.self) { folder in
                Button(model.relativePath(folder)) { model.receive([item.url], into: folder) }
            }
        }
        Button("Xuất bản sao…", systemImage: "square.and.arrow.up") { model.export(item.url) }
        Divider()
        Button("Chuyển vào Thùng rác", systemImage: "trash", role: .destructive) { model.trash(item.url) }
    }
}

// MARK: - List

private struct StorageList: View {
    @ObservedObject private var model = StorageModel.shared
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                row(item)
                    .tag(item.url)
                    .draggable(item.url)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard item.isFolder else { return false }
                        model.receive(urls, into: item.url)
                        return true
                    }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first, let item = StorageItem(url: url) { ItemMenu(item: item) }
        } primaryAction: { urls in
            if let url = urls.first, let item = StorageItem(url: url) { model.open(item) }
        }
        .onDeleteCommand {
            if let url = model.selection { model.trash(url) }
        }
    }

    @ViewBuilder
    private func row(_ item: StorageItem) -> some View {
        HStack(spacing: 10) {
            FileIcon(item: item, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                if model.renaming == item.url {
                    TextField("Tên", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onAppear {
                            draftName = item.name
                            renameFocused = true
                        }
                        .onSubmit { model.rename(item.url, to: draftName) }
                        .onExitCommand { model.renaming = nil }
                } else {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(model.search.trimmed.isEmpty ? item.detail : model.relativePath(item.url.deletingLastPathComponent()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Grid

private struct StorageGrid: View {
    @ObservedObject private var model = StorageModel.shared

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)], spacing: 14) {
                ForEach(model.items) { item in
                    let selected = model.selection == item.url
                    VStack(spacing: 6) {
                        FileThumbnail(item: item, size: 72)
                            .padding(6)
                            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(selected ? .white : .primary)
                            .background(selected ? AnyShapeStyle(Color.playBlue) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.open(item) }
                    .simultaneousGesture(TapGesture().onEnded { model.selection = item.url })
                    .contextMenu { ItemMenu(item: item) }
                    .draggable(item.url)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard item.isFolder else { return false }
                        model.receive(urls, into: item.url)
                        return true
                    }
                }
            }
            .padding(14)
        }
        .onTapGesture { model.selection = nil }
        .onDeleteCommand {
            if let url = model.selection { model.trash(url) }
        }
        .sheet(item: Binding(
            get: { model.renaming.map { RenameTarget(url: $0) } },
            set: { if $0 == nil { model.renaming = nil } }
        )) { target in
            RenameSheet(url: target.url)
        }
    }
}

private struct RenameTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct RenameSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Đổi tên").font(.headline)
            TextField("Tên", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Huỷ") { StorageModel.shared.renaming = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Đổi tên", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = url.lastPathComponent }
    }

    private func save() {
        StorageModel.shared.rename(url, to: name)
        dismiss()
    }
}
