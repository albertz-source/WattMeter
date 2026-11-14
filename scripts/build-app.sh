#!/bin/bash
# 把 SwiftPM 产物组装成可双击运行的 .app（无需 Xcode）
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ROOT="$(pwd)"
MODULE_CACHE="$ROOT/.build/module-cache"
mkdir -p "$MODULE_CACHE"

echo "==> 编译（$CONFIG）"
swift build -c "$CONFIG" \
    --product WattMeter \
    -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/WattMeter.app"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WattMeter" "$APP/Contents/MacOS/WattMeter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/WattMeter"

# 本地 ad-hoc 签名；对外分发需要 Developer ID 签名 + 公证
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
    echo "（跳过 codesign：$APP 仍可本机运行）"

echo
echo "构建完成：$APP"
echo "运行：open \"$APP\""
