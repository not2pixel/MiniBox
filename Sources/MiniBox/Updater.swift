import AppKit
import SwiftUI

/// Tự cập nhật từ GitHub Releases của repo MiniBox.
/// Bản phát hành cần đính kèm tệp `MiniBox.zip` (chứa MiniBox.app) và có tag dạng `v1.2.3`.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "not2pixel/MiniBox"

    struct Release: Equatable {
        var version: String
        var notes: String
        var zipURL: URL
        var page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading, installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdate") }
    }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
    }

    /// Gọi khi mở app: tối đa 1 lần / ngày, hỏi người dùng nếu có bản mới.
    func checkOnLaunch() {
        guard autoCheck, Date().timeIntervalSince(lastCheck ?? .distantPast) > 86_400 else { return }
        Task {
            await check()
            if case .available(let r) = state { prompt(r) }
        }
    }

    func check() async {
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MiniBox/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { state = .upToDate; lastCheck = .now; return } // chưa có bản phát hành nào
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { throw MusicError.message("GitHub trả về lỗi \(code).") }
            lastCheck = .now
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = obj["assets"] as? [[String: Any]] ?? []
            guard Self.isNewer(version, than: currentVersion),
                  let zip = assets.first(where: { ($0["name"] as? String) == "MiniBox.zip" })?["browser_download_url"] as? String,
                  let zipURL = URL(string: zip) else {
                state = .upToDate
                return
            }
            state = .available(Release(version: version, notes: obj["body"] as? String ?? "", zipURL: zipURL,
                                       page: URL(string: obj["html_url"] as? String ?? "") ?? zipURL))
        } catch {
            state = .failed("Không kiểm tra được: \(error.localizedDescription)")
        }
    }

    /// So sánh phiên bản dạng 1.2.3
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Từ menu "Kiểm tra cập nhật…": luôn báo kết quả.
    func checkInteractive() {
        Task {
            await check()
            switch state {
            case .available(let r): prompt(r)
            case .upToDate:
                let a = NSAlert()
                a.messageText = "MiniBox \(currentVersion) là bản mới nhất"
                a.runModal()
            case .failed(let e):
                let a = NSAlert()
                a.messageText = "Không kiểm tra được bản cập nhật"
                a.informativeText = e
                a.runModal()
            default: break
            }
        }
    }

    private func prompt(_ r: Release) {
        let alert = NSAlert()
        alert.messageText = "Đã có MiniBox \(r.version)"
        alert.informativeText = "Bạn đang dùng bản \(currentVersion). Cập nhật ngay? MiniBox sẽ tự khởi động lại.\n\n"
            + String(r.notes.prefix(600))
        alert.addButton(withTitle: "Cập nhật")
        alert.addButton(withTitle: "Để sau")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { install(r) }
    }

    /// Tải bản mới, thay thế app hiện tại rồi mở lại.
    func install(_ r: Release) {
        state = .downloading
        let target = Bundle.main.bundleURL
        Task {
            do {
                let (zip, resp) = try await URLSession.shared.download(from: r.zipURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.message("Tải bản cập nhật thất bại.") }
                state = .installing

                let work = FileManager.default.temporaryDirectory.appendingPathComponent("MiniBoxUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.path]
                try unzip.run()
                unzip.waitUntilExit()

                let newApp = work.appendingPathComponent("MiniBox.app")
                guard unzip.terminationStatus == 0,
                      Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw MusicError.message("Gói cập nhật không hợp lệ.")
                }
                guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                    throw MusicError.message("Không có quyền ghi vào \(target.deletingLastPathComponent().path).")
                }

                // Script chạy sau khi MiniBox thoát: đổi app, giữ bản cũ nếu lỗi, rồi mở lại.
                let script = """
                #!/bin/bash
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
                T="\(target.path)"
                rm -rf "$T.old"
                if mv "$T" "$T.old" && mv "\(newApp.path)" "$T"; then
                  rm -rf "$T.old"
                else
                  [ -d "$T" ] || mv "$T.old" "$T"
                fi
                xattr -cr "$T" 2>/dev/null
                open "$T"
                rm -rf "\(work.path)"
                """
                let scriptURL = work.appendingPathComponent("update.sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [scriptURL.path]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Mục "Cập nhật" trong Cài đặt → Chung.
struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cập nhật").font(.headline)
                Spacer()
                Text("Phiên bản \(updater.currentVersion)").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                status
                Spacer()
                switch updater.state {
                case .available(let r):
                    Button("Cập nhật lên \(r.version)") { updater.install(r) }
                        .buttonStyle(.borderedProminent)
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Kiểm tra ngay") { Task { await updater.check() } }
                }
            }
            Toggle("Tự động kiểm tra bản mới mỗi ngày", isOn: $updater.autoCheck)
                .font(.callout)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle: Text("Bản cập nhật lấy từ GitHub.").foregroundStyle(.secondary)
        case .checking: Text("Đang kiểm tra…").foregroundStyle(.secondary)
        case .upToDate: Label("Bạn đang dùng bản mới nhất", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let r): Label("Có bản mới \(r.version)", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading: Text("Đang tải bản mới…").foregroundStyle(.secondary)
        case .installing: Text("Đang cài đặt, MiniBox sẽ tự mở lại…").foregroundStyle(.secondary)
        case .failed(let e): Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }
}
