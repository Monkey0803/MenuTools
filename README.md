# MenuTools

[English](README.en.md) | 简体中文

一个常驻 macOS 菜单栏的轻量系统工具集，采用 macOS 26 原生 **Liquid Glass（液态玻璃）** 设计，自动适配深色 / 浅色模式。

![platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)
![swift](https://img.shields.io/badge/Swift-6-orange)
![license](https://img.shields.io/badge/license-MIT-green)

## ✨ 功能

### 快捷操作
| 功能 | 说明 |
|---|---|
| 🖥 终端打开 Finder 路径 | 一键在终端中打开当前 Finder 最前窗口的目录，支持 Terminal / iTerm2 / Warp / Ghostty / kitty / Alacritty |
| 🌗 深浅色切换 | 一键切换系统外观，面板实时跟随系统主题 |

### 快捷操作中心
| 功能 | 说明 |
|---|---|
| 🔒 锁定屏幕 | 立即锁定当前用户会话 |
| 🗑 清空废纸篓 | 通过 Finder 清空废纸篓 |
| 🔄 重启 Finder | 重启 Finder 以恢复异常状态 |
| 🌐 刷新 DNS | 刷新本机 DNS 缓存并重启 mDNSResponder |
| ⚙️ 系统设置 | 打开 macOS 系统设置 |
| 📷 截屏到剪贴板 | 截取当前屏幕并直接复制到剪贴板 |

### 效率工具
| 功能 | 说明 |
|---|---|
| 🚀 App 快速启动器 | 搜索并启动已安装 App，支持收藏和最近使用排序 |
| 🧩 配置场景 | 工作、演示、夜间三种预设，可手动一键应用 |
| 🪟 窗口管理 | 左右分屏、四象限、居中、跨显示器移动，并支持尺寸记忆 |
| 🌙 专注模式 | 快速切换系统 Focus 状态，并可打开系统专注模式设置 |

### 系统开关（六钮玻璃开关带）
| 开关 | 说明 |
|---|---|
| 🔒 防止锁屏 | IOKit 电源断言阻止屏幕休眠，开启时图标持续脉冲提示 |
| 👁 显示隐藏文件 | 切换 Finder 隐藏文件可见性（自动重启 Finder） |
| 🔇 静音 | 系统输出静音开关 |
| 📥 隐藏程序坞 | 程序坞自动隐藏，即时生效 |
| 📤 隐藏菜单栏 | 菜单栏自动隐藏，即时生效 |
| 🌅 夜览 | Night Shift 开关，与控制中心完全同步 |

### 信息与清理
| 功能 | 说明 |
|---|---|
| 🎧 蓝牙设备电量 | AirPods（左耳/右耳/充电盒分量）、罗技等 BLE 键鼠、索尼等经典蓝牙耳机，多设备列表实时显示 |
| 🔨 清理 DerivedData | 显示 Xcode DerivedData 占用容量，一键清理并统计释放空间 |
| 📋 清理剪贴板 | 显示当前剪贴板项数，一键清空 |
| 🕘 剪贴板历史 | 保存最近文本和图片，支持搜索、固定、删除和一键复制 |
| 📊 系统资源 | 显示 CPU、内存压力、磁盘可用空间和网络速率 |
| ⬇️ 检查更新 | 应用内检查新版本，发现更新可直接跳转下载 |

### 系统信息
| 功能 | 说明 |
|---|---|
| 🌐 网络状态 | 显示 Wi-Fi、网络名称、本机 IP、VPN 状态；公网 IP 和延迟支持按需查询 |
| 🔋 电池健康 | 显示内置电池健康度、循环次数、当前电量和充电状态；无数据时静默降级 |
| 🖥 显示器工具 | 显示内置/外接显示器、分辨率和刷新率，可切换系统支持的显示模式 |
| 💾 存储分析 | 分析 DerivedData、缓存、日志和下载目录，并对安全目录提供确认后清理 |

### 个性化
- 8 款可切换的菜单栏图标（SF Symbols），即点即换
- 液态玻璃 UI：`GlassEffectContainer` + 彩色 tint 玻璃磁贴 + 玻璃形变过渡
- 动画：区块错峰入场、SF Symbol 弹跳/脉冲/替换、数字滚动过渡

## 📦 安装与构建

### 下载

当前目标版本：[MenuTools v1.0.3](https://github.com/Monkey0803/MenuTools/releases/tag/v1.0.3)

下载 `MenuTools-1.0.3.zip`，解压后将 `MenuTools.app` 拖入「应用程序」文件夹。

> 正式 Release 使用 Developer ID 签名并经过 notarization；本地直接运行 `./build.sh` 生成的包仍使用自签名或 ad-hoc 签名。

### 首次打开

如果 macOS 阻止打开 App：

1. 双击打开 App，等待 macOS 阻止。
2. 打开「系统设置 → 隐私与安全性」。
3. 找到底部的安全提示。
4. 点击「仍要打开 / Open Anyway」。
5. 在随后出现的确认窗口中再次点击「打开」。

也可以在 Finder 中右键点击 `MenuTools.app`，选择「打开」。

如果仍无法打开，并且你确认 App 来自本项目的 GitHub Release，可在包含 App 的目录中执行：

```bash
sudo xattr -dr com.apple.quarantine MenuTools.app
```

> `xattr` 会移除下载隔离标记，只应对可信且已校验来源的 App 使用。优先使用「仍要打开」，不要关闭系统 Gatekeeper。

### 环境要求
- macOS 26.0+（Liquid Glass API 要求）
- Xcode 26+ / Swift 6 工具链

### 构建
```bash
git clone https://github.com/Monkey0803/MenuTools.git
cd MenuTools
./build.sh          # 编译 + 打包 + ad-hoc 签名
open dist/MenuTools.app
```

产物位于 `dist/MenuTools.app`，可直接拖入「应用程序」文件夹。

> 当前使用 ad-hoc 签名，仅限本机运行；分发需替换为开发者证书。

## 🔐 权限说明

首次使用对应功能时系统会弹出授权请求：

| 权限 | 用途 | 触发功能 |
|---|---|---|
| 自动化 → Finder | 读取最前窗口路径 | 终端打开 |
| 自动化 → Finder | 清空废纸篓 | 快捷操作中心 |
| 自动化 → 系统事件 | 外观/程序坞/菜单栏设置 | 深浅色、程序坞、菜单栏 |
| 蓝牙 | 读取 BLE 设备电量 | 蓝牙设备电量 |
| 屏幕录制 | 允许截取屏幕内容 | 截屏到剪贴板 |
| 辅助功能 | 读取和设置前台窗口位置、尺寸 | 窗口管理 |

若误点拒绝，可在 **系统设置 → 隐私与安全性** 中重新开启。静音、防止锁屏、夜览、清理类功能无需任何权限。

## 🛠 技术实现

| 模块 | 方案 |
|---|---|
| 菜单栏常驻 | SwiftUI `MenuBarExtra`（window 风格）+ `LSUIElement` |
| 液态玻璃 | macOS 26 原生 `glassEffect` / `GlassEffectContainer` / `glassEffectID` |
| Finder 路径 | AppleScript（NSAppleScript） |
| 深浅色 / 程序坞 / 菜单栏 | 系统事件 AppleScript |
| 防止锁屏 | IOKit `IOPMAssertionCreateWithName` |
| 夜览 | CoreBrightness 私有框架 `CBBlueLightClient`（运行时动态调用，带能力检查） |
| 蓝牙电量 | 三通道合并：IORegistry（AirPods）+ IOBluetooth 私有 getter（经典蓝牙耳机）+ CoreBluetooth GATT 180F/2A19（BLE 键鼠） |
| DerivedData | FileManager 递归容量统计（后台线程）+ 清理 |
| 快捷操作中心 | Process、Finder AppleScript、系统设置 URL 和 `screencapture` |
| 网络状态 | CoreWLAN、网络接口地址、VPN 状态和按需 URLSession 探针 |
| 电池健康 | `system_profiler SPPowerDataType -json`，无内置电池时静默降级 |
| 显示器工具 | `NSScreen` + CoreGraphics 显示模式枚举和切换 |
| 存储分析 | 后台递归统计指定目录，清理时保留目录本身且不操作 Downloads |
| App 启动器 | NSWorkspace 应用发现、搜索、收藏和启动 | App 快速启动器 |
| 配置场景 | 组合应用启动、外观、专注、音频、桌面图标和防止锁屏动作 | 配置场景 |
| 窗口管理 | Accessibility API 调整窗口位置、尺寸和显示器 | 窗口管理 |
| 专注模式 | Control Center 辅助功能脚本，失败时回退到系统设置 | 专注模式 |
| 检查更新 | 轻量 appcast JSON + 语义化版本比较 |

项目结构：

```
MenuTools/
├── Package.swift               # SPM 工程
├── build.sh                    # 一键打包脚本
├── release.sh                  # 正式发布预检、notarization 和安装包生成
├── appcast.json                # 更新源模板
├── Resources/                  # Info.plist / 图标
├── Scripts/                    # 图标生成与 API 验证脚本
└── Sources/MenuTools/
    ├── MenuToolsApp.swift      # 入口 + 菜单栏图标配置
    ├── MenuPanelView.swift     # 液态玻璃主面板
    └── Services/               # 各功能服务（单一职责）
```

## 🔄 发布更新

更新检查已对接 **GitHub Releases API**，正式发版流程：

1. 修改 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
2. 配置 Developer ID 证书和 notarization profile：
   ```bash
   export CODESIGN_IDENTITY="Developer ID Application: ..."
   export NOTARY_PROFILE="menutools-notary"
   ```
3. 运行 `./release.sh`，脚本会执行测试、Release 构建、签名验证、ZIP/DMG 打包、notarization 和 stapling。
4. 在 GitHub 上发布 Release：tag 使用 `v1.0.3` 或 `1.0.3`，描述即更新说明，附件上传脚本生成的 `.zip` 和 `.dmg`。
5. 用户端自动生效：打开面板时静默自动检查（24 小时节流），或手动点击「检查更新」；发现新版本后底栏可直接下载 Release 附件。

也兼容简单 appcast JSON（`{"version","notes","url"}`，见 `appcast.json` 模板），便于私有部署。更新源可通过命令行覆盖（便于测试）：

```bash
defaults write com.qoder.menutools updateFeedURL "https://your-server/appcast.json"
defaults delete com.qoder.menutools updateFeedURL   # 恢复默认 GitHub 源
```

## ⚠️ 已知限制

- 夜览与经典蓝牙耳机电量依赖系统私有 API，系统大版本升级后可能失效（代码已做能力检查，失效时静默降级不会崩溃；`Scripts/` 内有验证脚本可快速回归）
- 不上报电量的蓝牙设备（部分白牌耳机）无法显示电量
- AirPods 充电盒电量仅在开盖/刚连接时由系统上报
- 清空废纸篓和截屏功能受 macOS 的自动化、屏幕录制权限控制；拒绝权限时会在面板显示失败原因

## 🙏 鸣谢

- 平滑滚动功能的技术思路参考了 [Mos](https://github.com/Caldis/Mos)（复制事件模板改写 pointDelta 直投目标进程、CVDisplayLink 逐帧插值、峰值滤波去起始抖动、buffer/current 缓动模型、加速/转换/禁用修饰键等）。本项目为**独立实现**、未直接复制其源码；Mos 采用 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) 许可，与本项目 MIT 许可不兼容，故仅作思路参考并在此署名致谢。

## 📄 License

[MIT](LICENSE)
