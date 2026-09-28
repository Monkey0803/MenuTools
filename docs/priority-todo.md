# MenuTools 待办与优先级

> **基线**：1.1.4 已发布，当前开发分支 1.1.5 ｜ **生成时间**：2026-09-28
> **来源**：对 14 个内置模块的只读代码走查，加上本机实测（进程开销、数据目录、`vm_stat`、系统路径存在性、线上链接）
> **定位约束**：常驻菜单栏的「轻量、高频、菜单栏优先」工具集。与这条定位冲突的候选**一律不列入待办**，见文末「明确不做」。

## 优先级定义

| 级别 | 含义 | 处理时机 |
|---|---|---|
| **P0** | 已上线功能**给出错误结果**、**静默丢失配置**，或**完全失效** | 立即修，修完再谈其他 |
| **P1** | 高频失败无反馈/无修复路径、安全加固、性能与常驻开销、旗舰能力的可发现性硬伤 | 1.1.5 内 |
| **P2** | 体验与一致性打磨、半成品的最后一段 UI、无障碍 | 1.1.5 有余力或 1.1.6 |
| **P3** | 文档与低价值清理 | 随手做 |

## 证据可信度说明

- 每条都给出 `文件:行号`，可自行复核。
- **四条 P0 的代码我都独立复核过**；其中「内存口径」与「锁屏路径」还在本机实测复现（结论写在各条的「本机实测」里）。
- 少数无法从代码确定的**系统行为**已明确标注「**未验证**」，请不要当成结论使用。
- 本文档刻意排除了「已经做对的事」，例如：五语种键齐全、无重复键、格式符一致、界面文案无硬编码中文（`Tests/MenuToolsTests/L10nTests.swift` 已强制）；资源采样分级（面板 2s / 告警 10s / 否则停止）；网络历史按容量上限裁剪。

---

# P0：先修这四条（四条均已修复，见各条状态）

## P0-1 内存口径把「文件缓存」算成已用内存，污染四个已上线界面

> **状态：已修复（`3772d2b`）**。已用改按活跃 + 常驻 + 压缩；压力优先读内核信号，仅信号缺失或取值未知时回退比例。本机实测对照：新口径 70.2%、旧口径 94.8%，分区求和与物理内存偏差 1.9%，同期内核信号 normal。新增 `Scripts/test_memory_metrics.swift` 与 3 条用例。

- **现象**：内存读数恒定贴近满值，压力恒为「临界」，面板常驻红色「释放内存」按钮，菜单栏内存百分比虚高，内存告警持续误报。
- **证据**：
  - `Sources/MenuTools/Services/SystemResourceService.swift:373-390` —— 已用 = `total - free_count × pageSize`
  - 同文件 `:124-134` —— 压力**完全**由该比例在 0.75 / 0.9 处切档
  - 同文件 `:704-706` —— `shouldOfferMemoryRelease` 只在 `.critical` 为真
  - `Sources/MenuTools/Services/MenuBarMetric.swift:61-64`、`Sources/MenuTools/Services/SystemResourceAlerts.swift:78` —— 菜单栏与告警同源
  - `Sources/MenuTools/SystemResourceSettingsView.swift:642-644` 把百分比上限夹到 99，而自检里同一函数 `:166-168` 夹到 1，两处口径自相矛盾
- **本机实测**（32.00 GB，page 16 KiB）：`Pages free: 21189` → 空闲约 0.32 GB → 按该口径已用 ≈ **99%**；而内核 `kern.memorystatus_vm_pressure_level = **2**`（warning，非 critical）。macOS 会把大量内存用作文件缓存，`total - free` 必然虚高。
- **影响面**：面板数值、菜单栏百分比、资源历史趋势、内存告警——四处同时失真。对一个「系统信息」类工具，数据不可信是地基问题。
- **改法**：已用改按 `active + wired + compressed` 计；压力直接读 `kern.memorystatus_vm_pressure_level`；`cached` 明细口径与「已用」统一（现在用的是 purgeable+speculative，与已用口径打架）。
- **验收**：面板「已用」与「活动监视器 → 内存」同量级；压力档位与内核信号一致；`Tests/MenuToolsTests/SystemResourceServiceTests.swift:137-139` 是按「比例→档位」写的，需同步改预期。
- **风险**：历史库新旧数据尺度不同，需在 README 与更新说明里点明。

## P0-2 「锁定屏幕」快捷操作在本机已彻底失效

> **状态：已修复（`8621b54`）**。改走 `login.framework` 私有符号 `SACLockScreenImmediate`（本机可解析、无需任何权限），旧版 CGSession 保留为老系统回退；两个通道都不可用时给出可读原因。删除了那条只断言死路径的用例，补 7 条用例，并新增 `Scripts/test_screen_lock.swift`（默认只探测）。

- **现象**：点「锁定屏幕」直接报错。TODO.md:19 把它列为已完成功能。
- **证据**：
  - `Sources/MenuTools/Services/QuickActionService.swift:148` —— 硬编码 `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession`
  - 同文件 `:167-168` —— `.lockScreen` 直接执行该路径，**没有** `isSupported` 能力检查
  - `Tests/MenuToolsTests/QuickActionServiceTests.swift:52-61` —— 用例只断言「路径字符串等于这个值」，所以测试全绿而现实无效
