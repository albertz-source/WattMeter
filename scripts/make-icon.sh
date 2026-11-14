#!/bin/bash
# 生成 Resources/WattMeter.icns（多尺寸 PNG -> iconset -> iconutil）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
MC="$ROOT/.build/module-cache"
BIN="$ROOT/.build/bin"
mkdir -p "$MC" "$BIN"

swiftc -module-cache-path "$MC" -swift-version 5 -O \
    -o "$BIN/make-icon" \
    "$ROOT/scripts/make-icon.swift" \
    -framework AppKit

rm -rf "$ROOT/.build/WattMeter.iconset"
"$BIN/make-icon" "$ROOT/.build/WattMeter.iconset"

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ROOT/.build/WattMeter.iconset" -o "$ROOT/Resources/WattMeter.icns"
echo "icon: $ROOT/Resources/WattMeter.icns"
