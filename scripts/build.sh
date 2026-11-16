#!/bin/bash
#
# 不依赖 Xcode / SwiftPM 的构建脚本：
#   用 clang + swiftc 交叉编译 arm64 与 x86_64，再用 lipo 合成通用二进制。
#
# 部署目标必须显式指定：否则二进制会把「构建机的系统版本」写成最低要求，
# 旧版本 macOS 会直接拒绝启动（“不能与此版本的 macOS 配合使用”）。
#
# 用法：
#   ./scripts/build.sh                  # release，通用二进制，最低 macOS 13.0
#   ./scripts/build.sh debug
#   MIN_OS=14.0 ./scripts/build.sh      # 指定最低系统
#   ARCHS="arm64" ./scripts/build.sh    # 只构建本机架构（更快）
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FLAVOR="${1:-release}"
MIN_OS="${MIN_OS:-13.0}"
ARCHS="${ARCHS:-arm64 x86_64}"

if [ "$FLAVOR" = "debug" ]; then
    OPT=(-Onone -g)
else
    OPT=(-O)
fi

BIN_ROOT="$ROOT/.build/bin"
DIST="$ROOT/dist"
BRIDGE="$ROOT/Sources/CSystemPower/include"
PLUGIN_PATH="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"
COMMON_FRAMEWORKS=(-framework IOKit -framework CoreFoundation)
UI_FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework Charts)

mkdir -p "$BIN_ROOT" "$DIST"

