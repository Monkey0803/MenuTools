---
name: menutools-release
description: MenuTools 项目级发版流程：核对工作区与版本，定稿更新说明，运行 ./release.sh 完成测试、构建、自签名与 ZIP/DMG/appcast 打包，提交 Release 说明，推送版本分支并快进 main，创建并核验 GitHub Release。用户要求发布、发版、打包、创建 GitHub Release 或生成版本安装包时使用；只在当前 MenuTools 仓库内使用。
---

# MenuTools 发布

## 目标

用 `./release.sh`（默认 `RELEASE_MODE=github`）完成发布：自签名构建，产出 **ZIP + DMG + appcast.xml 三个资产**并创建 GitHub Release。

1.1.0 起一律这三个资产，**不要只发 ZIP**：

- 应用内更新依赖 `appcast.xml` 资产：`Resources/Info.plist` 的 `SUFeedURL` 指向 `releases/latest/download/appcast.xml`，缺了它已装旧版本的用户收不到更新。
- `release.sh` 会一并生成 `docs/release-notes-<版本>.md`（更新内容、测试数量、三个资产的 SHA-256、签名说明），直接用作 `--notes-file`，不要手写替换。

`v1.0.2` 时代「手工只打一个 ZIP」的流程已废弃，不要再照它执行。

## 发布前检查

```bash
git status --short
git branch --show-current
git log -1 --oneline
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist
git ls-remote --tags origin "v${VERSION}"
gh release list --repo Monkey0803/MenuTools --limit 5
```

必须满足：

- 工作区干净（`release.sh` 自己也会检查并拒绝脏工作区）。
- `CFBundleShortVersionString` 与 `CFBundleVersion` 相同，且等于要发布的版本；版本号在开版本分支时已由 `chore(version)` 提交设定，发版阶段不要再改。
- 当前分支名就是版本号（如 `1.1.4`）；远端没有同名 tag 或 Release。
- 不自动改版本号、不覆盖用户未提交的修改；工作区脏时停下并报告文件。

环境依赖（缺任一项 `release.sh` 会直接报错退出）：

- 代码签名证书 `MenuTools Self-Signed`：
  `security find-identity -p codesigning | grep -F "MenuTools Self-Signed"`
  （显示 `CSSMERR_TP_NOT_TRUSTED` 是自签名的正常状态，不影响发布。）
- Sparkle Ed25519 私钥 `.cert/sparkle_ed25519_private_key`。
- Sparkle 工具 `.build/artifacts/sparkle/Sparkle/bin/generate_appcast`。
- 已登录且具备 `repo` scope 的 `gh`。

## 1. 定稿更新说明（必做）

`release.sh` 从 `Resources/ReleaseNotes.md` 取 `## <版本>` 段落生成 Release 说明，并要求该段落存在。开发期段落形如 `## 1.1.4 — 开发中`，且末尾带一行占位：「开发中：本版本内容持续补充，发布前会据此生成 Release 说明」。发版前必须：

- 表头改成 `## <版本> — <YYYY-MM-DD>`。
- **删掉那行占位**——它在段落内部，不删会被当作一条更新内容带进 Release 说明。

改完先提交，再跑发布：

```bash
git add Resources/ReleaseNotes.md
git commit -m "docs(release): 定稿 <版本> 更新说明并移除开发中占位"
```

## 2. 打包

```bash
./release.sh
```

依次执行：`swift test`（**失败即中止，不会产出任何资产**）→ `build.sh release` 构建并签名 → `codesign --verify --deep --strict` → 生成 ZIP 与 DMG → `generate_appcast` 写出 `dist/appcast.xml` → 生成 `docs/release-notes-<版本>.md`。

注意事项：

- `build.sh release` 有副作用：会安装到 `/Applications/MenuTools.app`、重启 Finder 扩展与 Finder、并启动应用。这是预期行为，不是失败。
- 不要用管道掩盖退出码；若把输出重定向到日志，要确认日志里出现 `==> 发布资产已准备` 才算成功。
- `dist/` 已被忽略，不要提交；根 `appcast.xml` 只是空 feed 模板（`release.sh` 把它作为种子拷进归档目录），发布不需要改它。
- 只想按现有产物重算校验值并重生成说明：`RELEASE_NOTES_ONLY=1 ./release.sh`。
- 想补充验证条目，先写 `docs/release-verification-<版本>.md`，其内容会被并入 Release 说明的「验证」小节。

