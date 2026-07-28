#!/bin/zsh
# 构建 MenuTools.app —— 编译 SPM 可执行文件并打包成 .app Bundle
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

CONFIG="${1:-release}"
APP_NAME="MenuTools"
BUILD_DIR=".build/$CONFIG"
OUT_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# App 图标（若已生成）
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 本地化资源（多语言 Localizable.strings）
for lproj in Resources/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

echo "==> 签名"
# 优先用稳定的自签名证书（使 TCC 权限授予可跨重编译保留）；未安装时回退 ad-hoc
SIGN_IDENTITY="MenuTools Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "   （未找到 '$SIGN_IDENTITY' 证书，回退 ad-hoc 签名）"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> 完成：$APP_BUNDLE"
