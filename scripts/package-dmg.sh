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

cat > "$STAGE/INSTALL.txt" <<'TXT'
WattMeter — installation
========================

1. Drag WattMeter.app into the Applications folder on the right.
2. On first launch, if macOS says the developer cannot be verified,
   right-click WattMeter in Applications and choose Open, or run:

       xattr -dr com.apple.quarantine /Applications/WattMeter.app

3. A live power reading (e.g. 12.3W) appears in the menu bar.
   Click it to open the panel. Right-click it for the main window,
   launch at login, language and quit.
4. To quit: right-click the menu bar reading, then Quit WattMeter.

Requirements: macOS 13 or later, Apple Silicon or Intel.
The app reads data locally only: no network access, no root required.

------------------------------------------------------------
简体中文
------------------------------------------------------------

1. 把 WattMeter.app 拖到右侧的 Applications（应用程序）文件夹。
2. 首次打开若提示「无法验证开发者」，在「应用程序」里右键 WattMeter → 打开，
   或在终端执行：xattr -dr com.apple.quarantine /Applications/WattMeter.app
3. 菜单栏会出现实时功率（例如 12.3W），点击展开面板；
   右键可打开主窗口、开机启动、切换语言或退出。
4. 退出：右键菜单栏数字 →「退出 WattMeter」。

系统要求：macOS 13 及以上，Apple Silicon 或 Intel。
仅在本机读取数据，不联网、不需要 root。
TXT

DMG="$ROOT/dist/WattMeter-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "WattMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✅ Built: $DMG"
echo "   Open it and drag WattMeter.app into Applications."
