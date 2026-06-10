#!/bin/bash
# 构建并打包 视频转文字.app
# 用法: bash build.sh [--install]   --install 同时复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
if ! swift build -c release 2>&1 | tail -3; then
    echo "==> CLT 构建失败，改用完整 Xcode 工具链重试"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release | tail -3
fi

APP="dist/视频转文字.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Video2Text "$APP/Contents/MacOS/Video2Text"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 图标（可选）：Resources/AppIcon.png -> AppIcon.icns
if [ -f Resources/AppIcon.png ]; then
    echo "==> 生成图标"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size*2)) $((size*2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc 签名"
codesign --force --deep -s - "$APP"

echo "==> 完成: $APP"
if [ "${1:-}" = "--install" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/视频转文字.app"
    cp -R "$APP" "/Applications/视频转文字.app"
fi
