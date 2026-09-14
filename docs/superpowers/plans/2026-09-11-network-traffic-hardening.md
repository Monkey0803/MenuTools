# 网络流量模块加固计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 收尾网络流量模块的交互遗留问题，补齐通知权限出口、插件生命周期归属与文档/回归，让模块达到可发版状态。

**Architecture:** 交互修复把可测几何下沉到 `NetworkTrafficHistoryChartLayout`；权限通过 `NetworkTrafficAlerting.currentPermission()` 暴露系统授权状态；生命周期把 `NetworkStatusService` 的采样改为观察者计数，使监控归属跟随卡片所属插件。全部改动保持既有协议边界，便于 Swift Testing 覆盖。

**Tech Stack:** Swift 6、SwiftUI、AppKit、UserNotifications、SQLite/WAL、Swift Testing、macOS 26。

## Global Constraints

- UI 文案一律走 `L()`，五种内置语言（en、ja、ko、zh-Hans、zh-Hant）必须齐全。
- 新增枚举 case 时同步更新 `Tests/MenuToolsTests/L10nTests.swift` 的 `dynamicKeys`，否则文案缺失不会被发现。
- 遵循 TDD：先写能证明需求的失败测试，确认 RED 后写最小实现，再确认 GREEN。
- 不修改 `Sources/MenuTools/Services/WindowManagementService.swift` 等与本模块无关的并行改动。
- 不新增后台常驻进程；不引入抓包或内容审计能力。

---

### Task 1: 悬停交互收尾

**Files:**
- Modify: `Sources/MenuTools/NetworkTrafficSettingsView.swift`
- Test: `Tests/MenuToolsTests/NetworkTrafficServiceTests.swift`

**Interfaces:**
- `NetworkTrafficHistoryChartLayout.barHeight` / `detailRowHeight` / `detailRowSpacing`
- `NetworkTrafficHistoryChartLayout.blockHeight(hasHoverDetail:)`
- `NetworkTrafficHistoryChartLayout.hoveredIndex(x:totalWidth:sampleCount:spacing:)`

- [x] **Step 1: 写失败测试**

覆盖两点：详情行高度与是否悬停无关（几何不变），以及悬停命中由统一 helper 驱动、不再逐柱监听。

- [x] **Step 2: 确认 RED**

`swift test --filter NetworkTraffic`，预期因 `blockHeight` 不存在而失败。

- [x] **Step 3: 详情行改为固定预留行**

未悬停时渲染占位视图，图表高度固定为 `blockHeight(hasHoverDetail:)`，悬停不再位移也不再覆盖柱子。

- [x] **Step 4: 悬停改由整块画布统一命中**

用 `onContinuousHover` + `hoveredIndex` 替代逐柱 `onHover`，柱间空隙不命中；补 `.animation` 让详情淡入生效。

- [x] **Step 5: 确认 GREEN 并提交**

`swift test` 全量通过、`swift build -c release` 通过，提交 `fix(network): 悬停详情改用图表上方固定预留行`。

### Task 2: 通知权限出口

**Files:**
- Modify: `Sources/MenuTools/Services/NetworkTrafficService.swift`
- Modify: `Sources/MenuTools/NetworkTrafficSettingsView.swift`
- Modify: `Sources/MenuTools/Plugins/BuiltInPluginManager.swift`
- Modify: `Sources/MenuTools/Plugins/BuiltInPluginCatalog.swift`
- Modify: `Resources/*.lproj/Localizable.strings`
- Test: `Tests/MenuToolsTests/NetworkTrafficServiceTests.swift`、`Tests/MenuToolsTests/L10nTests.swift`

**Interfaces:**
- `enum NetworkTrafficNotificationPermission: String, CaseIterable, Equatable, Sendable`
- `enum NetworkTrafficNotificationAuthorization.permission(for:) -> NetworkTrafficNotificationPermission`
- `NetworkTrafficAlerting.currentPermission() async -> NetworkTrafficNotificationPermission`
- `NetworkTrafficService.notificationPermission` / `refreshNotificationPermission()`
- `BuiltInPluginPermission.notifications`

- [x] **Step 1: 写失败测试**

覆盖系统授权状态到界面状态的映射、服务把授权状态暴露给设置页、开启提醒会请求授权。

- [x] **Step 2: 确认 RED**

`swift test --filter NetworkTraffic`，预期因类型与成员缺失而失败。

- [x] **Step 3: 实现权限状态与协议扩展**

`UNAuthorizationStatus` → 界面状态用纯函数映射；读状态走回调版 API，只在回调内取 Sendable 的 `authorizationStatus`，避免跨 actor 传递 `UNNotificationSettings`。

