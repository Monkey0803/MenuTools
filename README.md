# MenuTools

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
| ⬇️ 检查更新 | 应用内检查新版本，发现更新可直接跳转下载 |

### 个性化
- 8 款可切换的菜单栏图标（SF Symbols），即点即换
- 液态玻璃 UI：`GlassEffectContainer` + 彩色 tint 玻璃磁贴 + 玻璃形变过渡
- 动画：区块错峰入场、SF Symbol 弹跳/脉冲/替换、数字滚动过渡

## 📦 安装与构建

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
| 自动化 → 系统事件 | 外观/程序坞/菜单栏设置 | 深浅色、程序坞、菜单栏 |
| 蓝牙 | 读取 BLE 设备电量 | 蓝牙设备电量 |

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
| 检查更新 | 轻量 appcast JSON + 语义化版本比较 |

项目结构：

```
MenuTools/
├── Package.swift               # SPM 工程
├── build.sh                    # 一键打包脚本
├── appcast.json                # 更新源模板
├── Resources/                  # Info.plist / 图标
├── Scripts/                    # 图标生成与 API 验证脚本
└── Sources/MenuTools/
    ├── MenuToolsApp.swift      # 入口 + 菜单栏图标配置
    ├── MenuPanelView.swift     # 液态玻璃主面板
    └── Services/               # 各功能服务（单一职责）
```

## 🔄 发布更新

更新检查已对接 **GitHub Releases API**，发版流程：

1. 修改 `Resources/Info.plist` 中的 `CFBundleShortVersionString`，构建并打包 `MenuTools.app`（可压缩为 zip）
2. 在 GitHub 上发布 Release：tag 使用 `v1.1.0` 或 `1.1.0`，描述即更新说明，附件上传安装包（.zip / .dmg / .pkg）
3. 用户端自动生效：打开面板时静默自动检查（24 小时节流），或手动点击「检查更新」；发现新版本后底栏出现下载按钮，优先直链 Release 附件，无附件则跳转 Release 页面

也兼容简单 appcast JSON（`{"version","notes","url"}`，见 `appcast.json` 模板），便于私有部署。更新源可通过命令行覆盖（便于测试）：

```bash
defaults write com.qoder.menutools updateFeedURL "https://your-server/appcast.json"
defaults delete com.qoder.menutools updateFeedURL   # 恢复默认 GitHub 源
```

## ⚠️ 已知限制

- 夜览与经典蓝牙耳机电量依赖系统私有 API，系统大版本升级后可能失效（代码已做能力检查，失效时静默降级不会崩溃；`Scripts/` 内有验证脚本可快速回归）
- 不上报电量的蓝牙设备（部分白牌耳机）无法显示电量
- AirPods 充电盒电量仅在开盖/刚连接时由系统上报

## 📄 License

[MIT](LICENSE)
