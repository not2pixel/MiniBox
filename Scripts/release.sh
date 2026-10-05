#!/bin/zsh
# Phát hành bản mới lên GitHub Releases (cần GitHub CLI: brew install gh && gh auth login)
#   Scripts/release.sh 1.1.0
# - Đặt số phiên bản trong Info.plist
# - Build universal + đóng gói build/MiniBox.zip
# - Commit, tạo tag v1.1.0, push, tạo Release kèm MiniBox.zip và Install-MiniBox.command
# Ghi chú phát hành lấy từ mục tương ứng trong CHANGELOG.md.
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Dùng: Scripts/release.sh 1.2.3"; exit 1; }
command -v gh >/dev/null || { echo "Cần GitHub CLI: brew install gh && gh auth login"; exit 1; }

BUILD=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist

./build.sh

# Trình cài đặt dạng nhấp đúp
cp install.sh build/Install-MiniBox.command
chmod +x build/Install-MiniBox.command

# Ghi chú phát hành: đoạn "## [VERSION]" trong CHANGELOG.md
NOTES=$(awk -v v="## [$VERSION]" 'index($0, v)==1 {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)
[ -n "$NOTES" ] || NOTES="MiniBox $VERSION"

git add -A
git commit -m "Release v$VERSION" || true
git tag -a "v$VERSION" -m "MiniBox $VERSION"
git push origin HEAD --follow-tags

gh release create "v$VERSION" build/MiniBox.zip build/Install-MiniBox.command \
  --title "MiniBox $VERSION" --notes "$NOTES"
echo "✓ Đã phát hành MiniBox $VERSION"