- [x] **Step 4: 设置页显示状态并给出恢复入口**

被拒时显示橙色说明 + 「打开系统设置」（`x-apple.systempreferences:com.apple.Notifications-Settings.extension`）；页面可见期间每 30 秒回读一次，用户作答后无需重开页面。

- [x] **Step 5: 注册权限枚举并补五种语言文案**

`network-traffic` 插件声明 `.notifications`；补 `plugin.permission.notifications` 与 4 条 `traffic.notification.*` 文案；`L10nTests.dynamicKeys` 同步加入新枚举。

- [x] **Step 6: 确认 GREEN**

`swift test` 全量通过，本地化审计覆盖新键。

### Task 3: 插件生命周期归属

**Files:**
- Modify: `Sources/MenuTools/Services/NetworkStatusService.swift`
- Modify: `Sources/MenuTools/Plugins/BuiltInPluginCatalog.swift`
- Test: `Tests/MenuToolsTests/NetworkStatusServiceTests.swift`

**Interfaces:**
- `NetworkStatusService.beginMonitoring()` / `endMonitoring()` / `isMonitoring`
- 插件 `system-insights` 启停 `NetworkStatusService` 监控，`network-traffic` 只启停 `NetworkTrafficService`

- [x] **Step 1: 写失败测试**

覆盖观察者计数：两次持有 + 一次释放仍在监控，归零后停止；多余释放不会把计数降到负数。

- [x] **Step 2: 确认 RED**

`swift test --filter NetworkStatus`，预期因成员缺失而失败。

- [x] **Step 3: 改为观察者计数**

`beginMonitoring` 递增并保证计时器唯一，`endMonitoring` 归零才停止。

- [x] **Step 4: 重新归属插件启停**

网络状态卡片的监控随 `system-insights` 启停；`network-traffic` 不再越权停掉别人的监控。

- [x] **Step 5: 确认 GREEN**

`swift test` 全量通过、release 构建通过。

### Task 4: 文档与发布回归

**Files:**
- Modify: `README.md`、`README.en.md`
- Create: `docs/superpowers/specs/2026-09-11-network-traffic-design.md`
- Create: `docs/superpowers/plans/2026-09-11-network-traffic-hardening.md`

- [x] **Step 1: 权限表补通知一行**

中英文 README 的权限说明都加入「通知 / 网络流量」，并说明被拒后的恢复路径。

- [x] **Step 2: 已知限制补网络流量条目**

补 nettop 进程级聚合与接口类别筛选的限制、首次开启无历史、nettop 字段随系统升级变化、通知被拒时提醒静默失效。

- [x] **Step 3: 补设计文档与计划文档**

设计文档沉淀采样策略、存储策略、提醒与额度规则、权限、导出与生命周期归属。

- [x] **Step 4: 跑发布前短时 smoke test**

Run: `swift Scripts/test_network_traffic.swift --duration 30 --connections --strict`

Expected: 15/15 采样成功，nettop 可用。（已跑：15/15，平均 69ms）

- [x] **Step 5: 跑 8 小时稳定性回归**

Run: `swift Scripts/test_network_traffic.swift --duration 28800 --interval 10 --no-download --strict`

Expected: 全程无超时、无失败采样；日志保留并在发版说明里记录结论。

结果（2026-09-11 17:04 → 2026-09-12 01:04，日志 `/tmp/menutools-traffic-soak-20260911-170448.log`）：
**2857/2857 次采样成功，0 次超时或失败，平均 72ms、最大 133ms**，输出稳定在 1.1–1.2KB/次，无内存或句柄增长迹象。

### Task 5: 发布前打包验证

- [ ] **Step 1: 打包并签名**

Run: `./build.sh`

Expected: `dist/MenuTools.app` 组装成功。

注意：`build.sh` 的 Finder 扩展编译步骤已改为 `xcrun --sdk macosx --show-sdk-path`。
若仍报 `SDK is not supported by the compiler`，说明活动 Xcode 与 CommandLineTools
的 SDK 不是同一套，改用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh`。

- [ ] **Step 2: 按验收清单实机核对**

Run: 打开设置页并逐项走 `docs/network-traffic-acceptance.md`

Expected: 清单中 11 组全部勾选；重点是第 7 组（通知权限状态行与系统设置跳转，本次新增、尚未真机核对）
与第 11 组（插件开关不会互相停掉采样）。

- [ ] **Step 3: 确认工作区**

Run: `git status --short`

Expected: 只包含本模块相关改动。