- **本机实测**：该路径**不存在**；`/System/Library/CoreServices/Menu Extras/` 下只剩 9 个 `.menu`（AirPort / DwellControl / Eject / ExpressCard / PPP / PPPoE / SafeEjectGPUExtra / TimeMachine / VPN），没有 `User.menu`。
- **改法**：换成当前系统可用的锁屏通道；加能力探测，缺能力时给可读原因而不是原始 `Process` 错误；按项目既有约定新增一个 `Scripts/test_*.swift` 回归脚本（对照 `Scripts/test_nightshift*.swift`）。
- **验收**：真机点击能锁屏；能力缺失时面板提示可读。

## P0-3 导入备份后插件配置不生效，且会被下一次开关操作静默回写覆盖

> **状态：已修复（`3de9c34`）**。新增 `BuiltInPluginManager.reloadFromStorage()`（重建顺序与启用集合并对齐运行时）与 `AppBackupService.applyRestoredState()`（落盘 + 广播 + 插件重载 + 滚动重载的统一入口），设置页改为只调用它。补 4 条用例，含导入备份端到端。

- **现象**：导入一份「截图/音频已关闭」的备份后，功能中心开关、后台监听、面板入口**全部仍是旧状态**；用户随后拨动任意一个开关，旧状态被整体写回，刚导入的配置被抹掉。
- **证据**：
  - `Sources/MenuTools/AppBackupService.swift:242` —— 恢复插件配置只调 `BuiltInPluginManager.persist(...)`（静态方法，仅写 UserDefaults）
  - `Sources/MenuTools/Plugins/BuiltInPluginManager.swift` —— 内存态 `enabledPluginIDs`/`orderedPluginIDs` **只在 `init` 读一次**，全类**没有 reload API**；而 `:311-321` 的 `persist()` 在任何后续开关/排序时用旧内存态重写 `plugins.state.v1`
  - `Sources/MenuTools/SettingsView.swift:707-710` —— 恢复成功后只做了 `RightClickConfigStore.broadcast` 与 `SmoothScrollEngine.shared.reload()`，**没有**重载插件管理器
  - `Tests/MenuToolsTests/AppBackupServiceTests.swift:390-416` —— 只验静态读取，从未构造活的 manager，所以测不出这个问题
- **改法**：加 `reloadFromStorage()`（或恢复后整体重启插件），复用已有的 `startEnabledPlugins` 失败收集；注意 stop/start 顺序。
- **验收**：备份「关掉截图/音频」→ 导入 → 功能中心开关与后台监听**立刻**一致；再拨动一个无关开关，配置不回退。

## P0-4 未授予屏幕录制时不主动申请，且会静默产出「墙纸图」并当作成功

> **状态：已修复（`925580f`）**。四条公开入口共同的私有 capture 内加权限预检，未授权直接抛 `ScreenshotError.screenRecordingDenied` 并阻断命令行回退；设置页对权限类错误给出直达系统设置的按钮。补 4 条用例。**未加入** 程序化主动申请（阻塞式 TCC 弹窗且刚授权需重启才生效），由错误文案与跳转按钮引导——与本文档既定改法一致。

- **现象**：未授权时没有任何申请入口；ScreenCaptureKit 失败被 `try?` 吞掉后回退 `screencapture`，得到的空桌面/墙纸图因为「可解码且宽高 > 0」被判定成功，进入截图历史与快捷卡片。README.md:403 却承诺「拒绝权限时会在面板显示失败原因」。
- **证据**：
  - 全仓库**无** `CGRequestScreenCaptureAccess`；只有 `Sources/MenuTools/RuntimeStatusCenter.swift:190` 的只读 `CGPreflightScreenCaptureAccess()`
  - `Sources/MenuTools/Services/ScreenshotService.swift:979-991`（全屏）、`:996-1008`（窗口）—— `try?` 吞掉捕获错误后回退命令行采集
  - 同文件 `:1562-1570` —— `validatedImageURL` 只校验文件存在、可解码、宽高 > 0
  - `README.md:403` —— 与实现不符的承诺
- **改法**：未授权时显式报错并给系统设置跳转（复用 `RuntimePermissionSettingsLink.url(for: .screenRecording)`）；采集异常时不要静默回退成「成功」。若要做「墙纸图」识别，需先单独验证启发式可靠性——**未验证**，不建议作为第一版方案。
- **验收**：未授权时触发截图 → 明确提示 + 一键跳转，**不产出图片**；授权后正常。

---

# P1：1.1.5 内建议完成（已完成 6/11，见各条状态）

## 失败路径与信任

### P1-1 截屏快捷键失败完全无声

