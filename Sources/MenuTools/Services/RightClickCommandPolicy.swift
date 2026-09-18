import AppKit
import Foundation

enum RightClickCommandError: LocalizedError {
    case invalidCommand, disabled, missingOption, clipboardUnavailable, applicationUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidCommand: return L("rc.error.invalidCommand")
        case .disabled: return L("rc.error.disabled")
        case .missingOption: return L("rc.error.missingOption")
        case .clipboardUnavailable: return L("rc.error.clipboardUnavailable")
        case .applicationUnavailable: return L("rc.error.applicationUnavailable")
        }
    }
}

/// 主进程重新验证动作和配置引用，不信任扩展传入的任意应用或目标路径。
enum RightClickCommandPolicy {
    static func validate(_ command: RightClickCommand, config: RightClickConfig) throws -> RightClickItem {
        guard let item = RightClickItem(rawValue: command.action),
              !command.paths.isEmpty, command.paths.count <= 1000,
              command.paths.allSatisfy(validPath),
              command.directoryPath.map(validPath) ?? true else { throw RightClickCommandError.invalidCommand }
        guard config.isEnabled(item) else { throw RightClickCommandError.disabled }
        switch item {
        case .newFolder, .saveClipboard, .verifyChecksum, .copyFileContents, .copyDirectoryListing:
            guard command.paths.count == 1 else { throw RightClickCommandError.invalidCommand }
        case .openInTerminal:
            guard command.paths.count == 1,
                  TerminalApp.resolve(optionID: command.optionID, preferredID: nil, fallback: .terminal) != nil else {
                throw RightClickCommandError.invalidCommand
            }
        case .newFile:
            guard command.paths.count == 1 else { throw RightClickCommandError.invalidCommand }
            if let id = command.optionID {
                guard config.templates.contains(where: { $0.id == id }) else { throw RightClickCommandError.missingOption }
            } else {
                guard let ext = command.fileExtension,
                      RightClickTemplate.builtIns.contains(where: { $0.id == ext }) else {
                    throw RightClickCommandError.missingOption
                }
            }
        case .openWithApp:
            guard config.applications.contains(where: { $0.id == command.optionID }) else { throw RightClickCommandError.missingOption }
        case .copyToFolder, .moveToFolder:
            guard config.destinations.contains(where: { $0.id == command.optionID }) else { throw RightClickCommandError.missingOption }
        case .batchRename:
            guard ["regex", "sequence", "date", "extension"].contains(command.optionID ?? "") else {
                throw RightClickCommandError.invalidCommand
            }
        case .copyFileInfo:
            guard ["text", "markdown", "json"].contains(command.optionID ?? "") else {
                throw RightClickCommandError.invalidCommand
            }
        case .copyCurrentRelativePath:
            guard command.directoryPath != nil else { throw RightClickCommandError.invalidCommand }
        default: break
        }
        if item == .saveClipboard {
            guard RightClickClipboardFormat(rawValue: command.optionID ?? "") != nil else {
                throw RightClickCommandError.invalidCommand
            }
        }
        if item == .copyDirectoryListing, !["list", "tree", "markdown", "json"].contains(command.optionID ?? "") {
            throw RightClickCommandError.invalidCommand
        }
        return item
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0")
            && !path.split(separator: "/").contains("..")
    }
}