## 3. 提交 Release 说明

```bash
git add docs/release-notes-<版本>.md
git commit -m "docs(release): 生成 <版本> Release 说明"
```

## 4. 推送分支并快进 main

发布用 `--target main`，所以 **main 必须先包含本次发版提交**，否则 tag 会打到上一个版本上：

```bash
git push origin "${VERSION}"
git checkout main && git merge --ff-only "${VERSION}" && git push origin main
git checkout "${VERSION}"
```

## 5. 创建 GitHub Release

```bash
gh release create "v${VERSION}" \
  "dist/MenuTools-${VERSION}.zip" \
  "dist/MenuTools-${VERSION}.dmg" \
  dist/appcast.xml \
  --repo Monkey0803/MenuTools \
  --target main \
  --title "MenuTools ${VERSION}" \
  --notes-file "docs/release-notes-${VERSION}.md"
```

## 6. 发布后核验

```bash
gh release view "v${VERSION}" --repo Monkey0803/MenuTools \
  --json tagName,isDraft,isPrerelease,targetCommitish,assets,url
git ls-remote --heads origin "${VERSION}"
git ls-remote --tags origin "v${VERSION}"
git fetch origin --tags
git status --short

# 应用内更新实际拉取的地址：必须已提供新版本，且与本地产物逐字节一致
curl -sL "https://github.com/Monkey0803/MenuTools/releases/latest/download/appcast.xml" -o /tmp/live-appcast.xml
grep -oE "<sparkle:version>[^<]*" /tmp/live-appcast.xml | head -3
shasum -a 256 /tmp/live-appcast.xml dist/appcast.xml
```

确认：Release 非 draft、非 prerelease；`targetCommitish` 为 `main`；tag、版本分支与 `main` 指向同一个发版提交；三个资产都是 `uploaded`；线上 appcast 已是新版本且 SHA-256 与 `dist/appcast.xml` 相同；工作区干净。最终报告 Release URL、资产、签名类型、测试数量和未执行的 notarization。

`gh release create` 只在远端创建 tag，本地需 `git fetch origin --tags` 补回。

## 顺带同步另一份克隆

用户的另一份克隆在 `~/Documents/GitHub/Me/MenuTools`，推送后同步：

```bash
cd ~/Documents/GitHub/Me/MenuTools && git pull --ff-only && git fetch origin --tags
```

## 正式签名发布

只有用户明确要求 notarized/正式签名发布，且环境具备凭据时才执行：

```bash
RELEASE_MODE=developer-id \
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="..." \
./release.sh
```

该模式额外要求 `SPARKLE_PUBLIC_ED_KEY` 与 `SPARKLE_PRIVATE_ED_KEY_FILE`，会做 notarization/stapling，并用已 stapled 的 App 重新生成 ZIP。缺少任一项时不要伪造正式发布结果；可以报告阻塞，或在用户明确允许后改走默认 github 模式。

## 提交说明会被钩子校验

本机全局 `commit-msg` 钩子要求：

- 标题形如 `type(scope): 中文描述`，`type` 限 `feat` / `fix` / `refactor` / `chore` / `docs` / `test` / `perf` / `build` / `ci` / `revert`，`scope` 为小写字母数字与 `._-`。
- 标题后必须空一行。
- 正文至少 2 条，**每行都要以 `- ` 开头**（不能出现普通段落），且必须含中文。

不满足会直接拒绝提交，需要改写说明后重试。

## 失败处理

- 测试、构建、签名、压缩校验、推送或 Release 创建失败时停止后续步骤，保留错误输出并报告。
- `release.sh` 在测试步中止（`set -e` + pipefail）时，先修失败用例再重跑，不要绕过测试发版；本项目出现过「负载敏感的固定 sleep 时序假设」导致的偶发失败（单跑通过、整包并发跑失败）。
- 不删除已有远端标签或 Release，不使用 `git reset --hard`、`git checkout --` 或其他破坏性回滚。
- Release 已创建但资产上传失败时，先报告现有 Release URL 和失败资产，不重复创建同名 Release。
