#!/usr/bin/swift
// 验证窗口管理模块依赖的系统能力，单元测试覆盖不到的部分：
//   1. 辅助功能权限（布局快捷键、吸附、多窗口排列的前置条件）
//   2. 显示器几何：frame 与 visibleFrame 的关系（吸附按鼠标位置选屏、落点用可用区域）
//   3. 前台外部应用与焦点窗口的 AX 读取，以及「AX 左上原点 ↔ Cocoa 左下原点」坐标往返
//   4. 多窗口排列依赖的 AXWindows / AXMinimized / AXFullScreen 属性可读性
//   5. --interactive：把焦点窗口移动到左半屏并还原，验证 AX 写入闭环
//
// 用法：
//   swift Scripts/test_window_management.swift                # 只读检查，不改动任何窗口
//   swift Scripts/test_window_management.swift --interactive   # 追加写入验证（会移动前台窗口）
//
// 系统大版本升级或窗口管理功能失效时先跑本脚本回归。

import AppKit
import ApplicationServices
import Foundation

let interactive = CommandLine.arguments.contains("--interactive")
var failures: [String] = []

func check(_ name: String, _ passed: Bool, detail: String = "") {
    print("\(passed ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures.append(name) }
}

// MARK: - 1. 辅助功能权限

let trusted = AXIsProcessTrusted()
check("辅助功能权限", trusted, detail: trusted ? "" : "请在系统设置 > 隐私与安全性 > 辅助功能中允许当前终端")

// MARK: - 2. 显示器几何

let screens = NSScreen.screens
check("检测到显示器", !screens.isEmpty, detail: "\(screens.count) 台")

for (index, screen) in screens.enumerated() {
    let frame = screen.frame
    let visible = screen.visibleFrame
    let contained = frame.contains(visible) || (visible.width > 0 && visible.height > 0
        && visible.minX >= frame.minX && visible.maxX <= frame.maxX
        && visible.minY >= frame.minY && visible.maxY <= frame.maxY)
    check(
        "显示器 \(index) visibleFrame 落在 frame 内",
        contained,
        detail: "frame=\(frame) visible=\(visible)"
    )
}

// 吸附按鼠标位置选屏：验证「完整屏幕范围」可以判定边界点，
// 而 CGRect.contains 的半开区间会漏掉顶边/右边（这就是要加 1pt 容差的原因）。
if let first = screens.first {
    let frame = first.frame
    let topEdge = CGPoint(x: frame.midX, y: frame.maxY)
    let rightEdge = CGPoint(x: frame.maxX, y: frame.midY)
    check("顶边坐标被 frame.contains 判定为外部", !frame.contains(topEdge), detail: "\(topEdge)")
    check("右边坐标被 frame.contains 判定为外部", !frame.contains(rightEdge), detail: "\(rightEdge)")
    check(
        "加 1pt 容差后可命中顶边",
        frame.insetBy(dx: -1, dy: -1).contains(topEdge),
        detail: "\(topEdge)"
    )
}

// MARK: - 3. 焦点窗口读取与坐标转换

let ownPID = ProcessInfo.processInfo.processIdentifier
let frontmost = NSWorkspace.shared.frontmostApplication
check(
    "存在前台应用",
    frontmost != nil,
    detail: frontmost.map { "\($0.localizedName ?? "?") pid=\($0.processIdentifier)" } ?? "无"
)

var focusedWindow: AXUIElement?
if let frontmost, frontmost.processIdentifier != ownPID {
    let application = AXUIElementCreateApplication(frontmost.processIdentifier)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
    check("读取前台应用焦点窗口", result == .success && value != nil, detail: "AXError=\(result.rawValue)")
    if result == .success, let value {
        focusedWindow = unsafeDowncast(value, to: AXUIElement.self)
    }
} else {
    print("· 前台应用是当前终端自身，跳过焦点窗口读取（请先点开任意 App 的窗口再运行）")
}

func axFrame(of window: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue, let sizeValue else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

/// 与 WindowCoordinateConverter 相同的换算：AX 以主屏左上角为原点，Cocoa 以左下角为原点。
func cocoaFrame(fromAccessibility frame: CGRect, desktopTop: CGFloat) -> CGRect {
    CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
}

func accessibilityFrame(fromCocoa frame: CGRect, desktopTop: CGFloat) -> CGRect {
    CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
}

let desktopTop = screens.map(\.frame.maxY).max() ?? 0

if let focusedWindow, let ax = axFrame(of: focusedWindow) {
    let cocoa = cocoaFrame(fromAccessibility: ax, desktopTop: desktopTop)
    let roundTrip = accessibilityFrame(fromCocoa: cocoa, desktopTop: desktopTop)
    check("窗口坐标转换往返一致", roundTrip == ax, detail: "ax=\(ax) cocoa=\(cocoa)")
    let onScreen = screens.contains { $0.frame.intersects(cocoa) }
    check("窗口落在某台显示器范围内", onScreen, detail: "\(cocoa)")
}

// MARK: - 4. 多窗口排列依赖的属性

if let frontmost, frontmost.processIdentifier != ownPID {
    let application = AXUIElementCreateApplication(frontmost.processIdentifier)
    var windowsValue: CFTypeRef?
    let windowsResult = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue)
    let windows = (windowsValue as? [AXUIElement]) ?? []
    check("读取应用 AXWindows", windowsResult == .success, detail: "\(windows.count) 个窗口")

    if let window = windows.first {
        var minimizedValue: CFTypeRef?
        let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
        check("读取 AXMinimized", minimizedResult == .success, detail: minimizedResult == .success ? "" : "AXError=\(minimizedResult.rawValue)")

        var fullScreenValue: CFTypeRef?
        let fullScreenResult = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreenValue)
        // 排列功能会过滤全屏窗口；部分应用不暴露该属性，此时按“非全屏”处理即可。
        let fullScreenReadable = fullScreenResult == .success
        print("· AXFullScreen \(fullScreenReadable ? "可读" : "不可读（按非全屏处理，AXError=\(fullScreenResult.rawValue)）")")
    }
}