> **状态：已修复（`77873f8`）**。HUD 增加任意文案能力并抽出 `TransientMessagePresenting`；截图与区域 OCR 的快捷键失败都会弹提示，不再只写无人读取的 `lastError`。补 5 条用例。
- **证据**：`Sources/MenuTools/Services/ScreenshotShortcutService.swift:277-279`、`ScreenshotService.swift:1026-1029`、`ScreenshotRegionOCRService.swift:110-114` 都只写 `lastError`，全仓**无任何视图读取**这些字段（唯一读取者是窗口管理页 `WindowManagementSettingsView.swift:659`）。只有鼠标点击路径才会 `flashStatus`（`MenuPanelView.swift:1914`、`ScreenshotSettingsView.swift:324`）。
- **影响**：全局快捷键是这条功能的主交互路径，失败（权限拒绝、窗口已消失、Vision 返回空）时用户只看到「按了没反应」。
- **改法**：复用现有 HUD（`ClipboardFeedbackHUDController`、`AppVolumeHUDController`）；注意现有 HUD 只接受本地化 key，显示任意错误串需小幅扩展。
- **成本**：小。

### P1-2 场景只施加不回滚，演示模式会让 Mac 一直不休眠

> **状态：已修复（`5cc29e3`）**。抽出 `SceneSystemEffects` 能力边界，新增 `exitScene()` 按施加前的值还原可逆动作并释放防休眠（打开的应用与专注模式按 `isReversible` 排除）；`apply` 改为逐动作报告，不再遇错即中断；场景卡片新增「退出场景」。补 4 条用例。
- **证据**：`Sources/MenuTools/Services/SceneService.swift:50-84` 只有 `apply`，`:83` 设 `activeScene` 后永不清除；`:70` 调 `CaffeinateService.shared.start()`，而 `CaffeinateService.swift:17-19` 只有 toggle/start/stop，**没有时长、也没有退出场景时的自动 stop**；`:13` 定义了 `.restoreDesktopFiles` 但 `:34-40` 的三个预设**无一处使用**；`Sources/MenuTools/ProductivityToolsViews.swift:6,18-19` 只用 `activeScene` 做高亮，**没有「退出场景」入口**。
- **影响**：「用完忘记 → 合盖不睡、电池跑空」。防锁屏恰是本工具的高频卖点。
- **改法**：按动作白名单可逆化（`.enableFocus` 是 toggle、`.openFavoriteApps` 不该回滚，需排除）；面板/场景卡加「退出场景」；`Caffeinate` 增加时长或场景归属；`apply` 的「遇错即中断」改为逐动作报告。
- **成本**：中。**注意**不要借此扩成完整场景编排器。

### P1-3 权限降级路径三家不一致，翻译页连提示都没有

> **状态：已修复（`6abfe0f`）**。新增共享组件 `AccessibilityPermissionNotice`，窗口管理/应用启动器/翻译三页统一使用；三个服务补 `refreshAccessibilityPermission()`，从系统设置授权后切回应用会自动刷新。新增静态一致性用例守护该不变量。
- **证据**：
  - 做对了的：`Sources/MenuTools/ProductivityToolsViews.swift:76-88`（跳转按钮）、`ClipboardHistoryManagementSettingsSection.swift:89-98`（状态 + 重新检查）
  - `WindowManagementSettingsView.swift:59-63`、`AppLaunchSettingsView.swift:67-71` 只有静态橙色文字，**无跳转**
  - `TranslationSettingsView.swift`（仅 120 行）**完全没有权限提示**，而 `TranslationShortcutService.swift:54` 已维护 `isAccessibilityTrusted`，该值在翻译 UI 中零引用；`BuiltInPluginCatalog.swift:93` 明确声明 translation 需要 `.accessibility`
- **改法**：统一复用 `ProductivityToolsViews.swift:76-88` 的按钮与已有文案键（`shortcut.permission`、`shortcut.openPermission`）；顺带在 `onAppear` 重新读取权限（现在只在 start/stop 时刷新）。
- **成本**：小。

### P1-4 快捷操作中心与窗口管理都缺全局快捷键入口/失败反馈
- **证据**：
  - 快捷操作（锁屏/清空废纸篓/重启 Finder/刷新 DNS/打开设置页/截图）**没有任何全局快捷键**：`GlobalShortcutService` 不覆盖 `QuickAction`
  - 窗口布局快捷键失败只写 `WindowShortcutService.swift:444,460` 的 `lastError`，唯一消费点是设置页在屏时的 `WindowManagementSettingsView.swift:659`；自动应用规则更是 `try? self.apply(layout)`（`WindowManagementService.swift:848`）完全吞错
  - 设置里**没有快捷键总览/冲突清单页**（`SettingsView.swift:96-108`），7 个模块各自只在自己的 tab 里展示绑定
- **改法**：轻量 HUD 或状态栏闪烁复用 `lastError`；总览页建议只读 + 跳转，避免再造一套编辑逻辑。
- **成本**：失败提示小；总览页中。

## 可发现性

