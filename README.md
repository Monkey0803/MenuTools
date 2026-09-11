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

### 截图工具
| 功能 | 说明 |
|---|---|
| 🖼 全屏/窗口截图 | 支持全屏、当前前台窗口和自定义区域截图，可绑定独立全局快捷键 |
| 🧭 重复上次区域 | 保存最近一次自定义选区，后续一键重复截取 |
| 📜 长截图 | 手动滚动并实时采集稳定画面，按快捷键结束后自动拼接 |
| ✏️ 截图标注 | 支持画笔、箭头、形状、高亮、马赛克和文字标注 |

### App 音量管理
| 功能 | 说明 |
|---|---|
| 🔊 系统主音量 | 调节当前默认输出设备音量，并与系统静音状态同步 |
| 🎚 单 App 音量 | 对正在发声的 App 独立进行 0–100% 无极调节，互不影响 |
| 💾 音量记忆 | 按主 App Bundle ID 保存音量，Helper 进程自动合并到主 App |

### 效率工具
| 功能 | 说明 |
|---|---|
| 🚀 App 快速启动器 | 搜索并启动已安装 App，支持收藏和最近使用排序 |
| 🧩 配置场景 | 工作、演示、夜间三种预设，可手动一键应用 |
| 🪟 窗口管理 | 58 种布局、边缘吸附、布局预设、应用规则、多窗口排列、跨显示器移动和尺寸记忆 |
| 🌙 专注模式 | 快速切换系统 Focus 状态，并可打开系统专注模式设置 |
| ⌨️ 场景快捷键 | 为工作、演示、夜间场景录制全局快捷键并触发场景 |

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
| 📋 清理剪贴板 | 显示当前剪贴板项数，一键清空，并区分「已清空」和「本来就是空的」 |
| 🕘 剪贴板历史 | 保存文本、富文本、图片、链接和文件（含 PDF），支持搜索、分类/来源/时间筛选、固定、批量置顶与敏感标记、纯文本粘贴与直接粘贴 |
| 🗂 剪贴板整理 | 顺序粘贴队列、文本转换（大小写、合并行、URL 编解码、JSON 格式化）、常用片段模板（`{{date}}`、`{{clipboard}}` 等）和图片 OCR/二维码识别 |
| 🔐 剪贴板隐私 | 暂停记录、按 App 排除、按 Bundle ID 覆盖记录与保留策略；自动拦截密码、验证码、银行卡和自定义关键词并限时过期 |
| 🗄 剪贴板管理 | 按数量、保留天数和占用空间自动清理，支持口令加密归档导入导出（`.mtclip`）和共享文件夹同步置顶内容与常用片段 |
| ⌨️ 剪贴板快捷键 | 全局快捷键呼出剪贴板面板，注册冲突时自动降级为备用监听 |
| 📊 系统资源 | 显示 CPU、内存压力、磁盘可用空间和网络速率 |
| 📶 网络流量 | 按 App 显示实时上下行、连接明细和 30 天历史；支持网卡/协议筛选、额度提醒、脱敏导出与数据清除 |
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

