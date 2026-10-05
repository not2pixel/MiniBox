import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileKind {
    case folder, pdf, image, video, audio, text, archive, other

    init(url: URL, isFolder: Bool) {
        if isFolder { self = .folder; return }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { self = .other; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
                    || type.conforms(to: .commaSeparatedText) || type.conforms(to: .xml) { self = .text }
        else if type.conforms(to: .archive) { self = .archive }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .folder: "Thư mục"
        case .pdf: "PDF"
        case .image: "Ảnh"
        case .video: "Video"
        case .audio: "Âm thanh"
        case .text: "Văn bản"
        case .archive: "Tệp nén"
        case .other: "Tệp"
        }
    }
}

struct StorageItem: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let size: Int64
    let modified: Date
    let kind: FileKind

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var detail: String {
        let date = modified.formatted(.dateTime.day().month(.abbreviated).year().locale(.vi))
        return isFolder ? "\(kind.title) · \(date)" : "\(kind.title) · \(size.formatted(.byteCount(style: .file))) · \(date)"
    }

    init?(url: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.isHidden != true else { return nil }
        self.url = url.standardizedFileURL
        isFolder = v.isDirectory ?? false
        size = Int64(v.fileSize ?? 0)
        modified = v.contentModificationDate ?? .distantPast
        kind = FileKind(url: url, isFolder: isFolder)
    }
}

/// Kho tệp riêng của MiniBox: ~/Library/Application Support/MiniBox/Storage
@MainActor
final class StorageModel: ObservableObject {
    static let shared = StorageModel()

