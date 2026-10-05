import AVKit
import PDFKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

// MARK: - Icons & thumbnails

struct FileIcon: View {
    let item: StorageItem
    var size: CGFloat = 22

    var body: some View {
        if item.isFolder {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(Color.playBlue.gradient)
                .frame(width: size, height: size)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

struct FileThumbnail: View {
    let item: StorageItem
    var size: CGFloat = 72
    @State private var image: NSImage?

    var body: some View {
        Group {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(Color.playBlue.gradient)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.url) {
            guard !item.isFolder else { return }
            let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
            }
        }
    }
}

// MARK: - Preview pane

struct FilePreview: View {
    let item: StorageItem
    @ObservedObject private var model = StorageModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileIcon(item: item, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.openExternally(item.url) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Mở bằng ứng dụng mặc định")
                Button { model.export(item.url) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Xuất bản sao ra ngoài…")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch item.kind {
            case .pdf: PDFViewer(url: item.url)
            case .image: ImageViewer(url: item.url)
            case .text: TextViewer(url: item.url)
            case .video, .audio: MediaPlayerView(url: item.url)
            default: QuickLookView(url: item.url)
            }
        }
        .id(item.url)
    }
}

/// Thanh công cụ nhỏ phía trên trình xem.
private struct ViewerBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - PDF

@MainActor
final class PDFController: ObservableObject {
    let pdfView = PDFView()
    let thumbs = PDFThumbnailView()
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var matchInfo = ""
    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var lastQuery = ""
    private var key = ""
    private var observer: NSObjectProtocol?

    func load(_ url: URL) {
        key = "pdfPage:" + url.lastPathComponent + ":" + String(url.path.hashValue)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.document = PDFDocument(url: url)
        thumbs.pdfView = pdfView
        thumbs.thumbnailSize = CGSize(width: 80, height: 104)
        thumbs.backgroundColor = .clear
        pageCount = pdfView.document?.pageCount ?? 0

        // Mở lại đúng trang đang đọc dở.
        let saved = UserDefaults.standard.integer(forKey: key)
        if saved > 0, let p = pdfView.document?.page(at: saved) { pdfView.go(to: p) }
        updatePage()

        observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
    }

    private func updatePage() {
        guard let doc = pdfView.document, let p = pdfView.currentPage else { return }
        page = doc.index(for: p)
        UserDefaults.standard.set(page, forKey: key)
    }

    func next() { pdfView.goToNextPage(nil) }
    func previous() { pdfView.goToPreviousPage(nil) }
    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func fit() { pdfView.autoScales = true }

    func find(_ query: String) {
        let q = query.trimmed
        guard !q.isEmpty, let doc = pdfView.document else {
            matches = []; pdfView.highlightedSelections = nil; matchInfo = ""; return
        }
        if q != lastQuery {
            lastQuery = q
            matches = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            matches.forEach { $0.color = .systemYellow }
            pdfView.highlightedSelections = matches
            matchIndex = 0
        } else if !matches.isEmpty {
            matchIndex = (matchIndex + 1) % matches.count
        }
        guard !matches.isEmpty else { matchInfo = "Không thấy"; return }
        let sel = matches[matchIndex]
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
        matchInfo = "\(matchIndex + 1)/\(matches.count)"
    }
}

private struct NSViewHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PDFViewer: View {
    let url: URL
    @StateObject private var ctl = PDFController()
    @AppStorage("pdfShowThumbs") private var showThumbs = true
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            ViewerBar {
                Button { withAnimation(.snappy) { showThumbs.toggle() } } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Ảnh thu nhỏ các trang")

                Divider().frame(height: 16)

                Button(action: ctl.previous) { Image(systemName: "chevron.up") }
                    .disabled(ctl.page == 0)
                    .help("Trang trước")
                Text("\(ctl.pageCount == 0 ? 0 : ctl.page + 1) / \(ctl.pageCount)")
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56)
                Button(action: ctl.next) { Image(systemName: "chevron.down") }
                    .disabled(ctl.page + 1 >= ctl.pageCount)
                    .help("Trang sau")

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tìm trong PDF", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 130)
                        .onSubmit { ctl.find(query) }
                    if !ctl.matchInfo.isEmpty {
                        Text(ctl.matchInfo).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onChange(of: query) { if query.isEmpty { ctl.find("") } }

                Divider().frame(height: 16)

                Button(action: ctl.zoomOut) { Image(systemName: "minus.magnifyingglass") }.help("Thu nhỏ")
                Button(action: ctl.fit) { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Vừa khung")
                Button(action: ctl.zoomIn) { Image(systemName: "plus.magnifyingglass") }.help("Phóng to")
            }

            HStack(spacing: 0) {
                if showThumbs {
                    NSViewHost(view: ctl.thumbs)
                        .frame(width: 112)
                        .background(.background.secondary)
                    Divider()
                }
                NSViewHost(view: ctl.pdfView)
            }
        }
        .onAppear { ctl.load(url) }
    }
}

