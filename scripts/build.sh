#!/bin/bash
#
# 不依赖 Xcode / SwiftPM 的构建脚本：
#   直接用 clang + swiftc 编译 C 桥接层和 Swift 模块，再组装成 .app。
#
# 用法：./scripts/build.sh [release|debug]
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FLAVOR="${1:-release}"

if [ "$FLAVOR" = "debug" ]; then
    OPT=(-Onone -g)
else
    OPT=(-O)
fi

MC="$ROOT/.build/module-cache"
OBJ="$ROOT/.build/obj"
MOD="$ROOT/.build/mod"
DIST="$ROOT/dist"
BIN="$ROOT/.build/bin"

mkdir -p "$MC" "$OBJ" "$MOD" "$DIST" "$BIN"

SWIFT_FLAGS=(-module-cache-path "$MC" "${OPT[@]}" -swift-version 5 -gline-tables-only -suppress-warnings \
    -plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins)
BRIDGE="$ROOT/Sources/CSystemPower/include"
COMMON_FRAMEWORKS=(-framework IOKit -framework CoreFoundation)

# 为 clang 模块生成 module.modulemap，让 Swift 可以 `import CSystemPower`
CMOD="$ROOT/.build/cmodule"
mkdir -p "$CMOD/CSystemPower"
cat > "$CMOD/CSystemPower/module.modulemap" <<EOF
module CSystemPower {
    header "$BRIDGE/CSystemPower.h"
    export *
}
EOF
SWIFT_FLAGS+=(-I "$CMOD")

echo "==> 1/6 编译 C 桥接层"
mkdir -p "$OBJ/CSystemPower"
clang -c -O2 -fmodules-cache-path="$MC" \
    -I "$BRIDGE" \
    "$ROOT/Sources/CSystemPower/CSystemPower.c" \
    -o "$OBJ/CSystemPower/CSystemPower.o"

echo "==> 2/6 编译 WattMeterCore"
mkdir -p "$OBJ/core"
(
    cd "$OBJ/core"
    swiftc "${SWIFT_FLAGS[@]}" -c -module-name WattMeterCore \
        -emit-module -emit-module-path "$MOD/WattMeterCore.swiftmodule" \
        "$ROOT"/Sources/WattMeterCore/*.swift
)

echo "==> 3/6 编译 WattMeterUI"
mkdir -p "$OBJ/ui"
(
    cd "$OBJ/ui"
    swiftc "${SWIFT_FLAGS[@]}" -c -module-name WattMeterUI \
        -emit-module -emit-module-path "$MOD/WattMeterUI.swiftmodule" \
        -I "$MOD" \
        "$ROOT"/Sources/WattMeterUI/*.swift
)

echo "==> 4/6 编译菜单栏 App"
mkdir -p "$OBJ/app"
(
    cd "$OBJ/app"
    swiftc "${SWIFT_FLAGS[@]}" -c -module-name WattMeter \
        -I "$MOD" \
        "$ROOT"/Sources/WattMeter/*.swift
)

echo "==> 5/6 链接 App / 探针 / 预览工具"
APP_BUNDLE="$DIST/WattMeter.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swiftc -module-cache-path "$MC" -o "$APP_BUNDLE/Contents/MacOS/WattMeter" \
    "$OBJ"/app/*.o "$OBJ"/ui/*.o "$OBJ"/core/*.o "$OBJ"/CSystemPower/*.o \
    "${COMMON_FRAMEWORKS[@]}" -framework AppKit -framework SwiftUI -framework Charts

cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$APP_BUNDLE/Contents/MacOS/WattMeter"

# 应用图标（首次构建时生成，之后直接复用）
if [ ! -f "$ROOT/Resources/WattMeter.icns" ]; then
    "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/Resources/WattMeter.icns" "$APP_BUNDLE/Contents/Resources/WattMeter.icns"

# CLI 探针
mkdir -p "$OBJ/probe"
(
    cd "$OBJ/probe"
    swiftc "${SWIFT_FLAGS[@]}" -c -module-name wattprobe \
        -I "$MOD" \
        "$ROOT/Sources/wattprobe/main.swift"
)
swiftc -module-cache-path "$MC" -o "$BIN/wattprobe" \
    "$OBJ"/probe/*.o "$OBJ"/core/*.o "$OBJ"/CSystemPower/*.o \
    "${COMMON_FRAMEWORKS[@]}"

# 离屏预览工具
mkdir -p "$OBJ/snapshot"
(
    cd "$OBJ/snapshot"
    swiftc "${SWIFT_FLAGS[@]}" -c -module-name wattmeter_snapshot \
        -I "$MOD" \
        "$ROOT/Sources/wattmeter-snapshot/main.swift"
)
swiftc -module-cache-path "$MC" -o "$BIN/wattmeter-snapshot" \
    "$OBJ"/snapshot/*.o "$OBJ"/ui/*.o "$OBJ"/core/*.o "$OBJ"/CSystemPower/*.o \
    "${COMMON_FRAMEWORKS[@]}" -framework AppKit -framework SwiftUI -framework Charts

echo "==> 6/6 ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>/dev/null || \
    echo "（codesign 跳过，本机仍可运行）"

echo
echo "构建完成："
echo "  App     : $APP_BUNDLE"
echo "  探针    : $BIN/wattprobe"
echo "  预览图  : $BIN/wattmeter-snapshot --out preview.png"
echo
echo "运行：open \"$APP_BUNDLE\""
