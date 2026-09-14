# MenuTools 1.1.1

> 本文件是 v1.1.1 GitHub Release 的正文来源（发布时整段复制，或 `gh release create --notes-file docs/release-notes-1.1.1.md`）。
> 如果重新打包（`./release.sh`），请同步更新文末的 SHA-256。

**系统要求**：macOS 26 或更高版本 · Apple 芯片（arm64）

## 安装

- `MenuTools-1.1.1.dmg`：打开后把 `MenuTools.app` 拖入「应用程序」
- `MenuTools-1.1.1.zip`：解压后把 `MenuTools.app` 拖入「应用程序」
- 源码：由 GitHub 按 tag 自动提供（Source code zip / tar.gz）

## 更新内容

### 修复

- **修复网络流量「连接明细」导致应用崩溃**：加载连接时同一进程会出现多行，构造身份索引触发运行时陷阱，应用直接退出——因此连接明细里一直看不到 IP
- 修复 Sparkle 关于本应用「后台更新缺少温和提醒」的告警

### 改进

- **后台更新改为温和提醒**：面板底栏与设置页显示「新版本可用」，点击后才弹出正式更新窗口；不再在后台静默下载安装
- **设置页显示发布日期与更新说明**：不用打开 GitHub 就能看到当前版本改了什么

## 验证

- Swift Testing：**582 项全部通过**
- 连接明细崩溃：新增用例覆盖「连接模式下同一 PID 多行」与「同一身份重复增量」；并用真实 `nettop` 连接模式读取验证（58 个进程行 / 47 个唯一 PID，即 11 个重复键）不再崩溃，端点解析为 `IP:端口`
- 温和提醒：以 1.0.4 版本构建实测，后台检查不再下载或安装，只记录提醒（`SULastCheckTime` 正常刷新）
- 网络流量采样：30 秒冒烟 15/15 次成功（平均 69ms，基线 72ms）；5 分钟持续下载期间 `curl` 被正确归属（1.39 GB）；历史库 25.2 MB（上限 64 MB）
- 安装包：ZIP 完整性、DMG 内容、App 签名校验通过；appcast 的 Ed25519 签名与 App 内嵌公钥一致，自动更新链路可用

## 下载校验

| 文件 | SHA-256 |
|---|---|
| `MenuTools-1.1.1.zip` | `67103f8b6c4809ce4b402589eeda90a198712630fbc1f5d87d61212a7996a368` |
| `MenuTools-1.1.1.dmg` | `b877e85d0940514e4a37b5c886328b46a9dbda81f5d874302173b1b16f116b88` |
| `appcast.xml` | `18da786508cb11dd03dd4b1c0608e1c06a6060b4776e32e4ce9084fd633bf077` |

## 签名说明

本版本使用项目自签名证书 `MenuTools Self-Signed`，**未使用 Apple Developer ID，未经过 notarization**。首次打开如被 macOS 阻止，请按 README 的「首次打开」说明操作（系统设置 → 隐私与安全性 → 仍要打开）。

已安装 1.0.x / 1.1.0 的用户可以直接通过应用内更新升级到 1.1.1。
