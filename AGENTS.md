# AGENTS.md

This file provides guidance to Qoder (qoder.com) when working with code in this repository.

## 项目概述

MenuTools 是常驻 macOS 菜单栏的系统工具集（SPM 可执行工程，无 Xcode 工程文件），要求 **macOS 26+ / Swift 6**（依赖原生 Liquid Glass API）。UI 文案与代码注释使用中文。

## 常用命令

```bash
./build.sh                  # 一键：swift build -c release + 组装 .app + ad-hoc 签名 → dist/MenuTools.app
swift build -c release      # 仅编译（Swift 6 严格并发检查在此暴露错误）

# 修改代码后的标准重启验证流程：
pkill -f MenuTools.app/Contents/MacOS/MenuTools; ./build.sh && open dist/MenuTools.app

# 重新生成 App 图标（渐变+玻璃高光+SF Symbol 程序化绘制）：
swift Scripts/make_icon.swift /tmp/icon/AppIcon.iconset && iconutil -c icns /tmp/icon/AppIcon.iconset -o Resources/AppIcon.icns
```

- 无单元测试 target。`Scripts/test_*.swift` 是**私有 API / 系统能力的独立验证脚本**，用 `swift Scripts/test_xxx.swift` 直接运行；系统大版本升级或相关功能失效时先跑对应脚本回归。
- 沙箱环境中 `swift build` 可能因 xcrun 缓存写入被拒（`/var/folders` permission denied），需在沙箱外执行。
- 发版：改 `Resources/Info.plist` 的 `CFBundleShortVersionString` → 打包 → GitHub 发 Release（tag `v1.x.x`，附件 .zip/.dmg/.pkg），客户端更新检查自动生效。

## 架构

### 入口与 UI（Sources/MenuTools/）
- `MenuToolsApp.swift`：`MenuBarExtra`（`.window` 风格）+ `Settings` 场景；`LSUIElement=true` 无 Dock 图标。`SettingsKey` 常量与 `MenuBarIcon` 枚举也在此。
- `MenuPanelView.swift`：唯一主面板（宽 320）。布局顺序：header → 终端/外观双磁贴 → 六钮玻璃开关带 → 蓝牙电量卡 → DerivedData/剪贴板双磁贴 → 状态条 → 底栏。
- `SettingsView.swift`：独立设置窗口（grouped Form），面板齿轮通过 `openSettings` 打开（需先 `NSApp.activate`）。

### UI 约定（改动面板时必须遵守）
- 所有玻璃元素置于同一 `GlassEffectContainer` 内，用 `.glassEffect()` + `glassEffectID(_:in:)` 实现形变过渡；选中态用 `.tint(color.opacity(~0.3))`。
- 动画体系：区块用 `Entrance` modifier 错峰入场（0.06s 间隔）；图标状态切换用 `.contentTransition(.symbolEffect(.replace))` + `.symbolEffect(.bounce, value:)`；数值用 `.contentTransition(.numericText())`。
- 只用语义化颜色/材质保证深浅色自适应；SF Symbol 名称以字符串存 `@AppStorage`。

### 服务层（Sources/MenuTools/Services/，一文件一职责）
多数是 `@MainActor enum` + 静态方法；需要跨面板生命周期保活的状态用 ObservableObject 单例（`CaffeinateService.shared`、`BLEBatteryMonitor.shared`——面板每次打开都会重建视图，`@State` 会丢失）。

按实现通道分类：
- **AppleScript**（NSAppleScript，需"自动化"授权，Info.plist 已配 usage string）：`FinderService`（Finder 前窗路径）、`AppearanceService`（深浅色）、`SystemToggleService` 的程序坞/菜单栏（System Events dock preferences）。
- **Process 调 defaults/killall**：`SystemToggleService` 的隐藏文件读写（写完 killall Finder）与各开关状态读取。
- **IOKit**：`CaffeinateService`（电源断言防锁屏）、`XcodeCleanerService`（DerivedData 容量统计放 `Task.detached` 后台）。
- **私有 API（重点，见下）**：`NightShiftService`、`BluetoothBatteryService` 通道 2。

### 蓝牙电量三通道合并（本项目最复杂的部分）
macOS 26 移除了传统电量数据源（IORegistry 电量键全空、IOPowerSources 为空），现行方案：
1. `BluetoothBatteryService.fetchFromRegistry()`：IORegistry `AppleDeviceManagementHIDEventService`（AirPods 左/右/盒）。
2. `BluetoothBatteryService.fetchFromIOBluetooth()`：IOBluetooth 私有 getter（`batteryPercentSingle` 等，经典蓝牙 HFP 耳机如索尼）。键名来自 SDK `.tbd` 符号表（`IOBluetoothDeviceExpansion` 分类）——**KVC 前必须 `responds(to:)` 检查**，错误键名直接抛 NSUnknownKeyException 崩溃；0 视为未上报。
3. `BLEBatteryMonitor`：CoreBluetooth 标准 GATT 电池服务 180F/2A19（罗技等 BLE 键鼠），需要 `NSBluetoothAlwaysUsageDescription`；**`CBPeripheral` 必须强引用**（`retained` 字典），否则连接被系统静默取消。

三源在 `MenuPanelView.allBtDevices` 按设备名去重合并，耳机排前。

### 私有 API 模式
`NightShiftService`：`dlopen` CoreBrightness → `NSClassFromString("CBBlueLightClient")` → `unsafeBitCast(method(for:))` 成 C 函数指针调用；结构体 `BlueLightStatus` 内存布局须与私有头一致。所有私有 API 都带能力检查、失效时静默降级；对应验证脚本在 `Scripts/`。

### 更新检查
`UpdateCheckerService`：默认 GitHub Releases API（仓库无 Release 返回 404 视为已最新），兼容 appcast JSON 回退；`defaults write com.qoder.menutools updateFeedURL <url>` 可覆盖更新源（本地 file:// 也支持，测试后记得 delete）。自动检查受设置开关 + 24h 节流控制。

### Swift 6 严格并发踩过的坑
- `@MainActor` 类型内的 `static let`（如 CBUUID）不能在 `nonisolated` delegate 回调中引用——放文件级 private 常量或就地构造。
- 非 Sendable 对象（CBPeripheral/CBCentralManager）不能带进 `MainActor.assumeIsolated` 闭包——先在外面提取 Sendable 值（UUID、String、Bool）再传入。

## Git

- 推送用邮箱必须是 `11564933+Monkey0803@users.noreply.github.com`（GitHub 邮箱隐私保护会拒绝暴露 `hu_1987@126.com` 的推送）；若仓库 `git config user.email` 未改，提交时用 `GIT_COMMITTER_EMAIL` 环境变量 + `--author` 覆盖。
- 用户的另一份本地克隆在 `~/Documents/GitHub/Me/MenuTools`，推送后通常需要在那边 `git pull --ff-only` 同步。
- `dist/`、`.build/` 已被 .gitignore 排除，不要提交构建产物。
