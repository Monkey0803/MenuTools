#!/usr/bin/swift
// 验证设置窗口各页的「滚动长度」没有回退。
//
// 设置窗口详情区只有 568pt 高（系统监控页是 534pt），页面一旦堆长，用户就要反复滚动。
// 本脚本用辅助功能接口逐个切换子页，取详情区所有可见元素的 y 范围作为内容高度，
// 除以可视高度得到屏数，并与下面的基线比较。
//
// 用法：
//   swift Scripts/test_settings_layout.swift          # 测量并对照基线（超出上限则退出码 1）
//   swift Scripts/test_settings_layout.swift --list    # 只打印测量值，不做判定
//
// 前置条件：
//   1. MenuTools 正在运行，且已授予辅助功能权限（否则读不到窗口结构）
//   2. 桌面空闲：MenuTools 是 accessory 应用，前台被别的进程占用时可能打不开设置窗口
//
// 换显示器或改动设置页布局后，请同步更新 baseline 里的数值（--list 可以打印当前值）。

import AppKit
import ApplicationServices
import Foundation

let listOnly = CommandLine.arguments.contains("--list")

/// 每个子页的屏数上限：超过就说明页面明显变长了。
let hardLimit = 1.7
/// 相对基线的漂移告警阈值。
let driftRatio = 1.25

/// 基线：页面 / 子页 / 期望屏数（2026-09-16 用本脚本实测）。
///
/// 换显示器、改设置页布局后，跑 `--list` 拿到新值再更新这里。
let baseline: [(page: String, sub: String, screens: Double)] = [
    ("窗口管理", "布局", 1.40),
    ("窗口管理", "吸附", 1.00),
    ("窗口管理", "预设", 1.00),
    ("窗口管理", "规则", 1.00),
    ("系统监控", "概览", 1.29),
    ("系统监控", "进程", 1.13),
    ("系统监控", "历史", 1.00),
    ("系统监控", "告警", 1.07),
    ("音频", "调音台", 1.35),
    ("音频", "设备", 1.18),
    ("音频", "场景", 1.00),
    ("音频", "设置", 1.32),
    ("音频", "高级", 1.01),
]

/// 侧边栏入口关键词 → 子页分段顺序。
let pages: [(sidebar: String, title: String, segments: [String])] = [
    ("窗口管理", "窗口管理", ["布局", "吸附", "预设", "规则"]),
    ("系统监控", "系统监控", ["概览", "进程", "历史", "告警"]),
    ("音频", "音频", ["调音台", "设备", "场景", "设置", "高级"]),
]

var failures: [String] = []

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func text(_ element: AXUIElement, _ name: String = kAXTitleAttribute) -> String {
    (value(element, name) as? String) ?? ""
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func frame(of element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute) as! AXValue?,
          let size = value(element, kAXSizeAttribute) as! AXValue? else { return nil }
    var origin = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: origin, size: dimensions)
}
func label(_ element: AXUIElement) -> String {
    [text(element), text(element, kAXDescriptionAttribute), text(element, kAXValueAttribute)].joined(separator: "|")
}
func allNodes(_ root: AXUIElement, _ maxLevel: Int = 20) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func walk(_ element: AXUIElement, _ level: Int) {
        guard level < maxLevel else { return }
        result.append(element)
        for child in children(element) { walk(child, level + 1) }
    }
    walk(root, 0)
    return result
}
func find(_ root: AXUIElement, _ maxLevel: Int = 20, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    allNodes(root, maxLevel).first(where: match)
}
func press(_ element: AXUIElement) {
    _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
}
func escapeKey() {
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
        if let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: isDown) {
            event.post(tap: .cghidEventTap)
        }
        usleep(40_000)
    }
}

// MARK: - 打开设置窗口

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.qoder.menutools" }) else {
    print("✗ MenuTools 未运行"); exit(1)
}
guard AXIsProcessTrusted() else {
    print("✗ 缺少辅助功能权限：请在系统设置 > 隐私与安全性 > 辅助功能中允许当前终端"); exit(1)
}
let appElement = AXUIElementCreateApplication(app.processIdentifier)

