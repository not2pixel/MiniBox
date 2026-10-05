import SwiftUI
import WebKit

// MARK: - Provider

struct AIProvider: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var url: String
    var symbol: String
    var color: Palette
    var enabled = true
    var builtIn = false
    /// Tên file logo trong Resources/Logos (svg hoặc png).
    var logo: String?
    /// Logo màu sáng, cần nền tối.
    var logoOnDark = false

    var home: URL? {
        let s = url.trimmed
        guard !s.isEmpty else { return nil }
        return URL(string: s.contains("://") ? s : "https://" + s)
    }

    var host: String { home?.host ?? url }

    static let builtIns: [AIProvider] = [
        .init(id: "claude", name: "Claude", url: "https://claude.ai/new", symbol: "sparkles", color: .orange, builtIn: true, logo: "claude"),
        .init(id: "chatgpt", name: "ChatGPT", url: "https://chatgpt.com/", symbol: "bubble.left.and.bubble.right.fill", color: .green, builtIn: true, logo: "chatgpt"),
        .init(id: "gemini", name: "Gemini", url: "https://gemini.google.com/app", symbol: "wand.and.stars", color: .blue, builtIn: true, logo: "gemini"),
        .init(id: "deepseek", name: "DeepSeek", url: "https://chat.deepseek.com/", symbol: "water.waves", color: .indigo, builtIn: true, logo: "deepseek"),
        .init(id: "grok", name: "Grok", url: "https://grok.com/", symbol: "bolt.fill", color: .gray, enabled: false, builtIn: true, logo: "grok"),
        .init(id: "perplexity", name: "Perplexity", url: "https://www.perplexity.ai/", symbol: "magnifyingglass", color: .teal, enabled: false, builtIn: true, logo: "perplexity"),
        .init(id: "copilot", name: "Copilot", url: "https://copilot.microsoft.com/", symbol: "paperplane.fill", color: .purple, enabled: false, builtIn: true, logo: "copilot"),
        .init(id: "mistral", name: "Le Chat", url: "https://chat.mistral.ai/chat", symbol: "wind", color: .yellow, enabled: false, builtIn: true, logo: "mistral"),
        .init(id: "qwen", name: "Qwen", url: "https://chat.qwen.ai/", symbol: "cube.fill", color: .pink, enabled: false, builtIn: true, logo: "qwen"),
        .init(id: "kimi", name: "Kimi", url: "https://www.kimi.com/", symbol: "moon.stars.fill", color: .mint, enabled: false, builtIn: true, logo: "kimi", logoOnDark: true),
    ]
}

// MARK: - Logo

extension AIProvider {
    @MainActor private static var logoCache: [String: NSImage] = [:]

    @MainActor var logoImage: NSImage? {
        guard let logo else { return nil }
        if let cached = Self.logoCache[logo] { return cached }
        let url = ["svg", "png"].lazy
            .compactMap { Bundle.main.url(forResource: logo, withExtension: $0, subdirectory: "Logos") }
            .first
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        Self.logoCache[logo] = img
        return img
    }

    /// Ảnh nhỏ 16pt cho menu (menu macOS không co giãn ảnh).
    @MainActor var menuIcon: Image {
        guard let img = logoImage else { return Image(systemName: symbol) }
        let size = NSSize(width: 16, height: 16)
        let out = NSImage(size: size, flipped: false) { rect in
            if logoOnDark {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                img.draw(in: rect.insetBy(dx: 3, dy: 3))
            } else {
                img.draw(in: rect.insetBy(dx: 1, dy: 1))
            }
            return true
        }
        return Image(nsImage: out)
    }
}

/// Logo hãng trong vòng tròn; không có logo thì dùng SF Symbol.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 22

    var body: some View {
        if let img = provider.logoImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * (provider.logoOnDark ? 0.24 : 0.18))
                .frame(width: size, height: size)
                .background(Circle().fill(provider.logoOnDark ? Color.black : Color.white))
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        } else {
            SymbolBadge(symbol: provider.symbol, color: provider.color.color, size: size)
        }
    }
}

enum AIOpenMode: String, CaseIterable, Identifiable {
    case inApp, safari
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inApp: "Ngay trong MiniBox"
        case .safari: "Safari"
        }
    }
}

// MARK: - Settings

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    @Published var providers: [AIProvider] {
        didSet { defaults.set(try? JSONEncoder().encode(providers), forKey: "aiProviders") }
    }
    @Published var currentID: String { didSet { defaults.set(currentID, forKey: "aiCurrent") } }
    @Published var openMode: AIOpenMode { didSet { defaults.set(openMode.rawValue, forKey: "aiOpenMode") } }

    private let defaults = UserDefaults.standard

    private init() {
        var list = defaults.data(forKey: "aiProviders")
            .flatMap { try? JSONDecoder().decode([AIProvider].self, from: $0) } ?? AIProvider.builtIns
        // Dịch vụ mặc định: cập nhật tên/địa chỉ/logo theo bản mới, giữ trạng thái bật/tắt.
        for b in AIProvider.builtIns {
            if let i = list.firstIndex(where: { $0.id == b.id }) {
                var updated = b
                updated.enabled = list[i].enabled
                list[i] = updated
            } else {
                list.append(b)
            }
        }
        providers = list
        currentID = defaults.string(forKey: "aiCurrent") ?? "claude"
        openMode = AIOpenMode(rawValue: defaults.string(forKey: "aiOpenMode") ?? "") ?? .inApp
    }

    var enabled: [AIProvider] { providers.filter(\.enabled) }

    var current: AIProvider {
        enabled.first { $0.id == currentID } ?? enabled.first ?? AIProvider.builtIns[0]
    }

    func addCustom(name: String, url: String) {
        let p = AIProvider(id: UUID().uuidString, name: name.trimmed, url: url.trimmed,
                           symbol: "globe", color: .gray)
        providers.append(p)
    }

    func remove(_ id: String) { providers.removeAll { $0.id == id && !$0.builtIn } }

    func resetDefaults() {
        providers = AIProvider.builtIns
        currentID = "claude"
    }
}

