import Combine
import Foundation

/// Finder Sync 的公开状态在部分 macOS 版本上会暂时返回 false，
/// 因此同时核对系统插件注册记录，避免把已注册的扩展误报为未启用。
enum FinderSyncExtensionStatus {
    static let bundleIdentifier = "com.qoder.menutools.finder-sync"

    enum State: Equatable, Sendable {
        /// FinderSync 的公开 API 明确确认扩展可用。
        case enabled
        /// 系统插件注册表已注册扩展，但公开 API 未能确认。
        case registered
        /// 系统插件注册表明确未启用扩展。
        case disabled
        /// 无法读取系统插件注册表，不能将状态误报为未启用。
        case unknown

        var isAvailable: Bool {
            self == .enabled || self == .registered
        }
    }

    static func resolve(finderAPIEnabled: Bool, pluginRegistryOutput: String?) -> State {
        guard !finderAPIEnabled else { return .enabled }
        guard let pluginRegistryOutput else { return .unknown }

        let isRegistered = pluginRegistryOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { line in
                line.hasPrefix("+") && line.contains(bundleIdentifier)
            }
        return isRegistered ? .registered : .disabled
    }
}

@MainActor
final class FinderSyncExtensionStatusService: ObservableObject {
    @Published private(set) var state: FinderSyncExtensionStatus.State = .unknown

    func refresh(finderAPIEnabled: Bool) {
        let registryOutput: String?
        if finderAPIEnabled {
            registryOutput = nil
        } else {
            registryOutput = FinderSyncPluginRegistry.registrationOutput(
                for: FinderSyncExtensionStatus.bundleIdentifier
            )
        }
        state = FinderSyncExtensionStatus.resolve(
            finderAPIEnabled: finderAPIEnabled,
            pluginRegistryOutput: registryOutput
        )
    }
}

private enum FinderSyncPluginRegistry {
    static func registrationOutput(for bundleIdentifier: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-v", "-i", bundleIdentifier]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}
