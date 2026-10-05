# Kiến trúc MiniBox

MiniBox là app SwiftUI thuần (macOS 14+), build bằng Swift Package Manager — không có tệp dự án Xcode. `build.sh` ghép tệp chạy với `Resources/Info.plist` thành `MiniBox.app`.

```
Package.swift
build.sh                  build universal + đóng gói MiniBox.zip
install.sh                trình cài đặt (tải bản mới nhất từ GitHub Releases)
Resources/
  Info.plist
  AppIcon.icns            tạo bởi Scripts/make_icon.swift
  Logos/                  logo các trợ lý AI
Scripts/
  make_icon.swift         vẽ icon bằng AppKit
  release.sh              phát hành bản mới lên GitHub
Sources/MiniBox/          toàn bộ mã nguồn
```

## Luồng chính

- `MiniBoxApp.swift` — điểm vào, cửa sổ chính (`NavigationSplitView`), menu, thanh menu, cửa sổ Cài đặt. Lần đầu chạy sẽ chuyển dữ liệu từ thư mục cũ `Noter/` sang `MiniBox/`.
- `Store.swift` — dữ liệu chính (ghi chú, danh mục, trắc nghiệm, thời khoá biểu), lưu một tệp `data.json`, tự ghi sau mỗi thay đổi (debounce). Nếu tệp hỏng, sao lưu trước khi ghi đè.
- `Features.swift` — bật/tắt từng mục trên sidebar.
- `SidebarView.swift`, `SettingsView.swift` — sidebar và cửa sổ Cài đặt.

## Theo tính năng

| Tệp | Nội dung |
|---|---|
| `Models.swift`, `NoteListView.swift`, `NoteEditor.swift`, `Notifier.swift` | Ghi chú, nhắc nhở (UserNotifications) |
| `Timetable.swift` | Thời khoá biểu: lưới tuần, kéo thả, nhắc giờ học lặp hằng tuần |
| `FocusTimer.swift`, `FocusView.swift` | Pomodoro |
| `Quiz*.swift` | Trắc nghiệm: prompt mẫu, đọc JSON/chữ từ AI, làm bài |
| `AI.swift` | Trợ lý AI nhúng `WKWebView` (mỗi dịch vụ một trang, giữ đăng nhập) |
| `Storage*.swift`, `FileViewers.swift` | Thư viện tài liệu, PDFKit, trình xem ảnh, Quick Look |
| `GameBox.swift` | Phiên chơi game có hẹn giờ |
| `Music.swift` | Thư viện nhạc, tải bằng yt-dlp, trình phát (AVPlayer, phím media) |
| `MusicCatalog.swift` | Tìm kiếm: YouTube Music (InnerTube), SoundCloud API v2, API riêng |
| `MusicHome.swift` | Trang chủ kiểu Spotify: gợi ý, mix, bảng xếp hạng, trang playlist/nghệ sĩ |
| `MusicView.swift`, `SpotifyUI.swift`, `Lyrics.swift` | Giao diện kiểu Spotify, lời bài hát LRCLIB |
| `Discord.swift` | Discord Rich Presence qua IPC cục bộ |
| `Updater.swift` | Tự cập nhật từ GitHub Releases |

## Tự cập nhật

1. `Updater` gọi `GET /repos/not2pixel/MiniBox/releases/latest`, so `tag_name` (vd. `v1.1.0`) với `CFBundleShortVersionString`.
2. Có bản mới → tải asset `MiniBox.zip`, giải nén bằng `ditto`, kiểm tra bundle identifier.
3. Ghi một script nhỏ chờ MiniBox thoát, đổi app (giữ bản cũ nếu lỗi), xoá cờ quarantine rồi mở lại.

Vì vậy mỗi Release **phải** có tag dạng `vX.Y.Z` và tệp `MiniBox.zip` — `Scripts/release.sh` làm sẵn việc này.

## Lưu trữ

```
~/Library/Application Support/MiniBox/
  data.json               ghi chú, danh mục, trắc nghiệm, thời khoá biểu
  Storage/                thư viện tài liệu
  Music/
    library.json          danh sách bài & playlist
    Tracks/  Artwork/  Lyrics/
    bin/ytdlp/            yt-dlp (tải khi người dùng bấm cài)
```
