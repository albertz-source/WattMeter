#!/bin/bash
# 打包成可拖拽安装的 DMG：WattMeter.app + Applications 快捷方式
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo 1.0.0)"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    ./scripts/build.sh release
fi

APP="$ROOT/dist/WattMeter.app"
if [ ! -d "$APP" ]; then
    echo "找不到 $APP，请先运行 ./scripts/build.sh release" >&2
    exit 1
fi

STAGE="$ROOT/.build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/WattMeter.app"
ln -s /Applications "$STAGE/Applications"

# 安装说明放在仓库 Resources/INSTALL.txt（可编辑），打包时复制进 DMG
INSTALL_NOTE="$ROOT/Resources/INSTALL.txt"
if [ ! -f "$INSTALL_NOTE" ]; then
    echo "missing $INSTALL_NOTE" >&2
    exit 1
fi
cp "$INSTALL_NOTE" "$STAGE/INSTALL.txt"

DMG="$ROOT/dist/WattMeter-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "WattMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✅ Built: $DMG"
echo "   Open it and drag WattMeter.app into Applications."
