#!/usr/bin/swift
// 验证剪贴板模块依赖的系统能力，单元测试覆盖不到的部分：
//   1. NSPasteboard 私有粘贴板读写、changeCount 与项数
//   2. 图片（PNG → TIFF）与富文本（HTML/RTF + 纯文本）的粘贴板表示
//   3. Vision 二维码/条码识别（剪贴板图片识别链路）
//   4. 辅助功能权限与 CGEvent 合成 ⌘V 的自动粘贴闭环
//
// 用法：
//   swift Scripts/test_clipboard_autopaste.swift                 # 非交互检查，不动系统剪贴板
//   swift Scripts/test_clipboard_autopaste.swift --interactive    # 追加端到端粘贴验证（会覆盖系统剪贴板）
//
// 系统大版本升级或剪贴板相关功能失效时先跑本脚本回归。

import AppKit
import ApplicationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

let interactive = CommandLine.arguments.contains("--interactive")
var failures: [String] = []

func check(_ name: String, _ passed: Bool, detail: String = "") {
    print("\(passed ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures.append(name) }
}

func qrCodePNG(payload: String) -> Data? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cgImage = CIContext().createCGImage(output, from: output.extent) else {
        return nil
    }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

/// 与 ClipboardHistoryImageData 一致：写入前把图片规范成 TIFF。
func tiffData(fromPNG data: Data) -> Data? {
    NSImage(data: data)?.tiffRepresentation
}

func synthesizeCommandV() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
        return false
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
}

func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    guard AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedUIElementAttribute as CFString,
        &focused
    ) == .success, let focused else {
        return nil
    }
    return (focused as! AXUIElement)
}

func focusedElementValue() -> String? {
    guard let element = focusedElement() else { return nil }
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

print("== 剪贴板系统能力验证 ==")
print(interactive ? "模式：非交互 + 端到端粘贴" : "模式：仅非交互（系统剪贴板不会被修改）")
print("")

// MARK: - 1. 粘贴板读写

let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsClipboardProbe.\(UUID().uuidString)"))
pasteboard.clearContents()
check("清空后项数为 0", (pasteboard.pasteboardItems?.count ?? 0) == 0, detail: "count=\(pasteboard.pasteboardItems?.count ?? -1)")

let changeCountBefore = pasteboard.changeCount
let text = "MenuTools 剪贴板验证 \(UUID().uuidString)"
pasteboard.clearContents()
check("写入文本", pasteboard.setString(text, forType: .string))
check("清空并写入后 changeCount 递增", pasteboard.changeCount > changeCountBefore,
      detail: "\(changeCountBefore) → \(pasteboard.changeCount)")
check("读回文本一致", pasteboard.string(forType: .string) == text)

// MARK: - 2. 图片与富文本表示

let payload = "https://example.com/menutools-clipboard-probe"
guard let png = qrCodePNG(payload: payload) else {
    print("✗ 生成二维码 PNG 失败，后续图片检查跳过")
    failures.append("生成二维码 PNG")
    exit(1)
}
check("生成二维码 PNG", true, detail: "\(png.count) 字节")

guard let tiff = tiffData(fromPNG: png) else {
    print("✗ PNG 规范化成 TIFF 失败")
    failures.append("PNG → TIFF")
    exit(1)
}
check("PNG 规范化成 TIFF", !tiff.isEmpty, detail: "\(tiff.count) 字节")

pasteboard.clearContents()
check("写入 TIFF 图片", pasteboard.setData(tiff, forType: .tiff))
check("读回 TIFF 图片", pasteboard.data(forType: .tiff) != nil)

// screencapture -c 在不同 macOS 版本可能写入 PNG 或 TIFF，读取路径两种都要能拿到。
pasteboard.clearContents()
check("写入 PNG 图片", pasteboard.setData(png, forType: .png))
check("读回 PNG 图片", pasteboard.data(forType: .png) != nil)

let richText = NSAttributedString(string: "MenuTools 富文本验证")
let documentRange = NSRange(location: 0, length: richText.length)
let rtf = try? richText.data(from: documentRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
let html = try? richText.data(from: documentRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])

pasteboard.clearContents()
let item = NSPasteboardItem()
if let rtf { item.setData(rtf, forType: .rtf) }
if let html { item.setData(html, forType: .html) }
item.setString("MenuTools 富文本验证", forType: .string)
check("写入富文本条目", pasteboard.writeObjects([item]))
check("读回纯文本", pasteboard.string(forType: .string) == "MenuTools 富文本验证")
check("读回 RTF", pasteboard.data(forType: .rtf) != nil)
check("读回 HTML", pasteboard.data(forType: .html) != nil)

// MARK: - 3. Vision 识别

if let cgImage = NSBitmapImageRep(data: png)?.cgImage {
    do {
        let barcodeRequest = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([barcodeRequest])
        let recognized = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
        check("Vision 识别二维码", recognized.contains(payload),
              detail: recognized.isEmpty ? "无结果" : recognized.joined(separator: ", "))
    } catch {
        check("Vision 识别二维码", false, detail: error.localizedDescription)
    }
} else {
    check("Vision 识别二维码", false, detail: "无法从 PNG 构造 CGImage")
}

// MARK: - 4. 辅助功能与自动粘贴

let trusted = AXIsProcessTrusted()
if trusted {
    print("✓ 辅助功能已授权，可合成 ⌘V")
} else {
    print("! 辅助功能未授权：剪贴板自动粘贴不可用")
    print("  开启路径：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 MenuTools（或本终端）")
}

if interactive {
    guard trusted else {
        print("")
        print("FAIL：--interactive 需要辅助功能授权，先按上面的路径授权后重试")
        exit(2)
    }

    let marker = "MenuTools-paste-probe-\(Int(Date().timeIntervalSince1970))"
    print("")
    print("端到端粘贴验证：会把标记文本写入系统剪贴板，并在 5 秒后向右下角前台 App 合成 ⌘V。")
    print("请立刻点击任意可编辑输入框（例如备忘录）并保持焦点。")
    let general = NSPasteboard.general
    general.clearContents()
    general.setString(marker, forType: .string)
    for remaining in stride(from: 5, through: 1, by: -1) {
        print("  \(remaining)…")
        Thread.sleep(forTimeInterval: 1)
    }

    let valueBefore = focusedElementValue() ?? ""
    if synthesizeCommandV() {
        Thread.sleep(forTimeInterval: 1)
        let valueAfter = focusedElementValue() ?? ""
        check("合成 ⌘V 后焦点输入框收到内容", valueAfter.contains(marker),
              detail: "粘贴前 \(valueBefore.count) 字符，粘贴后 \(valueAfter.count) 字符")
    } else {
        check("合成 ⌘V", false, detail: "无法创建 CGEvent")
    }
}

print("")
if failures.isEmpty {
    print("PASS：全部检查通过")
    exit(0)
}
print("FAIL：\(failures.count) 项失败 → \(failures.joined(separator: "、"))")
exit(1)
