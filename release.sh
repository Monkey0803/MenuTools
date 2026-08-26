#!/bin/zsh
# MenuTools 正式发布预检、打包和 notarization。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

APP_NAME="MenuTools"
OUT_DIR="$SCRIPT_DIR/dist"
INFO_PLIST="$SCRIPT_DIR/Resources/Info.plist"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_PRIVATE_ED_KEY_FILE="${SPARKLE_PRIVATE_ED_KEY_FILE:-}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "错误：正式发布必须设置 CODESIGN_IDENTITY（Developer ID Application）。" >&2
    exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "错误：正式发布必须设置 NOTARY_PROFILE（notarytool Keychain profile）。" >&2
    exit 1
fi

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "错误：正式发布必须设置 SPARKLE_PUBLIC_ED_KEY（Sparkle Ed25519 公钥）。" >&2
    exit 1
fi

if [[ -z "$SPARKLE_PRIVATE_ED_KEY_FILE" || ! -f "$SPARKLE_PRIVATE_ED_KEY_FILE" ]]; then
    echo "错误：正式发布必须设置 SPARKLE_PRIVATE_ED_KEY_FILE（Sparkle Ed25519 私钥文件）。" >&2
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
    echo "错误：正式发布要求工作区干净，请先提交或处理以下变更：" >&2
    git status --short >&2
    exit 1
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
    echo "错误：未找到签名证书 '$SIGN_IDENTITY'。" >&2
    exit 1
fi

echo "==> 运行测试"
swift test

echo "==> 使用 Developer ID 构建并签名"
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    CODESIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh release

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
ZIP_PATH="$OUT_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$OUT_DIR/$APP_NAME-$VERSION.dmg"

echo "==> 验证签名"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> 生成 ZIP 和 DMG"
rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"

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

echo "==> 生成 Sparkle appcast"
SPARKLE_BIN_DIR="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "错误：未找到 Sparkle generate_appcast：$GENERATE_APPCAST" >&2
    exit 1
fi

APPCAST_ARCHIVES="$OUT_DIR/sparkle-archives-$VERSION"
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

echo "    Sparkle appcast: $OUT_DIR/appcast.xml"

echo "==> 发布资产已准备："
echo "    $ZIP_PATH"
echo "    $DMG_PATH"