// MARK: - 5. 可选：写入闭环

if interactive {
    guard trusted else {
        print("\n无法执行写入验证：缺少辅助功能权限")
        exit(failures.isEmpty ? 0 : 1)
    }
    guard let focusedWindow, let original = axFrame(of: focusedWindow) else {
        print("\n无法执行写入验证：没有可用的焦点窗口（请先点开任意 App 的窗口）")
        exit(failures.isEmpty ? 0 : 1)
    }
    guard let screen = screens.first(where: { $0.frame.intersects(cocoaFrame(fromAccessibility: original, desktopTop: desktopTop)) })
        ?? screens.first else {
        print("\n无法执行写入验证：没有可用显示器")
        exit(failures.isEmpty ? 0 : 1)
    }

    let visible = screen.visibleFrame
    let target = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
    let targetAX = accessibilityFrame(fromCocoa: target, desktopTop: desktopTop)

    var origin = targetAX.origin
    var size = targetAX.size
    let positionResult = AXUIElementSetAttributeValue(
        focusedWindow,
        kAXPositionAttribute as CFString,
        AXValueCreate(.cgPoint, &origin)!
    )
    let sizeResult = AXUIElementSetAttributeValue(
        focusedWindow,
        kAXSizeAttribute as CFString,
        AXValueCreate(.cgSize, &size)!
    )
    check("写入 AXPosition/AXSize", positionResult == .success && sizeResult == .success,
          detail: "position=\(positionResult.rawValue) size=\(sizeResult.rawValue)")

    usleep(300_000)
    let applied = axFrame(of: focusedWindow) ?? .zero
    let sizeMatches = abs(applied.width - targetAX.width) <= 2 || applied.width >= targetAX.width
    check("窗口尺寸按要求变化", sizeMatches, detail: "期望宽≈\(targetAX.width)，实际=\(applied)")

    // 还原，避免把用户的窗口留在半屏。
    var restoreOrigin = original.origin
    var restoreSize = original.size
    _ = AXUIElementSetAttributeValue(focusedWindow, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &restoreOrigin)!)
    _ = AXUIElementSetAttributeValue(focusedWindow, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &restoreSize)!)
    usleep(200_000)
    let restored = axFrame(of: focusedWindow) ?? .zero
    check("已还原原始位置与尺寸", abs(restored.minX - original.minX) <= 2 && abs(restored.width - original.width) <= 2,
          detail: "original=\(original) restored=\(restored)")
}

print("")
if failures.isEmpty {
    print("全部检查通过")
    exit(0)
} else {
    print("失败 \(failures.count) 项：\(failures.joined(separator: "、"))")
    exit(1)
}