// MARK: - Image

struct ImageViewer: View {
    let url: URL
    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var rotation = 0
    @GestureState private var pinch: CGFloat = 1

    private var pixelSize: CGSize {
        guard let rep = image?.representations.first else { return image?.size ?? .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewerBar {
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button { zoom = max(0.1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Thu nhỏ")
                Text("\(Int((zoom * pinch * 100).rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(minWidth: 44)
                Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Phóng to")
                Button { withAnimation(.snappy) { zoom = 1 } } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .help("Vừa khung")
                Divider().frame(height: 16)
                Button { withAnimation(.snappy) { rotation = (rotation + 90) % 360 } } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Xoay phải")
            }

            GeometryReader { geo in
                let rotated = rotation % 180 != 0
                let natural = image?.size ?? .zero
                let box = CGSize(width: max(geo.size.width - 32, 10), height: max(geo.size.height - 32, 10))
                let w = rotated ? natural.height : natural.width
                let h = rotated ? natural.width : natural.height
                let fit = (w > 0 && h > 0) ? min(box.width / w, box.height / h, 1) : 1
                let scale = fit * zoom * pinch
                let shown = CGSize(width: natural.width * scale, height: natural.height * scale)

                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: shown.width, height: shown.height)
                            .rotationEffect(.degrees(Double(rotation)))
                            .frame(width: rotated ? shown.height : shown.width,
                                   height: rotated ? shown.width : shown.height)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                            .padding(16)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                            .onTapGesture(count: 2) {
                                withAnimation(.snappy) { zoom = zoom == 1 ? 1 / fit : 1 }
                            }
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { v, state, _ in state = v.magnification }
                        .onEnded { v in zoom = min(8, max(0.1, zoom * v.magnification)) }
                )
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

// MARK: - Văn bản

struct TextViewer: View {
    let url: URL
    @State private var text: String?
    @State private var truncated = false
    private let limit = 2_000_000

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if truncated {
                            Label("Tệp lớn — chỉ hiện 2 MB đầu.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                text = "Không đọc được tệp."
                return
            }
            truncated = data.count > limit
            let slice = truncated ? data.prefix(limit) : data
            text = String(decoding: slice, as: UTF8.self)
        }
    }
}

// MARK: - Video / âm thanh

struct MediaPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .background(.black)
            .onAppear { player = AVPlayer(url: url) }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

// MARK: - Quick Look (Word, Keynote, Pages…)

/// Bọc QLPreviewView trong một NSView thường. Không gọi close()/deactivate thủ công —
/// việc đó khi SwiftUI đang gỡ view (đóng cửa sổ, đổi tab) làm QuickLook assert và crash app.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        guard let ql = QLPreviewView(frame: .zero, style: .normal) else { return container }
        ql.shouldCloseWithWindow = false
        ql.autostarts = false
        ql.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ql)
        NSLayoutConstraint.activate([
            ql.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ql.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ql.topAnchor.constraint(equalTo: container.topAnchor),
            ql.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        ql.previewItem = url as NSURL
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let ql = nsView.subviews.first as? QLPreviewView else { return }
        if (ql.previewItem as? NSURL) as URL? != url { ql.previewItem = url as NSURL }
    }
}
