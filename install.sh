#!/bin/bash
# Trình cài đặt MiniBox — tải bản mới nhất từ GitHub Releases và cài vào máy.
#   curl -fsSL https://raw.githubusercontent.com/not2pixel/MiniBox/main/install.sh | bash
set -euo pipefail

REPO="not2pixel/MiniBox"
APP="MiniBox.app"

bold=$'\e[1m'; green=$'\e[32m'; red=$'\e[31m'; dim=$'\e[2m'; reset=$'\e[0m'
step() { echo "${bold}→${reset} $*"; }
fail() { echo "${red}✗ $*${reset}" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "MiniBox chỉ chạy trên macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "MiniBox cần macOS 14 Sonoma trở lên (máy bạn: $(sw_vers -productVersion))."

step "Đang tìm bản MiniBox mới nhất…"
json=$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest") \
  || fail "Không kết nối được GitHub."
url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*/MiniBox\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
tag=$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
[ -n "$url" ] || fail "Chưa có bản phát hành nào có tệp MiniBox.zip."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
step "Đang tải MiniBox ${tag}…"
curl -fL --progress-bar "$url" -o "$tmp/MiniBox.zip"
ditto -x -k "$tmp/MiniBox.zip" "$tmp"
[ -d "$tmp/$APP" ] || fail "Gói tải về không hợp lệ."

dest="/Applications"
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"
  mkdir -p "$dest"
fi

if pgrep -x MiniBox >/dev/null; then
  step "Đang đóng MiniBox đang chạy…"
  osascript -e 'quit app "MiniBox"' >/dev/null 2>&1 || pkill -x MiniBox || true
  sleep 1
fi

step "Đang cài vào $dest…"
rm -rf "$dest/$APP"
mv "$tmp/$APP" "$dest/"
xattr -cr "$dest/$APP" 2>/dev/null || true

echo "${green}✓ Đã cài MiniBox ${tag} vào $dest${reset}"
echo "${dim}  MiniBox sẽ tự kiểm tra và cập nhật bản mới (Cài đặt → Chung → Cập nhật).${reset}"
open "$dest/$APP"