# ---------------------------------------------------------------------------
# 编译一个架构
# ---------------------------------------------------------------------------
build_arch() {
    local ARCH="$1"
    local TARGET="$ARCH-apple-macos$MIN_OS"
    local MC="$ROOT/.build/module-cache/$ARCH"
    local OBJ="$ROOT/.build/obj/$ARCH"
    local MOD="$ROOT/.build/mod/$ARCH"
    local BIN="$BIN_ROOT/$ARCH"
    local CMOD="$ROOT/.build/cmodule/$ARCH"

    mkdir -p "$MC" "$OBJ" "$MOD" "$BIN" "$CMOD/CSystemPower" \
             "$OBJ/core" "$OBJ/ui" "$OBJ/app" "$OBJ/probe" "$OBJ/snapshot"
    cat > "$CMOD/CSystemPower/module.modulemap" <<EOF
module CSystemPower {
    header "$BRIDGE/CSystemPower.h"
    export *
}
EOF

    local SWIFT_FLAGS=(
        -module-cache-path "$MC"
        "${OPT[@]}"
        -swift-version 5
        -target "$TARGET"
        -gline-tables-only
        -suppress-warnings
        -plugin-path "$PLUGIN_PATH"
        -I "$CMOD"
    )

    echo "==> [$ARCH] 1/6 C 桥接层"
    clang -c -O2 -arch "$ARCH" -mmacosx-version-min="$MIN_OS" \
        -fmodules-cache-path="$MC" \
        -I "$BRIDGE" \
        "$ROOT/Sources/CSystemPower/CSystemPower.c" \
        -o "$OBJ/CSystemPower.o"

    echo "==> [$ARCH] 2/6 WattMeterCore"
    (
        cd "$OBJ/core"
        swiftc "${SWIFT_FLAGS[@]}" -c -module-name WattMeterCore \
            -emit-module -emit-module-path "$MOD/WattMeterCore.swiftmodule" \
            "$ROOT"/Sources/WattMeterCore/*.swift
    )

    echo "==> [$ARCH] 3/6 WattMeterUI"
    (
        cd "$OBJ/ui"
        swiftc "${SWIFT_FLAGS[@]}" -c -module-name WattMeterUI \
            -emit-module -emit-module-path "$MOD/WattMeterUI.swiftmodule" \
            -I "$MOD" \
            "$ROOT"/Sources/WattMeterUI/*.swift
    )

    echo "==> [$ARCH] 4/6 App / 探针 / 预览工具"
    (
        cd "$OBJ/app"
        swiftc "${SWIFT_FLAGS[@]}" -c -module-name WattMeter -I "$MOD" \
            "$ROOT"/Sources/WattMeter/*.swift
    )
    (
        cd "$OBJ/probe"
        swiftc "${SWIFT_FLAGS[@]}" -c -module-name wattprobe -I "$MOD" \
            "$ROOT/Sources/wattprobe/main.swift"
    )
    (
        cd "$OBJ/snapshot"
        swiftc "${SWIFT_FLAGS[@]}" -c -module-name wattmeter_snapshot -I "$MOD" \
            "$ROOT/Sources/wattmeter-snapshot/main.swift"
    )

    echo "==> [$ARCH] 5/6 链接"
    swiftc -module-cache-path "$MC" -target "$TARGET" -o "$BIN/WattMeter" \
        "$OBJ"/app/*.o "$OBJ"/ui/*.o "$OBJ"/core/*.o "$OBJ"/CSystemPower.o \
        "${COMMON_FRAMEWORKS[@]}" "${UI_FRAMEWORKS[@]}"

    swiftc -module-cache-path "$MC" -target "$TARGET" -o "$BIN/wattprobe" \
        "$OBJ"/probe/*.o "$OBJ"/core/*.o "$OBJ"/CSystemPower.o \
        "${COMMON_FRAMEWORKS[@]}"

    swiftc -module-cache-path "$MC" -target "$TARGET" -o "$BIN/wattmeter-snapshot" \
        "$OBJ"/snapshot/*.o "$OBJ"/ui/*.o "$OBJ"/core/*.o "$OBJ"/CSystemPower.o \
        "${COMMON_FRAMEWORKS[@]}" "${UI_FRAMEWORKS[@]}"

    echo "==> [$ARCH] 6/6 完成"
}

# ---------------------------------------------------------------------------
# 逐架构编译
# ---------------------------------------------------------------------------
echo "==> 目标：macOS $MIN_OS+，架构：$ARCHS"
rm -rf "$ROOT/.build/obj"
for ARCH in $ARCHS; do
    build_arch "$ARCH"
done

# ---------------------------------------------------------------------------
# lipo 合成通用二进制
# ---------------------------------------------------------------------------
echo "==> 合成通用二进制"
lipo_merge() {
    local NAME="$1"
    local OUT="$2"
    local INPUTS=()
    for ARCH in $ARCHS; do
        INPUTS+=("$BIN_ROOT/$ARCH/$NAME")
    done
    if [ "${#INPUTS[@]}" -eq 1 ]; then
        cp "${INPUTS[0]}" "$OUT"
    else
        lipo -create "${INPUTS[@]}" -output "$OUT"
    fi
}

APP_BUNDLE="$DIST/WattMeter.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

lipo_merge WattMeter "$APP_BUNDLE/Contents/MacOS/WattMeter"
lipo_merge wattprobe "$BIN_ROOT/wattprobe"
lipo_merge wattmeter-snapshot "$BIN_ROOT/wattmeter-snapshot"

cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$APP_BUNDLE/Contents/MacOS/WattMeter"

# 应用图标（首次构建时生成，之后直接复用）
if [ ! -f "$ROOT/Resources/WattMeter.icns" ]; then
    ARCHS=arm64 "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/Resources/WattMeter.icns" "$APP_BUNDLE/Contents/Resources/WattMeter.icns"

codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>/dev/null || \
    echo "（codesign 跳过，本机仍可运行）"

# ---------------------------------------------------------------------------
# 结果校验
# ---------------------------------------------------------------------------
echo
echo "==> 校验"
lipo -info "$APP_BUNDLE/Contents/MacOS/WattMeter"
vtool -show-build "$APP_BUNDLE/Contents/MacOS/WattMeter" | grep -E 'platform|minos' | head -6

echo
echo "构建完成："
echo "  App     : $APP_BUNDLE"
echo "  探针    : $BIN_ROOT/wattprobe"
echo "  预览图  : $BIN_ROOT/wattmeter-snapshot --out preview.png"
echo
echo "运行：open \"$APP_BUNDLE\""