enum Safari {
    static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Web page

/// Một trang web cho mỗi dịch vụ, giữ nguyên cuộc trò chuyện khi chuyển tab.
@MainActor
final class AIPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    /// Các miền đăng nhập/xác minh được phép mở trong app.
    private static let authDomains = [
        "google.com", "gstatic.com", "googleusercontent.com", "apple.com", "icloud.com",
        "microsoft.com", "microsoftonline.com", "live.com", "openai.com", "chatgpt.com",
        "x.com", "twitter.com", "github.com", "anthropic.com", "claude.com", "claude.ai",
        "cloudflare.com", "hcaptcha.com", "recaptcha.net", "arkoselabs.com",
    ]

    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false

    let home: URL
    let webView: WKWebView
    private var popups: [NSWindow] = []

    init(home: URL) {
        self.home = home
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // cookie được lưu lại → chỉ đăng nhập một lần
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUA
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: home))
    }

    func goHome() { webView.load(URLRequest(url: home)) }
    func reload() { webView.reload() }
    func goBack() { webView.goBack() }

    /// Chèn chữ vào ô chat (textarea hoặc contenteditable). Thử lại vài lần nếu trang chưa tải xong.
    func send(_ text: String, attempts: Int = 10) {
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        (() => {
          const visible = el => el && el.offsetParent !== null && !el.disabled;
          const el = [...document.querySelectorAll('textarea, [contenteditable="true"]')].find(visible);
          if (!el) return false;
          el.focus();
          if (el.tagName === 'TEXTAREA') {
            const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
            set.call(el, \(json));
            el.dispatchEvent(new Event('input', { bubbles: true }));
          } else {
            document.execCommand('selectAll', false);
            document.execCommand('insertText', false, \(json));
          }
          return true;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard (result as? Bool) != true, attempts > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self?.send(text, attempts: attempts - 1)
            }
        }
    }

    private func refreshState() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
    }

    private static func baseDomain(_ host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    private func allowedInApp(_ host: String) -> Bool {
        let own = Self.baseDomain(home.host ?? "")
        return (Self.authDomains + [own]).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refreshState() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refreshState() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refreshState() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshState()
    }

    /// Tiến trình web bị crash → trang trắng; tự tải lại.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           let host = url.host, !allowedInApp(host) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: WKUIDelegate

    /// Popup (đăng nhập Google/Apple…) → cửa sổ con thật, giữ liên kết window.opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let host = url.host, !allowedInApp(host) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = Self.safariUA
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let win = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Đăng nhập"
        win.contentView = popup
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        popups.append(win)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { win in
            guard win.contentView === webView else { return false }
            win.close()
            return true
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}

/// Mỗi dịch vụ một trang, tạo khi cần.
@MainActor
final class AIWebStore {
    static let shared = AIWebStore()
    private var pages: [String: AIPage] = [:]

    func page(for provider: AIProvider) -> AIPage? {
        guard let home = provider.home else { return nil }
        if let page = pages[provider.id], page.home == home { return page }
        let page = AIPage(home: home)
        pages[provider.id] = page
        return page
    }
}

// MARK: - Views

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView { attach(to: nsView) }
    }

    /// Gắn webview dùng chung vào container mới mỗi lần quay lại tab.
    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

struct AIView: View {
    @ObservedObject private var ai = AISettings.shared

    var body: some View {
        let provider = ai.current
        Group {
            if let page = AIWebStore.shared.page(for: provider) {
                AIPageView(page: page).id(provider.id)
            } else {
                ContentUnavailableView("Địa chỉ không hợp lệ", systemImage: "exclamationmark.triangle",
                                       description: Text("Kiểm tra lại URL của \(provider.name) trong Cài đặt (⌘,)."))
            }
        }
        .navigationTitle(provider.name)
        .navigationSubtitle(provider.host)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ai.enabled) { p in
                        Button { ai.currentID = p.id } label: {
                            Label { Text(p.id == provider.id ? "\(p.name) — đang dùng" : p.name) } icon: { p.menuIcon }
                        }
                    }
                    Divider()
                    SettingsLink { Label("Quản lý dịch vụ…", systemImage: "gearshape") }
                } label: {
                    Label { Text(provider.name) } icon: { provider.menuIcon }
                }
                .help("Chọn trợ lý AI")
            }
        }
    }
}

private struct AIPageView: View {
    @ObservedObject var page: AIPage

    var body: some View {
        WebViewHost(webView: page.webView)
            .overlay(alignment: .top) {
                if page.isLoading {
                    ProgressView().progressViewStyle(.linear).frame(height: 2)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { page.goBack() } label: { Label("Quay lại", systemImage: "chevron.backward") }
                        .disabled(!page.canGoBack)
                    Button { page.reload() } label: { Label("Tải lại", systemImage: "arrow.clockwise") }
                    Button { page.goHome() } label: { Label("Cuộc trò chuyện mới", systemImage: "plus.bubble") }
                        .help("Cuộc trò chuyện mới")
                    Button { Safari.open(page.webView.url ?? page.home) } label: {
                        Label("Mở trong Safari", systemImage: "safari")
                    }
                    .help("Mở trang này trong Safari")
                }
            }
    }
}
