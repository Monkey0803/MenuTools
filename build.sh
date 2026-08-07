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

# ===== 编译并嵌入 Finder 右键扩展（.appex）=====
EXT_NAME="RightClickTools"
APPEX="$APP_BUNDLE/Contents/PlugIns/$EXT_NAME.appex"
SDK=$(xcrun --show-sdk-path)
echo "==> 编译 Finder 扩展"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
# 扩展源 + 与主 App 共享的配置模型一起编译；入口 NSExtensionMain
swiftc Extension/*.swift Sources/MenuTools/RightClickConfig.swift \
    -sdk "$SDK" -target arm64-apple-macos26.0 \
    -framework FinderSync -framework AppKit \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/$EXT_NAME"
cp "Extension/Info.plist" "$APPEX/Contents/Info.plist"
# 扩展也带上多语言资源（右键菜单标题随系统语言）
for lproj in Resources/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APPEX/Contents/Resources/"
done

echo "==> 签名"
# 优先用稳定的自签名证书（使 TCC 权限授予可跨重编译保留）；未安装时回退 ad-hoc
SIGN_IDENTITY="MenuTools Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    SIGN_ARG=(--sign "$SIGN_IDENTITY")
else
    echo "   （未找到 '$SIGN_IDENTITY' 证书，回退 ad-hoc 签名）"
    SIGN_ARG=(--sign -)
fi
# 必须先签内嵌扩展，再签外层 App（否则封装校验失败）
# 扩展必须开启沙箱（pkd 硬性要求）+ App Group（与主 App 共享配置）
codesign --force "${SIGN_ARG[@]}" --entitlements Extension/RightClickTools.entitlements "$APPEX"
codesign --force "${SIGN_ARG[@]}" --entitlements Resources/MenuTools.entitlements "$APP_BUNDLE"

# 清理残留的旧扩展进程：替换 App 后 Finder 可能同时连着新旧两个实例，导致右键菜单出现两个 MenuTools
if pgrep -f "RightClickTools.appex" >/dev/null 2>&1; then
    echo "==> 清理旧 Finder 扩展进程并重启 Finder"
    pkill -f "RightClickTools.appex" || true
    killall Finder 2>/dev/null || true
fi

echo "==> 完成：$APP_BUNDLE"
