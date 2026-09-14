#!/bin/zsh
# MenuTools 发布预检与打包。
#
#   RELEASE_MODE=github（默认）：自签名 + ZIP/DMG + Sparkle appcast，不做 notarization。
#                               用于 GitHub 开源分发；源码压缩包由 GitHub 按 tag 自动提供。
#   RELEASE_MODE=developer-id：Developer ID 签名 + notarization + stapling，需要 Apple 开发者凭据。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

APP_NAME="MenuTools"
OUT_DIR="$SCRIPT_DIR/dist"
INFO_PLIST="$SCRIPT_DIR/Resources/Info.plist"
RELEASE_MODE="${RELEASE_MODE:-github}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_PRIVATE_ED_KEY_FILE="${SPARKLE_PRIVATE_ED_KEY_FILE:-}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"

case "$RELEASE_MODE" in
github)
    # 自签名证书不需要被系统信任：用户首次打开按 README 的「首次打开」说明放行即可。
    SIGN_IDENTITY="${SIGN_IDENTITY:-MenuTools Self-Signed}"
    SPARKLE_PRIVATE_ED_KEY_FILE="${SPARKLE_PRIVATE_ED_KEY_FILE:-$SCRIPT_DIR/.cert/sparkle_ed25519_private_key}"
    ;;
developer-id)
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "错误：RELEASE_MODE=developer-id 必须设置 CODESIGN_IDENTITY（Developer ID Application）。" >&2
        exit 1
    fi
    if [[ -z "$NOTARY_PROFILE" ]]; then
        echo "错误：RELEASE_MODE=developer-id 必须设置 NOTARY_PROFILE（notarytool Keychain profile）。" >&2
        exit 1
    fi
    if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
        echo "错误：RELEASE_MODE=developer-id 必须设置 SPARKLE_PUBLIC_ED_KEY（Sparkle Ed25519 公钥）。" >&2
        exit 1
    fi
    if [[ -z "$SPARKLE_PRIVATE_ED_KEY_FILE" ]]; then
        echo "错误：RELEASE_MODE=developer-id 必须设置 SPARKLE_PRIVATE_ED_KEY_FILE（Sparkle Ed25519 私钥文件）。" >&2
        exit 1
    fi
    ;;
*)
    echo "错误：未知的 RELEASE_MODE='$RELEASE_MODE'，可选 github / developer-id。" >&2
    exit 1
    ;;
esac

if [[ ! -f "$SPARKLE_PRIVATE_ED_KEY_FILE" ]]; then
    echo "错误：未找到 Sparkle Ed25519 私钥文件：$SPARKLE_PRIVATE_ED_KEY_FILE" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]]; then
    echo "错误：版本号格式无效：$VERSION" >&2
    exit 1
fi
if [[ "$VERSION" != "$BUILD_VERSION" ]]; then
    echo "错误：CFBundleShortVersionString 与 CFBundleVersion 不一致。" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "错误：发布要求工作区干净，请先提交或处理以下变更：" >&2
    git status --short >&2
    exit 1
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
    echo "错误：未找到签名证书 '$SIGN_IDENTITY'。" >&2
    exit 1
fi

echo "==> 发布模式：$RELEASE_MODE（签名身份：$SIGN_IDENTITY，版本：$VERSION）"

echo "==> 运行测试"
swift test

echo "==> 构建并签名"
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
        CODESIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh release
else
    CODESIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh release
fi

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
ZIP_PATH="$OUT_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$OUT_DIR/$APP_NAME-$VERSION.dmg"

echo "==> 验证签名"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> 生成 ZIP 和 DMG"
rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# DMG 里附带「应用程序」快捷方式，用户拖进去即可安装。
DMG_STAGE="$OUT_DIR/dmg-stage-$VERSION"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGE"

if [[ "$RELEASE_MODE" == "developer-id" ]]; then
    echo "==> 提交 DMG notarization 并等待结果"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "==> 将 notarization ticket 固化到 App 和 DMG"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$APP_BUNDLE"
    xcrun stapler validate "$DMG_PATH"

    echo "==> 用已 stapled 的 App 重新生成 ZIP"
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
else
    echo "==> 跳过 notarization（github 模式：自签名分发）"
    echo "    Gatekeeper 不会接受自签名包，这是预期行为；用户按 README 的「首次打开」操作。"
fi

echo "==> 生成 Sparkle appcast"
SPARKLE_BIN_DIR="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "错误：未找到 Sparkle generate_appcast：$GENERATE_APPCAST" >&2
    exit 1
fi

APPCAST_ARCHIVES="$OUT_DIR/sparkle-archives-$VERSION"
rm -rf "$APPCAST_ARCHIVES"
mkdir -p "$APPCAST_ARCHIVES"
cp "$ZIP_PATH" "$APPCAST_ARCHIVES/"
cp "$SCRIPT_DIR/appcast.xml" "$APPCAST_ARCHIVES/"

if [[ -z "$SPARKLE_DOWNLOAD_URL_PREFIX" ]]; then
    SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/Monkey0803/MenuTools/releases/download/v$VERSION/"
fi

"$GENERATE_APPCAST" \
    --ed-key-file "$SPARKLE_PRIVATE_ED_KEY_FILE" \
    --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX" \
    --link "https://github.com/Monkey0803/MenuTools/releases" \
    -o "$OUT_DIR/appcast.xml" \
    "$APPCAST_ARCHIVES"

echo "==> 发布资产已准备："
for asset in "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/appcast.xml"; do
    echo "    $asset"
    echo "      SHA-256: $(shasum -a 256 "$asset" | awk '{print $1}')"
done

cat <<EOF

==> 下一步（GitHub 开源分发）
    1. 提交并推送：git push origin <branch>
    2. 打 tag 并创建 Release：tag 使用 v$VERSION
    3. 上传资产：$(basename "$ZIP_PATH")、$(basename "$DMG_PATH")、appcast.xml
       （源码 zip/tar.gz 由 GitHub 按 tag 自动提供，无需上传）
    4. 把上面三个文件的 SHA-256 写进 Release 说明，便于用户校验
EOF