### P1-5 应用快速启动器：TODO 声称的三项能力在界面上不存在
- **证据**：
  - `TODO.md:31-34` 声明「从菜单栏搜索并启动应用 / 支持收藏常用应用 / 显示最近使用」
  - `Sources/MenuTools/Services/AppLauncherService.swift:122-129` 的 `toggleFavorite` 在 `Sources/` 内**零调用**（对比 `AppVolumeViews.swift:1569`、`ClipboardSnippetSettingsSection.swift:195` 都调了各自的），因此 `favoritePaths` **永远为空**
  - `Sources/MenuTools/Services/SceneService.swift:63-66` 的「工作模式打开收藏 App」遍历 `launcher.favoriteApps` → **结构性空操作**
  - `Sources/MenuTools/MenuPanelNavigation.swift:16-20` 的 `MenuPanelFeature` **没有 launcher 条目**，面板无启动器卡片
  - 最近使用：`AppLauncherService.swift:135-136` **会**记录 `recentPaths`，但没有任何界面展示它
  - 已有的部分：`AppLaunchSettingsView.swift` 可按快捷键绑定应用，其选择弹窗 `:391-438` 带搜索；`:51-60` 的列表只显示「已绑定快捷键」的应用
- **准确表述**（避免夸大）：以快捷键启动单个 App 可用；但「搜索启动」「收藏」「最近使用」三项无 UI，收藏更没有任何写入入口。
- **改法**：面板加启动器入口（搜索 + 收藏开关 + 最近列表），补 `MenuPanelFeature` 条目；服务与排序逻辑（`AppLauncherCatalog.visibleApps`）已就绪且可测。
- **成本**：中。

### P1-6 窗口管理在主面板没有任何入口
- **证据**：`MenuPanelNavigation.swift:16-20` 无窗口管理；`MenuPanelView` 无相关卡片；唯一弹面板入口 `MenuBarStatusItemController.swift:300` 的 `showWindowManagement()` 仅被 `WindowShortcutService.swift:167` 的默认闭包调用，而 `loadQuickAccessBinding` **无默认值**（`WindowShortcutService.swift:500-503`，默认 nil）；状态栏只处理左键（`MenuBarStatusItemController.swift:96-98`），无右键菜单。
- **影响**：60 种布局/预设/规则是旗舰能力，默认安装下**鼠标不可达**，必须先知道并手动配一个全局快捷键。与「菜单栏优先」定位直接冲突。
- **附带**：快速面板本身缺键盘操作——`WindowManagementQuickAccessView.swift` 全文无 `.onSubmit`/`keyboardShortcut`/Esc，搜索框回车无效。
- **成本**：入口小～中；键盘支持为纯前端增量。

### P1-7 菜单栏指标选择器与插件启停脱钩：选了没反应且无解释

> **状态：已修复（`1562928`）**。新增 `MenuBarMetric.requiredPlugin` 与 `isAvailable(enabledPluginIDs:)`（映射与菜单栏取值门槛一致），停用模块的指标在 Picker 里禁用并给出橙色说明。补 1 条用例。
- **证据**：`SettingsView.swift:504-509` 的 Picker 无条件列出全部 `MenuBarMetric`，不按插件启用状态过滤或禁用；而标题按插件开关逐项置 nil（`MenuBarStatusItemController.swift:118-123` 网速、`:131-139` 音量、`:151-156` 资源），`:160-178` 在 title 为 nil 时退化成应用名或空。
- **影响**：在功能中心关掉「系统监控」后再选「CPU」，菜单栏什么也不显示，设置页也不说原因——极易被判为 bug。
- **改法**：Picker 内对停用插件对应的 metric 加 `.disabled` + 一行说明；与 `MenuBarMetric.swift:30-43` 的 automatic 回退语义对齐。
- **成本**：小。

## 安全

### P1-8 Finder 右键命令通道无来源校验，本机任意进程可伪造命令
- **证据**：
  - `Sources/MenuTools/RightClickConfig.swift:621-628` —— 发送就是裸 `DistributedNotificationCenter.postNotificationName`
  - `Sources/MenuTools/Services/RightClickCommandHandler.swift:16-24` —— 以 `object: nil` 监听，**不校验发送者身份**
  - 校验只做 JSON 形状、不做身份（`Sources/MenuTools/Services/RightClickCommandPolicy.swift:19-73`）
  - `RightClickCommandHandler.swift:223-230` 的 `copyFileContents` **无任何确认**直接读文件并写入通用剪贴板；`:231-245` 的目录清单/文件信息同理
- **影响**：本地任意进程拼一个 `action + paths` 的 JSON 广播，即可让 MenuTools 读取任意用户可读文件并把内容放到任何进程都能读回的 `NSPasteboard`。属「静默读文件」级别。
- **改法**：敏感动作二次确认 + requestID 时效窗（成本中）；真正的认证需要改 `NSXPCConnection`（成本大，会重写 `RightClickExtensionSupport.swift:217-284` 的重投状态机，**建议单独立项**，不要混在 1.1.5）。
- **未验证**：macOS 对非沙盒进程 post 分布式通知是否有额外限制。

## 性能与磁盘

### P1-9 数据目录残留 116 MB，无任何可见性或清理入口

