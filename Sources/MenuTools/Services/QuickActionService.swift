import AppKit
import Foundation

/// 快捷操作中心支持的系统动作。
enum QuickAction: String, CaseIterable, Identifiable, Equatable {
    case lockScreen
    case emptyTrash
    case restartFinder
    case flushDNS
    case openSystemSettings
    case screenshot

    var id: String { rawValue }

    var titleKey: String {
        "quickAction.\(rawValue)"
    }

    var symbol: String {
        switch self {
        case .lockScreen: return "lock.fill"
        case .emptyTrash: return "trash.fill"
        case .restartFinder: return "arrow.clockwise.circle.fill"
        case .flushDNS: return "network.badge.shield.half.filled"
        case .openSystemSettings: return "gearshape.fill"
        case .screenshot: return "camera.viewfinder"
        }
    }
}

enum QuickActionError: LocalizedError, Equatable {
    case executionFailed(QuickAction, String)
    case openingFailed(QuickAction)

    var errorDescription: String? {
        switch self {
        case let .executionFailed(action, reason):
            return L("quickAction.error", L(action.titleKey), reason)
        case let .openingFailed(action):
            return L("quickAction.openFailed", L(action.titleKey))
        }
    }
}

@MainActor
protocol QuickActionProcessRunning {
    func run(executable: String, arguments: [String]) throws
}

@MainActor
protocol QuickActionScriptRunning {
    func run(source: String) throws
}

@MainActor
protocol QuickActionWorkspaceOpening {
    func open(_ url: URL) -> Bool
}

@MainActor
private final class DefaultQuickActionProcessRunner: QuickActionProcessRunning {
    enum RunnerError: LocalizedError {
        case launchFailed(String)
        case terminated(Int32)

        var errorDescription: String? {
            switch self {
            case let .launchFailed(message): return message
            case let .terminated(status): return "status \(status)"
            }
        }
    }

    func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RunnerError.terminated(process.terminationStatus)
                .withDetail(detail)
        }
    }
}

private extension DefaultQuickActionProcessRunner.RunnerError {
    func withDetail(_ detail: String?) -> Self {
        guard let detail, !detail.isEmpty else { return self }
        switch self {
        case .launchFailed:
            return .launchFailed(detail)
        case let .terminated(status):
            return .launchFailed("status \(status): \(detail)")
        }
    }
}

@MainActor
private final class DefaultQuickActionScriptRunner: QuickActionScriptRunning {
    func run(source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw QuickActionError.executionFailed(.emptyTrash, L("error.scriptInit"))
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? L("error.unknown")
            throw QuickActionError.executionFailed(.emptyTrash, message)
        }
    }
}

@MainActor
private final class DefaultQuickActionWorkspace: QuickActionWorkspaceOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// 快捷操作中心的系统能力边界。
@MainActor
final class QuickActionService {
    private static let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:")!

    private let processRunner: any QuickActionProcessRunning
    private let scriptRunner: any QuickActionScriptRunning
    private let workspace: any QuickActionWorkspaceOpening

    init(
        processRunner: any QuickActionProcessRunning = DefaultQuickActionProcessRunner(),
        scriptRunner: any QuickActionScriptRunning = DefaultQuickActionScriptRunner(),
        workspace: any QuickActionWorkspaceOpening = DefaultQuickActionWorkspace()
    ) {
        self.processRunner = processRunner
        self.scriptRunner = scriptRunner
        self.workspace = workspace
    }

    func perform(_ action: QuickAction) throws {
        switch action {
        case .lockScreen:
            try run(action, executable: Self.cgSessionPath, arguments: ["-suspend"])
        case .emptyTrash:
            do {
                try scriptRunner.run(source: "tell application \"Finder\" to empty trash")
            } catch let error as QuickActionError {
                throw error
            } catch {
                throw QuickActionError.executionFailed(action, error.localizedDescription)
            }
        case .restartFinder:
            try run(action, executable: "/usr/bin/killall", arguments: ["Finder"])
        case .flushDNS:
            try run(action, executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
            try run(action, executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
        case .openSystemSettings:
            guard workspace.open(Self.systemSettingsURL) else {
                throw QuickActionError.openingFailed(action)
            }
        case .screenshot:
            try run(action, executable: "/usr/sbin/screencapture", arguments: ["-x", "-c"])
        }
    }

    private func run(_ action: QuickAction, executable: String, arguments: [String]) throws {
        do {
            try processRunner.run(executable: executable, arguments: arguments)
        } catch {
            throw QuickActionError.executionFailed(action, error.localizedDescription)
        }
    }
}
