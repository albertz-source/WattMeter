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

cat > "$STAGE/安装说明.txt" <<'TXT'
WattMeter 安装方法

1. 把 WattMeter.app 拖到右侧的 Applications（应用程序）文件夹。
2. 首次打开若提示「无法验证开发者」，在「应用程序」里右键 WattMeter → 打开；
   或在终端执行：xattr -dr com.apple.quarantine /Applications/WattMeter.app
3. 启动后菜单栏会出现实时功率（例如 12.3W），点击即可展开面板。
4. 退出：右键菜单栏数字 →「退出 WattMeter」。
TXT

DMG="$ROOT/dist/WattMeter-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "WattMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✅ 已生成：$DMG"
echo "   双击挂载后，把 WattMeter.app 拖进 Applications 即可。"
