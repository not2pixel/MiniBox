#!/bin/zsh
# Build MiniBox.app (universal: Apple Silicon + Intel) và đóng gói build/MiniBox.zip
# Dùng: ./build.sh            → build
#       ./build.sh --install  → build rồi cài vào /Applications
set -e
cd "$(dirname "$0")"

echo "→ Build Apple Silicon (arm64)…"
swift build -c release --triple arm64-apple-macosx14.0
echo "→ Build Intel (x86_64)…"
swift build -c release --triple x86_64-apple-macosx14.0
[ -f Resources/AppIcon.icns ] || swift Scripts/make_icon.swift Resources/AppIcon.icns

APP=build/MiniBox.app
rm -rf "$APP" build/MiniBox.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/MiniBox" \
  "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/MiniBox" \
  -output "$APP/Contents/MacOS/MiniBox"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Logos "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/MiniBox"
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/MiniBox.zip
echo "✓ $APP ($(du -sh "$APP" | cut -f1)) · $(lipo -archs "$APP/Contents/MacOS/MiniBox")"
echo "✓ build/MiniBox.zip ($(du -h build/MiniBox.zip | cut -f1))"

if [ "$1" = "--install" ]; then
  pkill -x MiniBox 2>/dev/null && sleep 1 || true
  rm -rf /Applications/MiniBox.app
  cp -R "$APP" /Applications/
  echo "✓ Đã cài vào /Applications"
fi
