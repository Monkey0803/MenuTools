#!/bin/zsh
# 构建 MenuTools.app —— 编译 SPM 可执行文件并打包成 .app Bundle
#
# 构建完成后默认会**安装到 /Applications**：Finder 只加载 /Applications 里那份
# Finder 扩展（appex），只产出 dist 会出现"改了扩展却看不到效果"。用
# `./build.sh --no-install` 可以只构建不安装。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

# 参数：release/debug（可选）+ --no-install（可选），顺序不限
CONFIG="release"
DO_INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --no-install) DO_INSTALL=0 ;;
        release|debug) CONFIG="$arg" ;;
        *) echo "未知参数：$arg（可用：release|debug --no-install）" >&2; exit 2 ;;
    esac
done

APP_NAME="MenuTools"
BUILD_DIR=".build/$CONFIG"
OUT_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"

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

# 应用内更新说明（设置页显示发布日期与更新内容）
if [[ -f "Resources/ReleaseNotes.md" ]]; then
    cp "Resources/ReleaseNotes.md" "$APP_BUNDLE/Contents/Resources/ReleaseNotes.md"
fi

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
# 必须用 `--sdk macosx` 指定 SDK：裸 `xcrun --show-sdk-path` 返回的是
# CommandLineTools 的 SDK，它可能由另一套工具链的编译器构建。一旦 macOS 大版本
# 升级后 CLT 与当前活动 Xcode 不同套，扩展编译会报 “SDK is not supported by
# the compiler”，而主程序走 SwiftPM（解析出一致的 SDK）却能正常编译，
# 表现为「主程序编译成功、扩展编译失败」的迷惑现象。
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ ! -d "$SDK" ]]; then
    echo "错误：未找到 macOS SDK：$SDK" >&2
    echo "      可用 DEVELOPER_DIR 指定完整工具链，例如：" >&2
    echo "      DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0" >&2
    exit 1
fi
echo "==> 编译 Finder 扩展（SDK: $SDK）"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
# 扩展源 + 与主 App 共享的配置模型/菜单构建一起编译；入口 NSExtensionMain
# 性能监控与日志被 FinderSyncExtension 直接调用，必须一并编入扩展。
# 与主程序一致开启 Swift 6 语言模式：扩展已按严格并发检查收敛，新代码不得回退。
swiftc Extension/*.swift Sources/MenuTools/RightClickApplicationFilter.swift Sources/MenuTools/RightClickConfig.swift Sources/MenuTools/RightClickMenuPolicy.swift Sources/MenuTools/RightClickExtensionSupport.swift Sources/MenuTools/TerminalApp.swift Sources/MenuTools/Services/RightClickPerformanceMonitor.swift Sources/MenuTools/Services/RightClickLogger.swift \
    -swift-version 6 \
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

if [[ "$DO_INSTALL" == "1" ]]; then
    if [[ ! -w "$INSTALL_DIR" ]]; then
        echo "错误：$INSTALL_DIR 不可写，无法安装扩展；可用 ./build.sh --no-install 只构建" >&2
        exit 1
    fi
    echo "==> 安装到 $INSTALL_APP"
    # 先结束 /Applications 里的旧实例，否则替换 bundle 后菜单栏仍连着旧进程
    pkill -f "$INSTALL_APP/Contents/MacOS/$APP_NAME" || true
    sleep 1
    rm -rf "$INSTALL_APP"
    ditto "$APP_BUNDLE" "$INSTALL_APP"
    if codesign --verify --deep --strict "$INSTALL_APP" 2>/dev/null; then
        echo "    签名校验通过"
    else
        echo "    警告：签名校验未通过，扩展可能不被系统加载" >&2
    fi
    # 同一 extension identifier 同时注册 dist 与 /Applications 两份时，
    # Finder 可能直接不加载扩展；这里把 dist 那份从 pkd 数据库里摘掉。
    pluginkit -r "$APP_BUNDLE/Contents/PlugIns/$EXT_NAME.appex" >/dev/null 2>&1 || true
    echo "==> 重启 Finder 扩展进程与 Finder"
    pkill -f "$EXT_NAME.appex" || true
    killall Finder 2>/dev/null || true
    LAUNCH_APP="$INSTALL_APP"
else
    # 不安装时仍需清理旧扩展进程：替换 dist 后 Finder 可能同时连着新旧实例
    if pgrep -f "$EXT_NAME.appex" >/dev/null 2>&1; then
        echo "==> 清理旧 Finder 扩展进程并重启 Finder"
        pkill -f "$EXT_NAME.appex" || true
        killall Finder 2>/dev/null || true
    fi
    LAUNCH_APP="$APP_BUNDLE"
fi

echo "==> 启动：$LAUNCH_APP"
open "$LAUNCH_APP"
echo "==> 完成：$LAUNCH_APP"