当前目标版本：[MenuTools v1.0.4](https://github.com/Monkey0803/MenuTools/releases/tag/v1.0.4)

下载 `MenuTools-1.0.4.zip`，解压后将 `MenuTools.app` 拖入「应用程序」文件夹。

> GitHub Release 的实际签名类型以对应版本说明为准。没有 Developer ID 与 notarization 凭据时，发布包使用项目自签名证书或 ad-hoc 签名，不会宣称已经 notarize。

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
| 屏幕录制 | 允许截取当前窗口、自定义区域和长截图 | 截图工具 |
| 系统音频录制 | 捕获正在发声 App 的音频并以独立增益重放 | 单 App 音量管理 |
| 辅助功能 | 读取和设置前台窗口位置、尺寸 | 窗口管理 |
| 辅助功能 | 接收全局键盘事件并触发场景 | 场景快捷键、专注模式 |
| 辅助功能 | 合成 ⌘V 把内容贴回上一个 App | 剪贴板自动粘贴 |

若误点拒绝，可在 **系统设置 → 隐私与安全性** 中重新开启。静音、防止锁屏、夜览、剪贴板历史记录和清理类功能无需任何权限（剪贴板自动粘贴除外）。

## 🛠 技术实现

| 模块 | 方案 |
|---|---|
| 菜单栏常驻 | SwiftUI `MenuBarExtra`（window 风格）+ `LSUIElement` |
| 液态玻璃 | macOS 26 原生 `glassEffect` / `GlassEffectContainer` / `glassEffectID` |
| Finder 路径 | AppleScript（NSAppleScript） |
| 深浅色 / 程序坞 / 菜单栏 | 系统事件 AppleScript |
| 防止锁屏 | IOKit `IOPMAssertionCreateWithName` |
| 夜览 | CoreBrightness 私有框架 `CBBlueLightClient`（运行时动态调用，带能力检查） |
| 蓝牙电量 | 四通道合并：IORegistry + IOBluetooth 私有 getter + system_profiler（补齐 AirPods 分量）+ CoreBluetooth GATT 180F/2A19（BLE 键鼠） |
| DerivedData | FileManager 递归容量统计（后台线程）+ 清理 |
| 快捷操作中心 | Process、Finder AppleScript、系统设置 URL 和 `screencapture` |
| 截图工具 | ScreenCaptureKit 原生像素采集、冻结选区、窗口捕获、跨显示器合成、Vision 位移估计、PNG 拼接和 OCR/二维码识别；截图可复制到剪贴板或进入内置标注器 |
| 剪贴板历史 | 1 秒轮询 `NSPasteboard`、SQLite/WAL 元数据与二进制分离存储、口令加密归档、共享文件夹同步、Vision OCR/二维码识别（进程级串行闸门 + 失败重试）和 CGEvent 合成粘贴 |
| App 音量管理 | 公开 Core Audio Process Tap、私有 Aggregate Device 和 IOProc；只为低于 100% 的 App 建立路由，退出或失败时销毁 Tap 并恢复原音 |
| 网络状态 | CoreWLAN、网络接口地址、VPN 状态和按需 URLSession 探针 |
| 网络流量 | `/usr/bin/nettop` 进程采样、SQLite/WAL 历史、诊断、额度提醒和可选脱敏导出 |
| 电池健康 | `system_profiler SPPowerDataType -json`，无内置电池时静默降级 |
| 显示器工具 | `NSScreen` + CoreGraphics 显示模式枚举和切换 |
| 存储分析 | 后台递归统计指定目录，清理时保留目录本身且不操作 Downloads |
| App 启动器 | NSWorkspace 应用发现、搜索、收藏和启动 | App 快速启动器 |
| 配置场景 | 组合应用启动、外观、专注、音频、桌面图标和防止锁屏动作 | 配置场景 |
| 窗口管理 | Accessibility API 调整窗口位置、尺寸和显示器；NSEvent 边缘吸附；布局预设和应用规则持久化 | 窗口管理 |
| 专注模式 | Control Center 辅助功能脚本，失败时回退到系统设置 | 专注模式 |
| 全局快捷键 | NSEvent 全局/本地键盘监听、快捷键持久化和冲突检测 | 场景快捷键 |
| 检查更新 | Sparkle 标准更新器 + Ed25519 签名 appcast |

项目结构：

```
MenuTools/
├── Package.swift               # SPM 工程
├── build.sh                    # 一键打包脚本
├── release.sh                  # 正式发布预检、notarization 和安装包生成
├── appcast.xml                 # Sparkle 更新源模板
├── Resources/                  # Info.plist / 图标
├── Scripts/                    # 图标生成与 API 验证脚本
└── Sources/MenuTools/
    ├── MenuToolsApp.swift      # 入口 + 菜单栏图标配置
    ├── MenuPanelView.swift     # 液态玻璃主面板
    └── Services/               # 各功能服务（单一职责）
```

### 网络流量验证

网络流量依赖系统 `nettop` 的实际输出；提交或系统大版本升级后，可先跑短时 smoke test：

```bash
swift Scripts/test_network_traffic.swift --duration 30 --connections --strict
```

长时间稳定性回归可持续 8 小时采样（不主动产生下载流量）：

```bash
swift Scripts/test_network_traffic.swift --duration 28800 --interval 10 --no-download --strict
```

脚本会输出每次采样耗时、进程行数、非零流量行和汇总结果；之后在 MenuTools 设置页核对 App、速率和连接明细。

## 🔄 发布更新

更新功能使用 **[Sparkle](https://github.com/sparkle-project/Sparkle)**，由 Sparkle 负责 appcast 检查、下载、Ed25519 签名校验、安装和重启：

1. 修改 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
2. 配置 Developer ID 证书和 notarization profile：
   ```bash
   export CODESIGN_IDENTITY="Developer ID Application: ..."
   export NOTARY_PROFILE="menutools-notary"
   ```
3. 生成 Sparkle Ed25519 密钥，并将公钥写入环境变量；私钥只保存在本机或 CI 密钥存储中：
   ```bash
   export SPARKLE_PUBLIC_ED_KEY="..."
   export SPARKLE_PRIVATE_ED_KEY_FILE="/secure/path/sparkle_ed25519_private_key"
   ```
4. 运行 `./release.sh`，脚本会执行测试、Release 构建、Sparkle Framework 嵌入与签名、ZIP/DMG 打包、notarization、stapling 和 `generate_appcast`。
5. 在 GitHub 上发布 Release：tag 使用 `v1.0.4` 或 `1.0.4`，附件上传脚本生成的 `.zip` 和 `.dmg`。
6. 将 `dist/appcast.xml` 以 `appcast.xml` 文件名上传到 GitHub Release（当前 `SUFeedURL` 指向 `releases/latest/download/appcast.xml`）。

Sparkle 更新默认使用 `Resources/Info.plist` 中的 `SUFeedURL`。如果更新源不在 GitHub，可在发布时覆盖下载地址前缀：

```bash
export SPARKLE_DOWNLOAD_URL_PREFIX="https://your-server/releases/"
```

## ⚠️ 已知限制

- 夜览与经典蓝牙耳机电量依赖系统私有 API，系统大版本升级后可能失效（代码已做能力检查，失效时静默降级不会崩溃；`Scripts/` 内有验证脚本可快速回归）
- 不上报电量的蓝牙设备（部分白牌耳机）无法显示电量
- AirPods 充电盒电量仅在开盖/刚连接时由系统上报
- 单 App 音量需要系统音频录制权限；DRM 或无法被公开 Process Tap 捕获的音源会保持系统原始音量
- 清空废纸篓和截屏功能受 macOS 的自动化、屏幕录制权限控制；拒绝权限时会在面板显示失败原因
- 快捷键冲突检测可识别系统快捷键和其他应用通过 Carbon 注册的独占热键；使用私有事件监听器的应用无法通过公开 API 完整枚举
- 剪贴板历史依靠轮询系统剪贴板工作，只保存复制后的内容；macOS 不提供复制来源，因此「排除 App」按复制时的前台 App 判断
- 图片文字识别依赖本地 Vision，系统负载很高时可能短暂返回空结果；失败会自动重试，并在下次打开剪贴板面板时补试

## 🙏 鸣谢

- 平滑滚动功能的技术思路参考了 [Mos](https://github.com/Caldis/Mos)（复制事件模板改写 pointDelta 直投目标进程、CVDisplayLink 逐帧插值、峰值滤波去起始抖动、buffer/current 缓动模型、加速/转换/禁用修饰键等）。本项目为**独立实现**、未直接复制其源码；Mos 采用 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) 许可，与本项目 MIT 许可不兼容，故仅作思路参考并在此署名致谢。

## 📄 License

[MIT](LICENSE)