> **状态：已修复（`74596a1`）**。新增 `MigrationResidueCleaner`：7 天保留期后清理，且仅在替代库存在时才删；应用启动时执行。真机验证：112 MB + 4.2 MB 残留已被删除，替换库与附件完好，释放约 116 MB。补 2 条用例。
- **本机实测**（`~/Library/Application Support/MenuTools/`）：
  - `ClipboardHistory.json.migrated` = **112 MB**（迁移到 SQLite 时留下的安全备份，2026-09-04）
  - `network-traffic-history.json` = **4.2 MB**（迁移到 SQLite 前的旧文件）
  - 对照：`ClipboardHistory.sqlite3` 164 KB、`ClipboardHistory.blobs` 8.9 MB、`network-traffic-history.sqlite3` 49 MB（已接近 README 所述 64 MB 上限）
- **证据**：`Sources/MenuTools/Services/ClipboardHistoryService.swift:1645-1653` —— 迁移成功后把旧 JSON **移动**为 `.migrated` 作为备份，**全仓库没有任何代码删除它**（`:1677` 的 `removeItem` 删的是 `ClipboardHistory.sqlite3.backup`，不是它）。`NetworkTrafficService.swift:1032-1045` 迁移后同样没有删除旧 JSON。
- **影响**：用户磁盘上有上百 MB 无用数据，应用内既看不到也清不掉；存储分析模块只分析固定的开发者目录，覆盖不到自己的数据目录。
- **改法**：迁移备份加保留期（如 7 天）或提供一次性清理；把「应用自身数据占用」纳入存储分析或运行状态中心；至少要在更新说明里说明这些文件的作用。
- **成本**：小～中。

### P1-10 主线程同步采样：面板打开时每 2 秒在主线程做 IOKit / getifaddrs / 全量进程枚举 / 同步子进程
- **证据**：
  - `Sources/MenuTools/Services/SystemResourceService.swift:574-580` → `:583-592` 的 `refresh()` 在 `@MainActor` 上直接调 `provider.read()`；`:246-272` 内含 `host_statistics64`、`IOServiceMatching("IOBlockStorageDriver")` 遍历、`getifaddrs`、`URL.resourceValues`
  - `Sources/MenuTools/Services/SystemProcessResourceService.swift:213-224` 同样主线程 2 秒采样；`:127-161` 对每个 pid 做 `proc_listpids` + `proc_pid_rusage` + `proc_name`
  - `Sources/MenuTools/Services/NetworkStatusService.swift:231-244` 用 `waitUntilExit()` 同步跑子进程；`:184` 每 30 秒同步跑 `/usr/sbin/scutil --nc list`
  - `Sources/MenuTools/Services/SystemToggleService.swift:94-110` 每个开关读取都同步 `waitUntilExit`
- **对照**：同一代码库已有正确做法——`BatteryHealthService.swift:121-123` 用 `Task.detached`，AGENTS.md 也写明 DerivedData 统计要放后台。
- **本机实测**：主进程 RSS 88.4 MB、瞬时 CPU 2.6%、13 线程（运行 42 分钟后采样）。
- **改法**：把 `provider.read` 移出主线程并保留 Sendable 边界；注意 `SystemResourceSelfCheck.swift:107-123` 断言了 `currentSamplingInterval`，异步化后自检仍要能读到档位。
- **成本**：中（涉及 3 个服务 + 自检页）。

### P1-11 音频：睡眠定时结束后不恢复原音量；停用模块也不会取消定时

> **状态：已修复（`f60a1b9`）**。结束后保留「定时前的音量」并新增「恢复到定时前」（「知道了」= 接受静音）；`stop()` 会先取消定时并恢复音量。补 3 条用例。
- **证据**：`AppVolumeService.swift:2120-2136` 到点 `setMasterVolume(0)` + `setMasterMuted(true)`，`baseVolume` 随之丢弃；`AppVolumeViews.swift:970-980` 结束后只有「知道了」按钮；`AppVolumeService.swift:1179-1186` 的 `stop()` 取消只在 `cancelSleepTimer`（`:2109`）里做，`stop()` **不取消** `sleepTimerTask`。
- **影响**：「定时结束 → 主音量永久 0% 且无恢复入口」；停用插件后定时任务仍在跑并继续写音量。
- **改法**：保留 `baseVolume` 到用户确认并提供「恢复到定时前」；`stop()` 里取消定时任务。纯状态改动，可先用 `AppVolumeEnhancementsTests` 补测试。
- **成本**：小。

---

# P2：打磨与半成品

