---
name: menutools-release
description: MenuTools 项目级发版流程：核对版本与工作区，运行 Swift Testing，构建并签名 macOS App，按既有版本生成 ZIP，推送版本分支和标签，并创建、核验 GitHub Release。用户要求发布、发版、打包、创建 GitHub Release 或生成版本安装包时使用；只在当前 MenuTools 仓库内使用。
---

# MenuTools 发布

## 目标

按本项目已经验证的发布方式完成版本发布。默认复用 `v1.0.2` 的模式：Release 构建、ad-hoc 签名、单个 ZIP 资产、GitHub Release。不要把本地构建产物提交到 Git。

## 发布前检查

在仓库根目录执行：

```bash
git status --short
git branch --show-current
git log -1 --oneline
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist
```

必须满足：

- 工作区干净；`dist/` 和 `.build/` 即使被忽略也不能作为版本源文件提交。
- `CFBundleShortVersionString` 和 `CFBundleVersion` 相同，并与用户要求的版本一致。
- 发布分支使用版本号命名，例如 `1.0.3`；发布前确认远端没有同名标签或同版本 Release。
- 不自动修改版本号、提交代码或覆盖用户未提交的修改。发现脏工作区时先停止并报告文件。

## 默认发布流程（复用 v1.0.2）

### 1. 验证测试

```bash
swift test
```

记录实际通过的测试数量，不要把编译成功描述成测试通过。

### 2. Release 构建和签名

```bash
./build.sh release
```

该项目的普通发布构建会优先使用 `MenuTools Self-Signed`，不存在时回退 ad-hoc。检查签名：

```bash
codesign -dv --verbose=2 dist/MenuTools.app 2>&1 | rg 'Identifier|TeamIdentifier|Signature|Authority'
```

如果输出是 `MenuTools Self-Signed` 或没有 TeamIdentifier，Release 说明必须明确写明使用 ad-hoc/自签名；不要宣称已 notarize。

### 3. 生成与验证 ZIP

只生成与 v1.0.2 相同的 ZIP，除非用户明确要求 DMG 或 PKG：

```bash
rm -f "dist/MenuTools-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent \
  dist/MenuTools.app "dist/MenuTools-${VERSION}.zip"
unzip -tq "dist/MenuTools-${VERSION}.zip"
shasum -a 256 "dist/MenuTools-${VERSION}.zip"
```

`VERSION` 必须是已经核对过的版本变量，例如 `1.0.3`。删除操作只能针对 `dist/MenuTools-${VERSION}.zip` 这一明确资产。

### 4. 推送版本分支

确认 `git status --short` 仍为空后：

```bash
git push -u origin "${VERSION}"
```

如果本地分支名称不是版本号，先报告并确认，不要把当前分支强行重命名或推送到 `main`。

### 5. 创建 GitHub Release

使用已登录的 `gh`，将标签指向版本分支：

```bash
gh release create "v${VERSION}" "dist/MenuTools-${VERSION}.zip" \
  --repo Monkey0803/MenuTools \
  --target "${VERSION}" \
  --title "MenuTools ${VERSION}" \
  --notes '<版本更新说明和验证结果>'
```

Release 说明至少包含：窗口/系统功能变化、兼容或稳定性修复、测试数量、Release 构建和 ZIP 完整性验证结果，以及 ad-hoc 签名说明。

## 正式签名发布

只有用户明确要求 notarized/正式签名发布，且环境具备凭据时才执行：

```bash
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="..." \
./release.sh
```

`release.sh` 要求 Developer ID Application 证书和 `NOTARY_PROFILE`，会生成 ZIP/DMG 并执行 notarization/stapling。缺少任一项时不要伪造正式发布结果；可以报告阻塞，或在用户明确允许后改走默认 ad-hoc 流程。

## 发布后核验

```bash
gh release view "v${VERSION}" --repo Monkey0803/MenuTools \
  --json tagName,name,isDraft,isPrerelease,targetCommitish,publishedAt,assets,url
git ls-remote --heads origin "${VERSION}"
git ls-remote --tags origin "v${VERSION}"
git status --short
```

确认：Release 非 draft、非 prerelease，标签和版本分支指向预期提交，资产名称正确且上传完成，工作区干净。最终报告 Release URL、资产、签名类型、测试结果和任何未执行的 notarization。

## 失败处理

- 测试、构建、签名、压缩校验、推送或 Release 创建失败时停止后续步骤，保留错误输出并报告。
- 不删除已有远端标签或 Release，不使用 `git reset --hard`、`git checkout --` 或其他破坏性回滚。
- Release 已创建但资产上传失败时，先报告现有 Release URL 和失败资产，不重复创建同名 Release。
