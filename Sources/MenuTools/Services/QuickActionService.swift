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
    /// 系统上找不到任何可用锁屏通道（不是执行失败，而是能力缺失）。
    case lockUnsupported

    var errorDescription: String? {
        switch self {
        case let .executionFailed(action, reason):
            return L("quickAction.error", L(action.titleKey), reason)
        case let .openingFailed(action):
            return L("quickAction.openFailed", L(action.titleKey))
        case .lockUnsupported:
            return L("quickAction.lockUnsupported")
        }
    }
}

/// 锁屏通道。macOS 26 起 `User.menu` 里的 `CGSession` 已被移除，必须优先走
/// `login.framework` 的私有入口；老系统才回退到 `CGSession`。
enum ScreenLockChannel: Equatable, Sendable {
    /// 私有 `SACLockScreenImmediate`：不需要任何权限，现代 macOS 可用。
    case loginFramework
    /// 旧版 Menu Extra 的 `CGSession -suspend`：只在老系统上存在。
    case legacyCGSession
}

enum ScreenLockError: LocalizedError, Equatable {
    case channelUnavailable
    case lockFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .channelUnavailable:
            return L("quickAction.lockUnsupported")
        case let .lockFailed(status):
            return L("quickAction.lockFailed", Int(status))
        }
    }
}

/// login.framework 的二进制位于 dyld 共享缓存：**文件路径不存在也能 dlopen 成功**，
/// 所以可用性只能按「符号能否解析」判断。放文件级是为了能在 nonisolated 探测里引用。
private let screenLockLoginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
private let screenLockSymbolName = "SACLockScreenImmediate"

@MainActor
protocol ScreenLockRunning {
    /// 按优先级给出可用通道；一个都没有时返回 nil，由调用方给出可读原因。
    func availableChannel() -> ScreenLockChannel?
    func lock(using channel: ScreenLockChannel) throws
}

@MainActor
final class DefaultScreenLockRunner: ScreenLockRunning {
    static let legacyCGSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    private let legacyPath: String
    private let processRunner: any QuickActionProcessRunning
    private let isExecutableFile: (String) -> Bool
    private let isLoginFrameworkAvailable: () -> Bool

    init(
        legacyCGSessionPath: String = DefaultScreenLockRunner.legacyCGSessionPath,
        processRunner: any QuickActionProcessRunning = DefaultQuickActionProcessRunner(),
        isExecutableFile: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isLoginFrameworkAvailable: @escaping () -> Bool = DefaultScreenLockRunner.probeLoginFramework
    ) {
        self.legacyPath = legacyCGSessionPath
        self.processRunner = processRunner
        self.isExecutableFile = isExecutableFile
        self.isLoginFrameworkAvailable = isLoginFrameworkAvailable
    }

    func availableChannel() -> ScreenLockChannel? {
        if isLoginFrameworkAvailable() { return .loginFramework }
        if isExecutableFile(legacyPath) { return .legacyCGSession }
        return nil
    }

    func lock(using channel: ScreenLockChannel) throws {
        switch channel {
        case .loginFramework:
            guard let handle = dlopen(screenLockLoginFrameworkPath, RTLD_NOW) else {
                throw ScreenLockError.channelUnavailable
            }
            defer { dlclose(handle) }
            guard let symbol = dlsym(handle, screenLockSymbolName) else {
                throw ScreenLockError.channelUnavailable
            }
            let lockScreen = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
            let status = lockScreen()
            guard status == 0 else { throw ScreenLockError.lockFailed(status) }
        case .legacyCGSession:
            guard isExecutableFile(legacyPath) else { throw ScreenLockError.channelUnavailable }
            try processRunner.run(executable: legacyPath, arguments: ["-suspend"])
        }
    }

    /// 只探测符号可解析性，**不调用**，避免探测本身触发锁屏。
    nonisolated static func probeLoginFramework() -> Bool {
        guard let handle = dlopen(screenLockLoginFrameworkPath, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, screenLockSymbolName) != nil
    }
}

enum QuickActionScript {
    static let emptyTrash = """
    tell application "Finder"
        if (count of items of trash) is 0 then return
        try
            empty trash
        on error originalMessage number originalNumber
            if (count of items of trash) is not 0 then error originalMessage number originalNumber
        end try
    end tell
    """
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
    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:")!

    private let processRunner: any QuickActionProcessRunning
    private let scriptRunner: any QuickActionScriptRunning
    private let workspace: any QuickActionWorkspaceOpening
    private let screenLocker: any ScreenLockRunning

    init(
        processRunner: any QuickActionProcessRunning = DefaultQuickActionProcessRunner(),
        scriptRunner: any QuickActionScriptRunning = DefaultQuickActionScriptRunner(),
        workspace: any QuickActionWorkspaceOpening = DefaultQuickActionWorkspace(),
        screenLocker: (any ScreenLockRunning)? = nil
    ) {
        self.processRunner = processRunner
        self.scriptRunner = scriptRunner
        self.workspace = workspace
        // 旧版 CGSession 通道要走同一个进程执行器，便于测试与统一错误包装。
        self.screenLocker = screenLocker ?? DefaultScreenLockRunner(processRunner: processRunner)
    }

    func perform(_ action: QuickAction) throws {
        switch action {
        case .lockScreen:
            guard let channel = screenLocker.availableChannel() else {
                throw QuickActionError.lockUnsupported
            }
            do {
                try screenLocker.lock(using: channel)
            } catch let error as QuickActionError {
                throw error
            } catch {
                throw QuickActionError.executionFailed(action, error.localizedDescription)
            }
        case .emptyTrash:
            do {
                try scriptRunner.run(source: QuickActionScript.emptyTrash)
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
