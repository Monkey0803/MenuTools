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

    static func kebab(_ rawValue: String) -> String {
        var result = ""
        for scalar in rawValue.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if !result.isEmpty { result.append("-") }
                result.append(String(scalar).lowercased())
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// 通过 URL 触发的窗口操作。
enum MenuToolsURLAction: Equatable {
    case layout(WindowLayout)
    case preset(String)
}

/// `menutools://` 链接解析。
///
/// 支持的写法（便于 Raycast、快捷指令、脚本调用）：
///
///     menutools://window?layout=left-half
///     menutools://action?name=left-half      # 与 Rectangle 的 execute-action 习惯一致
///     menutools://preset?name=开发
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
        }
    }
}