| # | 项 | 证据 | 说明 | 成本 |
|---|---|---|---|---|
| P2-1 | 剪贴板历史「实际占用」不可见、无「立即清理」 | `ClipboardHistoryManagementSettingsSection.swift:32-46`、`:52-64`；`storageSize` 仅在 buffer 裁剪与瞬时摘要中用到（`ClipboardHistoryService.swift:1533`、`:2697-2698`），**无视图读取** | 唯一会自动发生却完全不可见的机制；需后台统计 sqlite + blobs（别硬编码路径，用 `ClipboardHistoryPersistence.blobsURL`） | 中 |
| P2-2 | 常用片段以**明文** JSON 落盘，与历史的 AES-GCM 不一致 | `ClipboardSnippetService.swift:459-468` 裸 `JSONEncoder` 写 `ClipboardSnippets.json`；历史走 `ClipboardHistoryEncryption.seal`；归档导出**含**片段且加密 | 用户会把 token/命令存进片段；迁移必须"读得到旧明文、写回密文" | 中 |
| P2-3 | 「按内容类型分别保留」已实现已持久化，但**无 UI 可设** | `ClipboardHistoryService.swift:2404-2417`；唯一调用方是测试 `ClipboardHistoryTests.swift:46` | 图片最易撑爆容量，正是该能力的价值点；UI 需收敛 5 个 case | 小 |
| P2-4 | 暂停记录后无任何全局可见提示 | `ClipboardHistoryService.swift:2518-2522`；`isRecordingPaused` 唯一消费者是隐私页那个开关本身 | 几天后看到历史不增长会以为功能坏了 | 小 |
| P2-5 | 已存钥匙串口令时手动「立即同步」仍强制重输 | 按钮禁用条件含 `archivePassphrase.isEmpty`（`ClipboardPrivacySettingsSection.swift:229-235`），但服务本身支持回退钥匙串（`ClipboardAutoSyncService.swift:343-348`），且**音频预设同步页早已用 `hasStoredPassphrase` 正确处理**（`AppVolumeViews.swift:693-726`） | 同库内已有正确范式，照抄即可 | 小 |
| P2-6 | 历史容量档位被藏在「筛选」菜单里 | `ClipboardHistorySettingsView.swift:319-326`，且参与「筛选已生效」计数徽标 | 容量是保留策略而非筛选条件，管理区反而没有 | 小 |
| P2-7 | 图片 OCR 无总开关，识别闸门状态不可见 | `ClipboardHistoryService.swift:2731-2771` 无条件排队；无对应 SettingsKey；闸门是进程级串行（`ScreenshotOCRService.swift:44-67`） | 覆盖隐私/发热诉求；关闭后 recognizedText 与二维码结果都会消失，需说明 | 小 |
| P2-8 | 标注器撤销过弱：裁剪/旋转**不可逆丢失全部标注**，且无 redo | `ScreenshotEditorView.swift:519-525` `undo()` 只是 `popLast()`；`:527-538` `applyCrop` 与 `:540-548` `rotateImage` 都 `annotations.removeAll()`；撤销按钮以 `annotations.isEmpty` 为禁用条件 | 误剪一刀回不到原图 | 中 |
| P2-9 | 截图历史只露 8 条（存量上限 50），无搜索/时间/定位，清空无确认 | `ScreenshotSettingsView.swift:218` `prefix(8)`；`ScreenshotOutputService.swift:182` 上限 50；`:260-262` 清空无二次确认 | 50 条被 UI 压成 8 条，找上周的图只能翻 Finder | 小～中 |
| P2-10 | 标注器零键盘快捷键、图标按钮缺无障碍标签 | `ScreenshotEditorView.swift` 内 `keyboardShortcut` 命中 0；`:234-286` 均为纯图标按钮且只有 `.help` | 对比同模块 `ScreenshotSettingsView.swift:147,156` 已有 label | 小 |
| P2-11 | 平滑滚动运行状态与失败原因不可见 | `SmoothScrollEngine.swift:461` 的 `isRunning`、`:484-498` 失败只置 false；`ScrollSettingsView.swift` 全文未引用 `isRunning` | 开关显示已开启但 tap 没装上时，用户只看到「没效果」 | 小 |
| P2-12 | 平滑滚动接管范围半成品：`hasVisibleOwnWindow` 从未接线，也无 per-App 例外 | `SmoothScrollEngine.swift:9-16`（参数存在默认 false）、`:523-526`（生产调用点不传）；`SmoothScrollMotionTests.swift:38-42` 却覆盖了这条未使用路径 | 面板内滚动会被全局 tap 改写；对照窗口管理有应用规则、剪贴板有排除 App | 小～中 |
| P2-13 | 音频：tap 建立但拿不到声音时（DRM/受保护音源）无兜底 | `CoreAudioAppVolumeBackend.swift:1128` `.mutedWhenTapped`（一建立就静音原声）、`:1247` 只记 peak/rms 无「长时间为 0」判定；`README.md:401` 的承诺只在建 tap **失败**时成立 | **未验证**：受保护音源下 tap 是否只出静音需真机验证。建议先做「检测 + 提示」，判据用 `isRunningOutput` + 连续 N 秒为 0，且不改音频行为 | 小 |
| P2-14 | 均衡器旧配置只增不减 | `CoreAudioAppVolumeBackend.swift:805`/`:858` `retainedEqualizerConfigurations.append(...)`；拖动每帧触发（`AppVolumeViews.swift:2312-2316`） | 长会话内存单调增长；指针被 IOProc 无锁读取，改成最多保留 2 份的滚动缓冲 | 小 |
| P2-15 | 设置导航：15 个 tab 无全局搜索，键盘/焦点基本不可用 | `SettingsView.swift:75-91`（15 tab）、`:48`/`:398` 主动关闭焦点环、`:638` 图标网格 `.focusable(false)`、该文件 `accessibilityLabel` 为 0；全仓 `keyboardShortcut` 仅 2 处且都是对话框按钮 | 对照主面板做得对：`MenuPanelCategoryBar.swift:103-113` 有 `.focusable()` + `onMoveCommand` + label。搜索需同步五语种键 | 中 |
| P2-16 | 右键菜单不跟随应用内语言设置 | 主程序 `L10n.swift:55-71` 读 `SettingsKey.appLanguage` 手动选 lproj；扩展 `Extension/FinderSyncExtension.swift:224` 用 `NSLocalizedString`（只按系统语言）；共享配置字段里没有语言（`RightClickConfig.swift:203`） | 非中文系统 + 手动切语言会出现「主界面英文、右键中文」。五语种键集合本身一致，属**通道**问题 | 小～中 |
| P2-17 | Finder 右键菜单构建同步做磁盘 IO 与剪贴板图片重编码，多选时卡顿 | `Extension/FinderSyncExtension.swift:69` 每次 `menu(for:)` 无条件读剪贴板；`RightClickExtensionSupport.swift:343-368` 对剪贴板 TIFF 解码 + PNG 重编码且**无体积上限**（只有 RTF/HTML 限 5MB）；`FinderSyncExtension.swift:206-210` 对每个选中项取 `resourceValues`；`:120` 每次构建对 6 个终端查 `urlForApplication` | FinderSync 要求 `menu(for:)` 快速返回，超时表现就是「菜单空白」；埋点阈值 100ms 但日志默认关 | 中 |
| P2-18 | 资源告警冷却只在内存，重启即可能重复提醒；告警面只覆盖 CPU/内存/磁盘 | `SystemResourceAlerts.swift:49-56`（内存态）、`:98-101`、`:17-23`（磁盘冷却 24h）；对照网络监控把额度告警阶段持久化（`NetworkTrafficService.swift:1985-1986`） | 电池健康（`BatteryHealthService.swift:4-10` 已读 condition/healthPercent/cycleCount）无告警出口；桌面 Mac 无电池必须静默降级 | 小 |
| P2-19 | 资源页无障碍与数值口径：历史柱/每核条只认鼠标；满载显示 99% | `SystemResourceSettingsView.swift:473-510`、`:245-273` 只有视觉宽度与 `onContinuousHover`；`:642-644` 夹到 99 而 `:166-168` 夹到 1 | 键盘/VoiceOver 拿不到历史与每核数据；两处 percent 口径互相矛盾 | 小 |
| P2-20 | `menutools://` 深链覆盖过窄 | `Sources/MenuTools/Services/MenuToolsURLService.swift:35-37` 只有 `layout` / `preset` / `settings(tab)` | 快捷操作与场景无法被 Raycast/快捷指令调用；该文件 101 行**纯逻辑却零测试**（对比项目 TDD 规范要求优先覆盖纯逻辑） | 小 |
| P2-21 | 设置页错误呈现各写各的 | `errorMessage`（翻译 `TranslationSettingsView.swift:10`）、`feedback`（存储 `SystemStorageSettingsView.swift:10`）、`ErrorBanner`（网络监控 `NetworkTrafficSettingsView.swift:176`）、`alert`（截图）；`SystemResourceSettingsView.swift` 全文件仅 1 处失败相关标识 | 面板侧已有统一的 `statusMessage` + `flashStatus`，设置侧缺同一套 | 小～中 |
| P2-22 | 插件体系三处空转 | `BuiltInPluginCatalog.swift:32-177` 的 14 个 registration **无一传 `dependencies:`**，故依赖/环检测与文案永不可达；`.finderTools` 停用只做进程内反注册，系统里 appex 仍启用（`BuiltInPluginCatalog.swift:161-168`）；`PluginCenterView.swift:174-248` 不渲染依赖与连锁影响 | 「关了还在」的信任问题；系统扩展本就无法由 App 完全撤销，应诚实提示 | 小～中 |

