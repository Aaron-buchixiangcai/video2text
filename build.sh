#!/bin/bash
# 构建并打包 视频转文字.app
# 用法: bash build.sh [--install]   --install 同时复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
if ! swift build -c release 2>&1 | tail -3; then
    if [ -d /Applications/Xcode.app ]; then
        echo "==> CLT 构建失败，改用完整 Xcode 工具链重试"
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release | tail -3
    else
        # 新版 SDK 里 SwiftUI 的 @State 等依赖宏插件，插件只随 Xcode 提供；
        # 没装 Xcode 时改用命令行工具自带的旧版 SDK
        OLD_SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
        echo "==> 未安装 Xcode，改用 $OLD_SDK 重试"
        SDKROOT="$OLD_SDK" swift build -c release | tail -3
    fi
fi

# 在 /tmp（非 iCloud 托管）里组装并签名：桌面/文稿等 iCloud 目录会不断给 .app 根目录
# 加回 com.apple.FinderInfo 扩展属性，导致 codesign 报 "detritus not allowed"。
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/视频转文字.app"
echo "==> 组装 $STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/Video2Text "$STAGE/Contents/MacOS/Video2Text"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

# 图标（可选）：Resources/AppIcon.png -> AppIcon.icns
if [ -f Resources/AppIcon.png ]; then
    echo "==> 生成图标"
    ICONSET="$STAGE_ROOT/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size*2)) $((size*2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
fi

echo "==> 清理扩展属性并 ad-hoc 签名"
xattr -cr "$STAGE"
codesign --force --deep -s - "$STAGE"
codesign -v "$STAGE" && echo "签名校验通过"

APP="dist/视频转文字.app"
echo "==> 交付到 $APP"
mkdir -p dist
rm -rf "$APP"
cp -R "$STAGE" "$APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/视频转文字.app"
    cp -R "$STAGE" "/Applications/视频转文字.app"
fi

rm -rf "$STAGE_ROOT"
echo "==> 完成: $APP"