    enum SortKey: String, CaseIterable, Identifiable {
        case name, date, size, kind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: "Tên"
            case .date: "Ngày sửa"
            case .size: "Kích thước"
            case .kind: "Loại"
            }
        }
    }

    enum ViewMode: String { case list, grid }

    let root: URL
    @Published private(set) var current: URL
    @Published private(set) var items: [StorageItem] = []
    @Published var selection: URL?
    @Published var renaming: URL?
    @Published var search = "" { didSet { reload() } }
    @Published var sort: SortKey {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "storageSort"); reload() }
    }
    @Published var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "storageViewMode") }
    }
    @Published var errorMessage: String?

    private let fm = FileManager.default
    private var watcher: DispatchSourceFileSystemObject?
    private var activeObserver: NSObjectProtocol?

    private init() {
        root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniBox/Storage", isDirectory: true).standardizedFileURL
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        current = root
        sort = SortKey(rawValue: UserDefaults.standard.string(forKey: "storageSort") ?? "") ?? .name
        viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "storageViewMode") ?? "") ?? .list
        reload()
        watch(current)
        // Quay lại app → làm mới (phòng khi tệp bị đổi từ bên ngoài).
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var isAtRoot: Bool { current.path == root.path }
    var selectedItem: StorageItem? { selection.flatMap { StorageItem(url: $0) } }

    /// Các thư mục từ gốc tới thư mục hiện tại (cho thanh đường dẫn).
    var breadcrumb: [URL] {
        var list: [URL] = []
        var u = current
        while u.path.hasPrefix(root.path) {
            list.insert(u, at: 0)
            if u.path == root.path { break }
            u = u.deletingLastPathComponent().standardizedFileURL
        }
        return list
    }

    func displayName(_ url: URL) -> String { url.path == root.path ? "Thư viện" : url.lastPathComponent }

    func contains(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.path) }

    /// Theo dõi thư mục đang mở: có tệp thêm/xoá/đổi tên là tự cập nhật danh sách.
    private func watch(_ url: URL) {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: Listing

    func reload() {
        let q = search.trimmed
        var list: [StorageItem]
        if q.isEmpty {
            let urls = (try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)) ?? []
            list = urls.compactMap(StorageItem.init(url:))
        } else {
            // Tìm trong toàn bộ Storage.
            let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            list = (e?.allObjects as? [URL] ?? [])
                .filter { $0.lastPathComponent.localizedCaseInsensitiveContains(q) }
                .compactMap(StorageItem.init(url:))
        }
        items = list.sorted(by: comparator)
        if let s = selection, !fm.fileExists(atPath: s.path) { selection = nil }
    }

    private func comparator(_ a: StorageItem, _ b: StorageItem) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        switch sort {
        case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .date: return a.modified > b.modified
        case .size: return a.size > b.size
        case .kind:
            if a.kind.title != b.kind.title { return a.kind.title < b.kind.title }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var summary: String {
        let files = items.filter { !$0.isFolder }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return "\(items.count) mục · \(total.formatted(.byteCount(style: .file)))"
    }

    // MARK: Navigation

    func open(_ item: StorageItem) {
        guard fm.fileExists(atPath: item.url.path) else { reload(); return }
        if item.isFolder { go(to: item.url) } else { selection = item.url }
    }

    func go(to url: URL) {
        guard contains(url) else { return }
        search = ""
        current = url.standardizedFileURL
        selection = nil
        renaming = nil
        reload()
        watch(current)
    }

    func goUp() {
        guard !isAtRoot else { return }
        let parent = current.deletingLastPathComponent()
        let from = current
        go(to: parent)
        selection = from.standardizedFileURL
    }

    // MARK: File operations

    private func uniqueURL(for name: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    /// Tệp từ ngoài → copy vào; tệp trong Storage → chuyển chỗ.
    func receive(_ urls: [URL], into folder: URL? = nil) {
        let dest = (folder ?? current).standardizedFileURL
        for src in urls {
            let s = src.standardizedFileURL
            if contains(s) {
                guard s.deletingLastPathComponent().path != dest.path, !dest.path.hasPrefix(s.path + "/"), s.path != dest.path
                else { continue }
                attempt { try fm.moveItem(at: s, to: uniqueURL(for: s.lastPathComponent, in: dest)) }
            } else {
                attempt { try fm.copyItem(at: s, to: uniqueURL(for: s.lastPathComponent, in: dest)) }
            }
        }
        reload()
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Thêm vào Thư viện"
        panel.message = "Các tệp sẽ được copy vào Thư viện của MiniBox."
        panel.begin { [weak self] in
            if $0 == .OK { self?.receive(panel.urls) }
        }
    }

    func newFolder() {
        let url = uniqueURL(for: "Thư mục mới", in: current)
        attempt { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        reload()
        selection = url.standardizedFileURL
        renaming = url.standardizedFileURL
    }

    func rename(_ url: URL, to newName: String) {
        renaming = nil
        let name = newName.trimmed.replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        guard !fm.fileExists(atPath: dest.path) else {
            errorMessage = "Đã có mục tên “\(name)” trong thư mục này."
            return
        }
        attempt { try fm.moveItem(at: url, to: dest) }
        reload()
        selection = dest.standardizedFileURL
    }

    /// Chuyển vào Thùng rác của macOS (có thể khôi phục).
    func trash(_ url: URL) {
        if fm.fileExists(atPath: url.path) {
            attempt { try fm.trashItem(at: url, resultingItemURL: nil) }
        }
        if selection == url { selection = nil }
        reload()
    }

    func duplicate(_ url: URL) {
        attempt { try fm.copyItem(at: url, to: uniqueURL(for: url.lastPathComponent, in: url.deletingLastPathComponent())) }
        reload()
    }

    func export(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.prompt = "Xuất"
        panel.begin { [weak self] in
            guard $0 == .OK, let dest = panel.url else { return }
            self?.attempt {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: url, to: dest)
            }
        }
    }

    func openExternally(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Các thư mục con trong Storage (để chọn đích khi chuyển).
    func allFolders() -> [URL] {
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let urls = (e?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return [root] + urls.map(\.standardizedFileURL).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func relativePath(_ url: URL) -> String {
        let rel = url.standardizedFileURL.path.dropFirst(root.path.count)
        return rel.isEmpty ? "Thư viện" : "Thư viện" + rel
    }

    private func attempt(_ op: () throws -> Void) {
        do { try op() } catch { errorMessage = error.localizedDescription }
    }
}
