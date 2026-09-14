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
RELEASE_NOTES_ONLY="${RELEASE_NOTES_ONLY:-0}"
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

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
ZIP_PATH="$OUT_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$OUT_DIR/$APP_NAME-$VERSION.dmg"

if ! grep -q "^## $VERSION" Resources/ReleaseNotes.md; then
    echo "错误：Resources/ReleaseNotes.md 缺少版本 $VERSION 的更新说明段落。" >&2
    echo "      应用内「更新说明」与 Release 说明都依赖它，请先补上（标题形如：## $VERSION — YYYY-MM-DD）。" >&2
    exit 1
fi

# 取出当前版本的条目（## $VERSION 到下一个 ## 之间）。
release_note_bullets() {
    awk -v version="$VERSION" '
        $0 ~ "^## " version "([[:space:]]|$)" { inside = 1; next }
        /^## / { inside = 0 }
        inside {
            if ($0 ~ /^[[:space:]]*$/ && !started) next
            started = 1
            lines[count++] = $0
        }
        END {
            while (count > 0 && lines[count - 1] ~ /^[[:space:]]*$/) count--
            for (i = 0; i < count; i++) print lines[i]
        }
    ' Resources/ReleaseNotes.md
}

# 从 Resources/ReleaseNotes.md 生成 GitHub Release 说明。
# $1 为测试数量（可空）；额外验证条目放在 docs/release-verification-<版本>.md。
write_release_notes() {
    local test_count="${1:-${RELEASE_TEST_COUNT:-}}"
    local notes_path="$SCRIPT_DIR/docs/release-notes-$VERSION.md"
    local verification_path="$SCRIPT_DIR/docs/release-verification-$VERSION.md"

    # 单独重生成时沿用上一次记录的数量，避免丢掉「测试全部通过」这一行。
    if [[ -z "$test_count" && -f "$notes_path" ]]; then
        test_count=$(sed -nE 's/^- Swift Testing：\*\*([0-9]+) 项全部通过\*\*/\1/p' "$notes_path" | head -1)
    fi

    {
        echo "# MenuTools $VERSION"
        echo ""
        echo "> 本文件由 \`./release.sh\` 从 \`Resources/ReleaseNotes.md\` 生成（更新内容以那里为准），请勿手改。"
        echo "> 单独重新生成：\`RELEASE_NOTES_ONLY=1 ./release.sh\`"
        echo ""
        echo "**系统要求**：macOS 26 或更高版本 · Apple 芯片（arm64）"
        echo ""
        echo "## 安装"
        echo ""
        echo "- \`$APP_NAME-$VERSION.dmg\`：打开后把 \`$APP_NAME.app\` 拖入「应用程序」"
        echo "- \`$APP_NAME-$VERSION.zip\`：解压后把 \`$APP_NAME.app\` 拖入「应用程序」"
        echo "- 源码：由 GitHub 按 tag 自动提供（Source code zip / tar.gz）"
        echo ""
        echo "## 更新内容"
        echo ""
        release_note_bullets
        echo ""
        echo "## 验证"
        echo ""
        if [[ -n "$test_count" ]]; then
            echo "- Swift Testing：**$test_count 项全部通过**"
        fi
        if [[ -f "$verification_path" ]]; then
            cat "$verification_path"
        elif [[ -z "$test_count" ]]; then
            echo "- 待补充：可写入 \`docs/release-verification-$VERSION.md\`"
        fi
        echo ""
        echo "## 下载校验"
        echo ""
        echo "| 文件 | SHA-256 |"
        echo "|---|---|"
        local asset
        for asset in "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/appcast.xml"; do
            echo "| \`$(basename "$asset")\` | \`$(shasum -a 256 "$asset" | awk '{print $1}')\` |"
        done
        echo ""
        echo "## 签名说明"
        echo ""
        echo "本版本使用项目自签名证书 \`$APP_NAME Self-Signed\`，**未使用 Apple Developer ID，未经过 notarization**。首次打开如被 macOS 阻止，请按 README 的「首次打开」说明操作（系统设置 → 隐私与安全性 → 仍要打开）。"
        echo ""
        echo "已安装旧版本的用户可以直接通过应用内更新升级到 $VERSION。"
    } > "$notes_path"
    echo "    Release 说明：$notes_path"
}

# 只重新生成 Release 说明：不跑测试、不重新打包，用现有产物算校验值。
if [[ "$RELEASE_NOTES_ONLY" == "1" ]]; then
    for asset in "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/appcast.xml"; do
        if [[ ! -f "$asset" ]]; then
            echo "错误：缺少打包产物 $asset，请先跑一次完整发布。" >&2
            exit 1
        fi
    done
    echo "==> 仅重新生成 Release 说明（版本 $VERSION）"
    write_release_notes
    exit 0
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
TEST_OUTPUT=$(swift test 2>&1 | tee /dev/stderr)
TEST_COUNT=$(printf '%s\n' "$TEST_OUTPUT" | sed -nE 's/.*Test run with ([0-9]+) tests.*/\1/p' | tail -1)

echo "==> 构建并签名"
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
        CODESIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh release
else
    CODESIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh release
fi

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

echo "==> 生成 Release 说明"
write_release_notes "$TEST_COUNT"

echo "==> 发布资产已准备："
for asset in "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/appcast.xml"; do
    echo "    $asset"
    echo "      SHA-256: $(shasum -a 256 "$asset" | awk '{print $1}')"
done

cat <<EOF

==> 下一步（GitHub 开源分发）
    1. 提交并推送：git push origin <branch>
    2. 打 tag 并创建 Release：tag 使用 v$VERSION，说明用 docs/release-notes-$VERSION.md
       gh release create v$VERSION \
         dist/$(basename "$ZIP_PATH") dist/$(basename "$DMG_PATH") dist/appcast.xml \
         --title "MenuTools $VERSION" --notes-file docs/release-notes-$VERSION.md --target main
       （源码 zip/tar.gz 由 GitHub 按 tag 自动提供，无需上传）
EOF
