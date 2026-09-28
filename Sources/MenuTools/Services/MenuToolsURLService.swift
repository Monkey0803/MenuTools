import AppKit
import Foundation

/// 布局名与 URL 名称之间的转换。
///
/// URL 里用 kebab-case（`left-half`、`top-left-sixth`），与 Rectangle 的
/// `rectangle://execute-action?name=left-half` 习惯一致；枚举的 rawValue 仍保持 camelCase。
enum WindowLayoutURLName {
    static func name(for layout: WindowLayout) -> String {
        kebab(layout.rawValue)
    }

    static func layout(from name: String) -> WindowLayout? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return WindowLayout.allCases.first { kebab($0.rawValue) == normalized }
    }

    /// camelCase → kebab-case。
    ///
    /// 连续大写属于同一个缩写词，必须整体小写：`flushDNS` → `flush-dns`。
    /// 最初的实现给每个大写字母都补连字符，于是 `flushDNS` 变成 `flush-d-n-s`，
    /// 脚本按 `flush-dns` 调用时解析直接失败。
    static func kebab(_ rawValue: String) -> String {
        var result = ""
        let scalars = Array(rawValue.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            guard CharacterSet.uppercaseLetters.contains(scalar) else {
                result.unicodeScalars.append(scalar)
                continue
            }
            let previous = index > 0 ? scalars[index - 1] : nil
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil

            var startsNewWord = false
            if let previous {
                if CharacterSet.lowercaseLetters.contains(previous)
                    || CharacterSet.decimalDigits.contains(previous) {
                    // flushDNS：前面是小写，这里是新词的开头
                    startsNewWord = true
                } else if CharacterSet.uppercaseLetters.contains(previous),
                          let next,
                          CharacterSet.lowercaseLetters.contains(next) {
                    // DNSValue → dns-value：缩写结束、下一个词开始
                    startsNewWord = true
                }
            }
            if startsNewWord, !result.isEmpty {
                result.append("-")
            }
            result.append(String(scalar).lowercased())
        }
        return result
    }
}

/// 通过 URL 触发的窗口操作。
enum MenuToolsURLAction: Equatable {
    case layout(WindowLayout)
    case preset(String)
    case settings(SettingsTab)
    case scene(ScenePreset)
    case quickAction(QuickAction)
}

/// `menutools://` 链接解析。
///
/// 支持的写法（便于 Raycast、快捷指令、脚本调用）：
///
///     menutools://window?layout=left-half
///     menutools://action?name=left-half      # 与 Rectangle 的 execute-action 习惯一致
///     menutools://preset?name=开发
///     menutools://settings?tab=runtime-status
///     menutools://scene?name=demo
///     menutools://quick-action?name=lock-screen
enum MenuToolsURL {
    static let scheme = "menutools"

    static func action(for url: URL) -> MenuToolsURLAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = (url.host ?? "").lowercased()
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func value(_ name: String) -> String? {
            queryItems.first { $0.name.lowercased() == name }?.value
        }

        switch host {
        case "window", "action":
            guard let raw = value("layout") ?? value("name"),
                  let layout = WindowLayoutURLName.layout(from: raw) else { return nil }
            return .layout(layout)
        case "preset":
            guard let name = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return .preset(name)
        case "settings":
            guard let raw = value("tab") else { return nil }
            guard let tab = SettingsTab.allCases.first(where: {
                WindowLayoutURLName.kebab($0.rawValue) == raw.lowercased()
            }) else { return nil }
            return .settings(tab)
        case "scene":
            // 场景名就是枚举 rawValue（work / demo / night），大小写不敏感。
            guard let raw = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let scene = ScenePreset(rawValue: raw) else { return nil }
            return .scene(scene)
        case "quick-action", "quickaction":
            guard let raw = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else { return nil }
            // 同时接受 kebab-case（lock-screen）与原始驼峰（lockScreen）写法。
            guard let action = QuickAction.allCases.first(where: {
                WindowLayoutURLName.kebab($0.rawValue) == raw || $0.rawValue.lowercased() == raw
            }) else { return nil }
            return .quickAction(action)
        default:
            return nil
        }
    }
}

/// 执行 URL 触发的操作。
@MainActor
enum MenuToolsURLActionHandler {
    static func perform(_ action: MenuToolsURLAction) {
        switch action {
        case let .layout(layout):
            // URL 通常来自脚本或快捷指令，此时 MenuTools 不是前台应用：
            // 先锁定当前的外部前台应用，再套用布局。
            WindowManagementService.shared.rememberFrontmostExternalApplication()
            try? WindowManagementService.shared.apply(layout)
        case let .preset(name):
            guard let preset = WindowManagementService.shared.configuration.presets.first(where: { $0.name == name }) else {
                return
            }
            WindowManagementService.shared.rememberFrontmostExternalApplication()
            try? WindowManagementService.shared.apply(preset)
        case let .settings(tab):
            MenuBarStatusItemController.shared.showSettings(tab)
        case let .scene(scene):
            // 与场景快捷键走同一条链路：逐动作报告失败，并用统一 HUD 把失败原因显示出来。
            let report = SceneService.shared.apply(
                scene,
                launcher: AppLauncherService.shared,
                focusService: FocusModeService.shared
            )
            if !report.isFullSuccess {
                ClipboardHUDMessagePresenter().show(
                    message: L("scene.appliedPartial", L(scene.titleKey), report.failures.count),
                    isSuccess: false
                )
            }
        case let .quickAction(action):
            performQuickAction(action)
        }
    }

    /// 快捷操作：与面板里的按钮走同一套实现（截图单独走捕获流程）。
    private static func performQuickAction(_ action: QuickAction) {
        if action == .screenshot {
            Task { @MainActor in
                do {
                    _ = try await ScreenshotService.shared.captureConfigured()
                } catch {
                    ClipboardHUDMessagePresenter().show(
                        message: error.localizedDescription,
                        isSuccess: false
                    )
                }
            }
            return
        }
        do {
            try QuickActionService().perform(action)
        } catch {
            ClipboardHUDMessagePresenter().show(
                message: error.localizedDescription,
                isSuccess: false
            )
        }
    }
}
