import AppKit
import Foundation

/// 接收 Finder 扩展转交的操作指令并在主 App 进程执行。
/// 扩展是沙箱进程，新建文件/文件夹与"在终端打开"必须由非沙箱的主 App 代为完成。
@MainActor
enum RightClickCommandHandler {

    static func activate() {
        let center = DistributedNotificationCenter.default()
        // 指令随通知 object 以 JSON 字符串送达，不落盘（避免跨容器文件访问触发 TCC 弹窗）
        center.addObserver(
            forName: Notification.Name(RightClickCommandStore.commandNotification),
            object: nil, queue: .main
        ) { note in
            let json = note.object as? String
            MainActor.assumeIsolated {
                guard let command = RightClickCommandStore.decode(json) else { return }
                handle(command)
            }
        }
        // 扩展冷启动时请求配置 → 广播当前配置
        center.addObserver(
            forName: Notification.Name(RightClickConfigStore.requestNotification),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RightClickConfigStore.broadcast(RightClickConfigStore.load())
            }
        }
        // 主 App 启动时也广播一次，让已在跑的扩展同步
        RightClickConfigStore.broadcast(RightClickConfigStore.load())
    }

    private static func handle(_ command: RightClickCommand) {
        guard let item = RightClickItem(rawValue: command.action) else { return }

        switch item {
        case .newFolder:
            if let base = command.paths.first {
                let url = uniqueURL(in: URL(fileURLWithPath: base),
                                    name: L("rc.default.newFolder"))
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
        case .newFile:
            if let base = command.paths.first {
                // 本地化缺省名只取主名，扩展名由菜单选择决定（txt/md/json）
                let stem = (L("rc.default.newFile") as NSString).deletingPathExtension
                let ext = command.fileExtension ?? "txt"
                let url = uniqueURL(in: URL(fileURLWithPath: base),
                                    name: "\(stem).\(ext)")
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        case .openInTerminal:
            if let path = command.paths.first {
                let terminal = TerminalApp(
                    rawValue: UserDefaults.standard.string(forKey: SettingsKey.preferredTerminal) ?? ""
                ) ?? .systemDefault
                try? TerminalLauncher.open(directory: URL(fileURLWithPath: path), in: terminal)
            }
        default:
            break // 复制类操作在扩展内直接完成，不会转交
        }
    }

    /// 在目录下生成不重名的路径（重名追加序号）
    private static func uniqueURL(in directory: URL, name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            index += 1
        }
        return candidate
    }
}
