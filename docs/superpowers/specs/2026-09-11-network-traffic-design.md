# 网络流量模块设计

## 目标

在菜单栏常驻工具里提供**按 App 的网络流量视图**：实时上下行速率、本次运行累计、连接明细、最近 30 天历史与排名，并支持网卡/协议筛选、高流量与月度额度提醒、脱敏导出和数据清除。

定位约束：只做「谁在占带宽、占了多少、什么时候占的」，不做抓包、不做内容审计、不引入后台常驻守护进程。

## 数据通道

- 采样命令固定为 `/usr/bin/nettop`，参数由 `NetworkTrafficQuery.commandArguments` 生成：
  `-P -L 1 -c -x -n -J bytes_in,bytes_out`，协议筛选追加 `-m tcp|udp`，网卡筛选追加 `-t <接口类别>`。
  需要连接明细时去掉 `-P`（改用按连接聚合的输出）。
- 网卡筛选用的是 nettop 的**接口类别**（external、wifi、wired、awdl、expensive、loopback、undefined），不是物理网卡名；VPN（utun）等隧道不会单列。
- 进程身份由 `NetworkProcessIdentityProviding` 解析：进程名 + PID → App 身份（Bundle ID 优先）。同名 App 用 Bundle ID 独立聚合；PID 被复用、计数器回退等异常都按「不回退、不串号」处理。
- 接口信息（IPv4/IPv6、VPN）由 `NetworkTrafficInterfaceInspector` 从系统接口地址读取，只用于展示，不参与流量归属。
- 所有系统依赖都在协议边界后（`NetworkTrafficProviding`、`NetworkTrafficProcessRunner`、`NetworkProcessIdentityProviding`），纯计算与解析可用 Swift Testing 覆盖。

## 采样策略

`NetworkTrafficSamplingPolicy.interval(liveObserverCount:alertEnabled:)`：

| 状态 | 间隔 |
|---|---|
| 面板或设置页可见（`beginLiveView` 计数 > 0） | 2 秒 |
| 仅开启提醒 | 10 秒 |
| 后台 | 60 秒 |

- `start()` 幂等；`stop()` 清空本次运行累计并落盘。
- 采样进程需要排空大输出，并在超时后终止，避免 nettop 卡死拖住采样循环。
- `NetworkTrafficDiagnostics` 暴露采样耗时、连续失败次数、最后成功时间、失败原因和存储占用，设置页「诊断」页直接展示。

## 历史存储

- 存储为 SQLite + WAL（`NetworkTrafficHistoryStore`），按 `queryKey`（`interface:transport`）分维度保存。
- 分钟桶：1 天以前的桶在读取时压缩，降低查询与体积。
- 保留 30 天，按真实时间清理所有查询维度。
- 体积上限：数据库 64 MB、WAL 8 MB（`NetworkTrafficHistoryStoragePolicy`），超限时收缩页数。
- 写入是增量的：只保存发生变化的分钟桶，避免每次采样全量重写。
- 清除历史只删当前查询维度；「清除全部流量数据」同时清空历史与本次运行累计。
- 旧版 JSON 历史在首次启动时迁移到 SQLite。

## 提醒与额度

- 高流量提醒：某 App 连续 2 次采样超过阈值才提醒，提醒后同一 App 5 分钟内不再提醒，且必须回落到阈值以下才重新武装。
- 月度额度：当前范围达到 80% 和 100% 时各提醒一次，切换查询范围或修改额度后重新计数。
- 提醒通过 `UNUserNotificationCenter` 送达，**需要通知权限**：
  - `NetworkTrafficNotificationPermission`（notRequested / authorized / denied）由 `NetworkTrafficNotificationAuthorization.permission(for:)` 从系统状态映射。
  - 开启提醒或设置额度时请求授权；设置页显示当前状态，被拒时给出「打开系统设置」入口。
  - 系统弹窗是异步的，设置页在可见期间定期回读状态，用户作答后无需重开页面。

## 导出与隐私

- 导出为 CSV，选择范围 = 当前筛选出的 App + 当前时间范围。
- `NetworkTrafficExportPrivacy` 两档：`full`（保留 App 身份、进程与端点）和 `redacted`（隐藏 App 身份、进程名和连接端点）。
- 导出只写用户选择的文件，不写入 App 容器以外的固定路径。

## 生命周期与归属

- 插件 `network-traffic` 只负责 `NetworkTrafficService` 的启停，声明 `notifications` 权限。
- 网络状态卡片属于 `system-insights` 插件，`NetworkStatusService` 的后台采样（30 秒）也由该插件启停。
- `NetworkStatusService` 的监控按**观察者计数**（`beginMonitoring`/`endMonitoring`）：功能中心与网络流量设置页可以同时持有，任一方释放都不会停掉另一方仍在使用的采样。
- 菜单栏网速显示由 `NetworkTrafficMenuBarPresenter` 决定（关闭 / 总速率 / 上传+下载），随插件开关与设置项变化。

## 验收标准

- 面板与设置页的 App 速率、累计、连接明细与 nettop 输出一致。
- 采样失败（命令不可用、超时、权限、输出异常）不伪造流量，并在诊断页可见。
- 历史可写入、按 ISO8601 读取、按真实时间清理、按范围清除，旧 JSON 可迁移。
- 提醒与额度按上述去重规则各触发一次，通知被拒时设置页状态可见且可跳转恢复。
- 导出两种隐私档位字段正确，脱敏档不泄露 App 身份与端点。
- 五种内置语言文案齐全；`swift test`、`swift build -c release` 与 `Scripts/test_network_traffic.swift` 通过。
