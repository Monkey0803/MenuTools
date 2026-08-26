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

# 菜单栏应用不会随着 .app 文件替换而自动重新加载，先结束同路径的旧实例，
# 否则菜单栏仍可能连接到旧进程，导致重新构建后的点击行为看起来没有变化。
if pgrep -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "==> 关闭旧的 $APP_NAME 实例"
    pkill -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" || true
    sleep 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Sparkle 的 SPM 二进制包不会自动嵌入最终的手工组装 App，需要把完整
# Sparkle.framework（包含 Autoupdate、Updater.app 和 XPCServices）放入
# Frameworks，并为主程序补上 App Bundle 内的运行时搜索路径。
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "错误：未找到 Sparkle.framework：$SPARKLE_FRAMEWORK" >&2
    exit 1
fi
mkdir -p "$FRAMEWORKS_DIR"
cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 默认使用 Info.plist 中已公开的 Ed25519 公钥；密钥轮换或正式构建时也可以
# 通过 SPARKLE_PUBLIC_ED_KEY 覆盖，私钥始终只保存在钥匙串或本地 .cert/ 中。
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
    fi
fi

# App 图标（若已生成）
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 本地化资源（多语言 Localizable.strings）
for lproj in Resources/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

# 随二进制分发第三方许可声明。Sparkle LICENSE 来自固定版本的 SPM artifact，
# 避免手工复制后与实际嵌入版本不一致。
if [[ -f "THIRD_PARTY_NOTICES.md" ]]; then
    cp "THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/"
fi
SPARKLE_LICENSE=".build/artifacts/sparkle/Sparkle/LICENSE"
if [[ ! -f "$SPARKLE_LICENSE" ]]; then
    echo "错误：未找到 Sparkle LICENSE：$SPARKLE_LICENSE" >&2
    exit 1
fi
cp "$SPARKLE_LICENSE" "$APP_BUNDLE/Contents/Resources/Sparkle-LICENSE.txt"

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
# 正式发布通过 CODESIGN_IDENTITY 显式传入 Developer ID；普通本地构建继续优先使用稳定的自签名证书。
SIGN_IDENTITY="${CODESIGN_IDENTITY:-MenuTools Self-Signed}"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    if ! security find-identity -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
        echo "错误：未找到签名证书 '$SIGN_IDENTITY'" >&2
        exit 1
    fi
    SIGN_ARG=(--sign "$SIGN_IDENTITY")
elif security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    SIGN_ARG=(--sign "$SIGN_IDENTITY")
else
    echo "   （未找到 '$SIGN_IDENTITY' 证书，回退 ad-hoc 签名）"
    SIGN_ARG=(--sign -)
fi
# 必须先签内嵌扩展，再签外层 App（否则封装校验失败）
# 扩展必须开启沙箱（pkd 硬性要求）+ App Group（与主 App 共享配置）
codesign --force --deep "${SIGN_ARG[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force "${SIGN_ARG[@]}" --entitlements Extension/RightClickTools.entitlements "$APPEX"
codesign --force "${SIGN_ARG[@]}" --entitlements Resources/MenuTools.entitlements "$APP_BUNDLE"

# 清理残留的旧扩展进程：替换 App 后 Finder 可能同时连着新旧两个实例，导致右键菜单出现两个 MenuTools
if pgrep -f "RightClickTools.appex" >/dev/null 2>&1; then
    echo "==> 清理旧 Finder 扩展进程并重启 Finder"
    pkill -f "RightClickTools.appex" || true
    killall Finder 2>/dev/null || true
fi

echo "==> 启动：$APP_BUNDLE"
open "$APP_BUNDLE"
echo "==> 完成：$APP_BUNDLE"