---

# P3：文档与清理

**文档与实现不一致清单**（均已核实）：

| 文档位置 | 现写内容 | 实际 |
|---|---|---|
| `TODO.md:19` | 锁定屏幕已完成 | **已失效**（见 P0-2） |
| `TODO.md:31-34` | 启动器支持搜索/收藏/最近 | UI 不存在，收藏无写入入口（见 P1-5） |
| `TODO.md:45` | 网络卡片显示 Wi-Fi 名称 | 无 CoreLocation 引用、`Info.plist` 无 `NSLocation*` 键；macOS 26/27 起 `ssid()` 需定位授权，未授权返回 nil 后静默显示 `en0`（`MenuPanelView.swift:1154-1158`）。**系统行为未验证** |
| `TODO.md:114` | 温度监控「暂不优先」 | 实现已在跑 AppleSMC 私有调用（`SystemResourceOptionalMetrics.swift:75-197`）并配了 `Scripts/test_smc_temperature.swift`——文档/TODO/实现三方不一致 |
| `README.md:403` | 拒绝权限时面板显示失败原因 | 截屏路径未兑现（见 P0-4） |
| `README.md:80` | 链接 `docs/finder-right-click-acceptance.md` | **该文件不存在** |
| `README.md:93`、`docs/ops-guide.md:191,216,293` | 日志路径 `com.monkey0803.MenuTools` | 实际 bundle id 为 `com.qoder.menutools`，数据目录是 `~/Library/Application Support/MenuTools/` |
| `docs/system-and-audio-acceptance.md:3` | 「待验收」 | 该改造已随 1.1.3/1.1.4 上线；同文件 `:88/:139`、`:95/:146` 两段重复，`:101`(687pt) 与 `:152`(843pt) 屏数互相矛盾 |
| `Extension/Info.plist` | 扩展版本 1.0.0 | 主程序已是 1.1.5，扩展版本从未跟上 |

