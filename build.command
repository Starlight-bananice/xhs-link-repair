#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/小红书链接修复.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

mkdir -p "$MACOS_DIR"

swiftc \
  -target arm64-apple-macosx13.0 \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  "$SCRIPT_DIR"/Sources/*.swift \
  -o "$MACOS_DIR/XHSLinkRepair"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$MACOS_DIR/XHSLinkRepair"
# 固定 designated requirement。默认临时签名会把每次构建的 CDHash 当作身份，
# 导致 macOS 辅助功能权限在更新后看似开启、实际却不再匹配。
codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "com.starlightbananice.xhslinkrepair"' \
  "$APP_DIR"

echo "构建完成：$APP_DIR"