func settingsWindow() -> AXUIElement? {
    (value(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
}

if settingsWindow() == nil {
    // 走应用菜单里的「设置…」：⌘, 对 accessory 应用不一定生效
    escapeKey()
    usleep(300_000)
    var menuBarRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
       let menuBarRef {
        let menuBar = menuBarRef as! AXUIElement
        let bars = children(menuBar)
        if bars.count > 1 {
            press(bars[1])   // 第 0 项是 Apple 菜单，第 1 项才是应用菜单
            usleep(800_000)
            let items = allNodes(bars[1], 6).filter { text($0, kAXRoleAttribute) == "AXMenuItem" }
            if let settings = items.first(where: { label($0).contains("设置") }) {
                press(settings)
                usleep(1_500_000)
            }
        }
    }
}
guard let window = settingsWindow() else {
    print("✗ 打不开设置窗口。请手动打开一次（点菜单栏图标 → 设置），或让桌面空闲后重试。")
    exit(1)
}

// MARK: - 测量

func scrollAreas() -> [AXUIElement] {
    allNodes(window).filter { text($0, kAXRoleAttribute) == kAXScrollAreaRole as String }
}
func sidebar() -> AXUIElement? {
    scrollAreas().min { (frame(of: $0)?.width ?? 0) < (frame(of: $1)?.width ?? 0) }
}
func detailArea() -> AXUIElement? {
    scrollAreas().max { (frame(of: $0)?.width ?? 0) < (frame(of: $1)?.width ?? 0) }
}

func pickSidebar(_ keyword: String) -> Bool {
    guard let bar = sidebar() else { return false }
    for _ in 0..<6 {
        _ = AXUIElementPerformAction(bar, "AXScrollUpByPage" as CFString)
        usleep(200_000)
    }
    for _ in 0..<10 {
        if let entry = find(bar, 10, { label($0).contains(keyword) }) {
            press(entry)
            usleep(1_200_000)
            return true
        }
        _ = AXUIElementPerformAction(bar, "AXScrollDownByPage" as CFString)
        usleep(250_000)
    }
    return false
}

/// 返回（内容高度, 可视高度）
func measure() -> (content: CGFloat, viewport: CGFloat)? {
    guard let area = detailArea(), let viewportFrame = frame(of: area) else { return nil }
    var minY = CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    var count = 0
    for node in allNodes(area, 14) {
        guard let nodeFrame = frame(of: node), nodeFrame.height > 2, nodeFrame.width > 2 else { continue }
        minY = min(minY, nodeFrame.minY)
        maxY = max(maxY, nodeFrame.maxY)
        count += 1
    }
    guard maxY > minY, count > 3 else { return nil }
    return (maxY - minY, viewportFrame.height)
}

print("页面 / 子页              内容      可视     屏数    基线    判定")
print("--------------------------------------------------------------------------")

var measured: [String: Double] = [:]
var didFail = false

for page in pages {
    guard pickSidebar(page.sidebar) else {
        print("✗ 侧边栏找不到「\(page.sidebar)」"); didFail = true; continue
    }
    for segment in page.segments {
        let key = "\(page.title)/\(segment)"
        guard let segmentElement = find(window, 14, {
            text($0, kAXSubroleAttribute) == "AXSegment" && label($0).contains(segment)
        }) else {
            print("✗ 找不到分段「\(key)」"); didFail = true; continue
        }
        press(segmentElement)
        usleep(1_100_000)

        guard let result = measure() else {
            print("✗ \(key)：测不到内容（页面可能还没渲染完）"); didFail = true; continue
        }
        let screens = result.content / result.viewport
        measured[key] = screens

        let expected = baseline.first { "\($0.page)/\($0.sub)" == key }?.screens
        var verdict = "✓"
        if screens > hardLimit {
            verdict = "✗ 超过上限 \(hardLimit)"
            failures.append("\(key) 为 \(String(format: "%.2f", screens)) 屏，超过上限 \(hardLimit)")
        } else if let expected, screens > expected * driftRatio {
            verdict = "⚠ 比基线长 \(Int((screens / expected - 1) * 100))%"
        }
        let expectedText = expected.map { String(format: "%.2f", $0) } ?? "—"
        print(String(format: "%-24@ %6d %8d %8.2f %7@   %@",
                     key as NSString, Int(result.content), Int(result.viewport), screens, expectedText as NSString, verdict))
    }
}

print("")
if listOnly {
    print("（--list：只测量，不做判定）")
    exit(0)
}
if didFail || !failures.isEmpty {
    for failure in failures { print("✗ \(failure)") }
    print("有页面超出滚动长度上限。改动设置页布局后请同步更新脚本里的基线。")
    exit(1)
}
print("全部子页都在基线范围内（上限 \(hardLimit) 屏）。")