**其他清理项**：

- `Sources/MenuTools/SystemStorageSettingsView.swift:208-215` —— `if/else if` 块缩进比同级 `Button` 浅一层、内层 `Text` 多缩一层（纯排版，编译无误）。
- `Sources/MenuTools/MenuBarStatusItemController.swift:187` —— 每次点面板无条件写 `/tmp/menutools-status-toggle.marker`，全仓无消费者。
- `Sources/MenuTools/Services/SparkleUpdateService.swift:141-145` —— 启动失败只 `NSLog`；`SettingsView.swift:585` 的灰按钮无任何解释。
- `Sources/MenuTools/Services/AppUpdateReminder.swift:11-34` —— 提醒仅存内存；`availableNotes` 从不展示。
- `Resources/ReleaseNotes.md`、`appcast.xml` 的更新说明只有中文，而应用界面支持五语种。
- 右键健康检查页三处结论不可信：`RightClickHealthCheckView.swift:76-78` 先 `resolveBaseDirectory()`（该函数已过滤不可写候选并有兜底）再测可写 → **该卡不可能变红**；`:83-88` 的「辅助功能与自动化」卡实际测的是 `AXIsProcessTrusted()`（辅助功能）却只讲自动化文案，且无修复入口（同库正确做法见 `RuntimeStatusCenter.swift:189,196` 与 `RuntimePermissionSettingsLink`（`:232-246`））；`:99-105` 的「查看日志」只在 Finder 里打开目录，而 `RightClickLogger.swift:110-124` 的 `readRecent`/`clear` 除测试外**无人调用**、日志上限 1000 行且关闭后旧日志永久留盘。
- `Extension/Info.plist:15-18` 版本号脱节（见上表）。
- `Sources/MenuTools/AppLauncherService.swift:95-101` 的 `refresh()` 同步扫 5 个目录——接 P1-5 的 UI 时需保持现有 `.task` 调用方式。

---

# 附：本轮 P0 验证中顺带发现并已修复

- **测试会写入用户真实历史库**（已修复，`e994e6a`）：`SystemResourceService` 有 5 处测试构造漏传 `historyStore`，于是走默认路径把合成数据（`memory_used=1` / `memory_total=2`、cpu 与磁盘均为 0）写进 `~/Library/Application Support/MenuTools/system-resource-history.sqlite3`。由于 `release.sh` 每次发版都会跑测试，等于每次发版都往用户库里写脏行；在真实库中已观测到 36 行。
- 修复后验证：跑完整套件前后库内假数据行数不变；**应用停止时整套 954 个测试对数据目录的写入为 0 个文件**（此前审计到的剪贴板写入来自正在运行的应用本身，不是测试）。
- 用户库中已有的 36 行旧脏数据未自动清理（避免破坏性操作），可在 设置 → 系统监控 → 历史 里清除。

# 明确不做（守护定位）

| 候选 | 为什么不列入 |
|---|---|
| 剪贴板云同步 / 账号体系 | `TODO.md:87` 已明确搁置；共享文件夹 + 口令加密已覆盖多设备 |
| 自建终端 | `TODO.md:115`：会明显扩大项目边界 |
| AI 助手 | `TODO.md:116`：偏离轻量系统工具定位 |
| 温度监控「正式化」 | `TODO.md:114`：依赖私有 API，系统升级有稳定性风险。**只建议把现状写进已有限制清单**，不新增承诺 |
| Finder 扩展 XPC 认证改造 | 会重写重投状态机并引入常驻组件，与「零 daemon」现状冲突；先做 P1-8 的小改动 |
| 翻译历史、截图图库化 | 明显增加模块体量，收益低于成本 |

---

# 建议的 1.1.5 范围

1. **四条 P0 全做**（内存口径、锁屏、备份恢复、截屏权限）——都是「现在就是错的」，且各自成本不大。
2. **P1 里优先做成本小、信任收益高的四组**：P1-1/P1-3（失败与权限可见性）、P1-2（场景回滚 + 防休眠释放）、P1-7（菜单栏指标与插件脱钩）、P1-9（磁盘残留清理）。
3. **P1-5/P1-6**（启动器与窗口管理的主面板入口）建议同批做，因为它们共享「能力已实现、只差最后一段 UI」的性质，且直接兑现「菜单栏优先」。
4. P1-4、P1-8、P1-10、P1-11 视余力排入，其中 P1-10（主线程采样）建议单独立项做，避免与 P0-1 的内存口径改动互相干扰。