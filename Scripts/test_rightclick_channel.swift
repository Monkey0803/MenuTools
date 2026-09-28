#!/usr/bin/swift
// 验证 Finder 右键命令通道的来源校验（P1-8）。
//
// 命令通过 DistributedNotificationCenter 投递，通知名是公开字符串：任何本地进程都能伪造一份
// JSON 让主进程执行文件操作。本脚本扮演「伪造者」，连续投递两条命令：
//   1. 不带通道令牌 → 宿主必须拒绝（探针字符串保持不变）
//   2. 带正确令牌   → 宿主必须执行（探针字符串被替换为文件名）
// 用剪贴板作为可观测副作用（copyFilename 只写剪贴板、不弹任何对话框），结束后恢复原内容。
//
// 用法：
//   swift Scripts/test_rightclick_channel.swift
//
// 前置条件：
//   1. MenuTools 正在运行，且「右键工具」已启用（宿主会注册命令监听）
//   2. 已用 ./build.sh 安装过带通道令牌的版本（宿主会在激活时创建令牌文件）

import AppKit
import Foundation

let commandNotification = "com.qoder.menutools.rightclick.command"
let appGroupIdentifier = "group.com.qoder.menutools"
let probeText = "menutools-channel-probe"

func exitWith(_ code: Int32, _ message: String) -> Never {
    print(message)
    exit(code)
}

/// 令牌文件位置：主 App 与扩展优先用 App Group 容器，不可写时退回 Application Support。
func tokenURL() -> (url: URL, token: String)? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent("Library/Group Containers/\(appGroupIdentifier)/MenuTools"),
        home.appendingPathComponent("Library/Application Support/MenuTools")
    ]
    for directory in candidates {
        let url = directory.appendingPathComponent("rightclick-channel.secret")
        guard let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { continue }
        return (url, token)
    }
    return nil
}

func post(action: String, paths: [String], token: String?) {
    var payload: [String: Any] = ["action": action, "paths": paths]
    if let token {
        payload["channelToken"] = token
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else { return }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(commandNotification),
        object: json,
        deliverImmediately: true
    )
}

guard let token = tokenURL() else {
    exitWith(2, "✗ 找不到通道令牌文件：请先 ./build.sh 安装并启动新版本，再运行本脚本。")
}
print("令牌文件：\(token.url.path)")

let pasteboard = NSPasteboard.general
let backup: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
    var contents: [NSPasteboard.PasteboardType: Data] = [:]
    for type in item.types {
        if let data = item.data(forType: type) { contents[type] = data }
    }
    return contents
}

func restorePasteboard() {
    pasteboard.clearContents()
    let items: [NSPasteboardItem] = backup.map { contents in
        let item = NSPasteboardItem()
        for (type, data) in contents {
            item.setData(data, forType: type)
        }
        return item
    }
    if !items.isEmpty {
        pasteboard.writeObjects(items)
    }
}

let probePath = FileManager.default.temporaryDirectory
    .appendingPathComponent("menutools-channel-spoof-\(UUID().uuidString).txt")
    .path
let expectedFilename = (probePath as NSString).lastPathComponent

pasteboard.clearContents()
pasteboard.setString(probeText, forType: .string)
let sentinel = pasteboard.string(forType: .string)

// 1) 伪造：无令牌
post(action: "copyFilename", paths: [probePath], token: nil)
Thread.sleep(forTimeInterval: 2.0)
let afterSpoof = pasteboard.string(forType: .string)
if afterSpoof != sentinel {
    restorePasteboard()
    exitWith(1, "✗ 无令牌命令被执行了（剪贴板变为 \(afterSpoof ?? "nil")）：来源校验没生效。")
}
print("✓ 无令牌命令被拒绝（剪贴板未被改动）")

// 2) 伪造：错误令牌
post(action: "copyFilename", paths: [probePath], token: "deadbeef")
Thread.sleep(forTimeInterval: 2.0)
let afterWrongToken = pasteboard.string(forType: .string)
if afterWrongToken != sentinel {
    restorePasteboard()
    exitWith(1, "✗ 错误令牌的命令被执行了（剪贴板变为 \(afterWrongToken ?? "nil")）。")
}
print("✓ 错误令牌命令被拒绝")

// 3) 合法投递：正确令牌
post(action: "copyFilename", paths: [probePath], token: token.token)
Thread.sleep(forTimeInterval: 2.0)
let afterValid = pasteboard.string(forType: .string)
restorePasteboard()
if afterValid != expectedFilename {
    exitWith(1, "✗ 带正确令牌的命令没有执行（剪贴板为 \(afterValid ?? "nil")，期望 \(expectedFilename)）。")
}
print("✓ 带正确令牌的命令正常执行（通道仍然可用）")
print("全部通过：通道只接受带正确令牌的投递。")
