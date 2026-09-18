import AppKit
import Foundation

/// 接收 Finder 操作；主进程负责交互、实际文件权限及后台任务。
@MainActor
enum RightClickCommandHandler {
    private static var observerTokens: [NSObjectProtocol] = []
    private static var handledRequests: [String] = []
    private static var queue = RightClickCommandQueue()
    private static var isRunning = false
    static var isActive: Bool { !observerTokens.isEmpty }

    static func activate() {
        guard observerTokens.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observerTokens.append(center.addObserver(
            forName: Notification.Name(RightClickCommandStore.commandNotification), object: nil, queue: .main
        ) { note in
            let json = note.object as? String
            MainActor.assumeIsolated {
                guard let command = RightClickCommandStore.decode(json) else { return }
                receive(command)
            }
        })
        observerTokens.append(center.addObserver(
            forName: Notification.Name(RightClickConfigStore.requestNotification), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RightClickConfigStore.broadcast(RightClickConfigStore.load()) }
        })
        RightClickConfigStore.broadcast(RightClickConfigStore.load())
    }

    static func deactivate() {
        observerTokens.forEach(DistributedNotificationCenter.default().removeObserver)
        observerTokens.removeAll()
        queue.removeAll()
        RightClickConfigStore.broadcast(.disabled)
    }

    private static func receive(_ command: RightClickCommand) {
        if let id = command.requestID {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(RightClickCommandStore.acceptedNotification), object: id, deliverImmediately: true)
            guard !handledRequests.contains(id) else { return }
            handledRequests.append(id)
            if handledRequests.count > 256 { handledRequests.removeFirst() }
        }
        switch queue.enqueue(command) {
        case .duplicate:
            // 定时重试与配置广播重投可能同时到达，只执行一次。
            return
        case .full:
            showMessage(L("rc.operation.busy"), title: L("rc.title"))
        case .accepted:
            startNextIfIdle()
        }
    }

    /// 串行执行：长任务执行期间到达的命令排队等待，而不是被拒绝。
    private static func startNextIfIdle() {
        guard !isRunning, let command = queue.dequeue() else { return }
        isRunning = true
        Task {
            defer {
                isRunning = false
                startNextIfIdle()
            }
            do {
                let config = RightClickConfigStore.load()
                let item = try RightClickCommandPolicy.validate(command, config: config)
                try await execute(item, command: command, config: config)
            } catch is CancellationError {
                showMessage(L("rc.operation.cancelled"), title: L("rc.title"))
            } catch {
                showMessage(error.localizedDescription, title: L("rc.error.title"), error: true)
            }
        }
    }

    private static func execute(_ item: RightClickItem, command: RightClickCommand, config: RightClickConfig) async throws {
        let urls = command.paths.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { throw RightClickCommandError.invalidCommand }
        switch item {
        case .newFolder:
            guard let name = promptName(title: L(item.titleKey), directory: first, initial: L("rc.default.newFolder")) else { return }
            let created = try await Task.detached {
                try RightClickFileService.createFolder(in: first, name: name)
            }.value
            try RightClickUndoStore.save(.init(kind: .create, entries: [try undoEntry(source: nil, destination: created)]))
            reveal([created])
        case .newFile:
            let id = command.optionID ?? command.fileExtension
            guard let template = config.templates.first(where: { $0.id == id }) else { throw RightClickCommandError.missingOption }
            let now = Date()
            let projectName = RightClickFileService.gitRoot(containing: first)?.lastPathComponent
            var promptValues: [String: String] = [:]
            for promptName in RightClickTemplateRenderer.promptNames(in: [template.filename, template.content]) {
                guard let value = promptText(
                    title: L("rc.template.prompt.title", promptName),
                    message: L("rc.template.prompt.message"), initial: "", placeholder: promptName) else { return }
                guard value.utf8.count <= 4_096 else { throw RightClickCommandError.invalidCommand }
                promptValues[promptName] = value
            }
            let clipboard: String
            if case .text(let text) = RightClickClipboardReader.read() {
                clipboard = String(text.prefix(32_768))
            } else {
                clipboard = ""
            }
            let renderContext = RightClickTemplateRenderer.Context(
                directory: first, date: now, timeZone: .current, projectName: projectName,
                uuid: UUID().uuidString.lowercased(), clipboard: clipboard, prompts: promptValues)
            var initial = RightClickTemplateRenderer.render(template.filename, context: renderContext)
            if let original = RightClickTemplate.builtIns.first(where: { $0.id == id }),
               original.filename == template.filename, initial.hasPrefix("Untitled.") {
                initial = (L("rc.default.newFile") as NSString).deletingPathExtension + "." + (initial as NSString).pathExtension
            }
            guard let name = promptName(title: L(item.titleKey), directory: first, initial: initial) else { return }
            let content = RightClickTemplateRenderer.render(template.content, context: renderContext)
            let created = try await Task.detached {
                try RightClickFileService.createFile(in: first, name: name, data: Data(content.utf8))
            }.value
            try RightClickUndoStore.save(.init(kind: .create, entries: [try undoEntry(source: nil, destination: created)]))
            reveal([created])
        case .saveClipboard:
            guard let format = RightClickClipboardFormat(rawValue: command.optionID ?? ""),
                  let payload = RightClickClipboardReader.payload(),
                  let data = payload.data(for: format) else {
                throw RightClickCommandError.clipboardUnavailable
            }
            let ext = format.fileExtension
            guard let name = promptName(title: L(item.titleKey), directory: first, initial: L("rc.clipboard.filename") + "." + ext) else { return }
            let created = try await Task.detached {
                try RightClickFileService.createFile(in: first, name: name, data: data)
            }.value
            try RightClickUndoStore.save(.init(kind: .create, entries: [try undoEntry(source: nil, destination: created)]))
            reveal([created])
        case .openInTerminal:
            guard let terminal = TerminalApp.resolve(optionID: command.optionID,
                preferredID: UserDefaults.standard.string(forKey: SettingsKey.preferredTerminal), fallback: .systemDefault) else {
                throw RightClickCommandError.invalidCommand
            }
            guard let appURL = terminal.appURL else { throw TerminalLauncher.LaunchError.appNotFound(terminal) }
            try await open(urls, application: appURL)
        case .openWithApp:
            guard let application = config.applications.first(where: { $0.id == command.optionID }) else { throw RightClickCommandError.missingOption }
            var appURL = URL(fileURLWithPath: application.path)
            if !FileManager.default.fileExists(atPath: appURL.path),
               let relocated = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier) { appURL = relocated }
            guard Bundle(url: appURL)?.bundleIdentifier == application.bundleIdentifier else { throw RightClickCommandError.applicationUnavailable }
            try await open(urls, application: appURL)
        case .copyToFolder, .moveToFolder:
            guard let destination = config.destinations.first(where: { $0.id == command.optionID }) else { throw RightClickCommandError.missingOption }
            let target = URL(fileURLWithPath: destination.path)
            let conflicts = try await Task.detached {
                try RightClickFileService.hasConflicts(sources: urls, destination: target)
            }.value
            var policy = RightClickConflictPolicy.keepBoth
            if conflicts {
                let alert = makeAlert(title: L("rc.conflict.title"), message: L("rc.conflict.message"))
                alert.addButton(withTitle: L("rc.conflict.keepBoth"))
                alert.addButton(withTitle: L("rc.conflict.skip"))
                alert.addButton(withTitle: L("rc.button.cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: policy = .keepBoth
                case .alertSecondButtonReturn: policy = .skip
                default: return
                }
            }
            let progress = RightClickProgressController(title: L(item.titleKey), determinate: true)
            defer { progress.close() }
            let chosenPolicy = policy
            let operationProgress = progress.progress
            let result = try await Task.detached {
                try RightClickFileService.transfer(sources: urls, destination: target,
                    move: item == .moveToFolder, conflict: chosenPolicy, progress: { value in
                        operationProgress.totalUnitCount = max(value.totalBytes, 1)
                        operationProgress.completedUnitCount = value.completedBytes
                    }, isCancelled: { operationProgress.isCancelled })
            }.value
            progress.close()
            if !result.completed.isEmpty {
                let entries = try result.completions.map { completion in
                    try undoEntry(source: completion.source.path, destination: completion.destination)
                }
                try RightClickUndoStore.save(.init(kind: item == .moveToFolder ? .move : .copy, entries: entries))
            }
            var message = L("rc.transfer.result", result.completed.count, result.skipped.count, result.failures.count)
            if !result.failures.isEmpty {
                message += "\n\n" + result.failures.prefix(10).map { "\(($0.path as NSString).lastPathComponent)：\($0.message)" }.joined(separator: "\n")
            }
            showMessage(message, title: L(item.titleKey), error: !result.failures.isEmpty)
            if !result.completed.isEmpty { reveal(result.completed) }
        case .checksum, .verifyChecksum:
            var expected: String?
            if item == .verifyChecksum {
                guard let input = promptText(title: L(item.titleKey), message: first.lastPathComponent,
                                             initial: "", placeholder: L("rc.checksum.placeholder")) else { return }
                expected = try RightClickFileService.normalizedSHA256(input)
            }
            let progress = RightClickProgressController(title: L("rc.checksum.calculating"), determinate: false)
            defer { progress.close() }
            let hashes = try await Task.detached {
                try urls.map { try RightClickFileService.sha256($0) }
            }.value
            progress.close()
            if let expected, let hash = hashes.first {
                let matches = hash == expected
                showMessage(first.lastPathComponent + "\n\n" + hash,
                            title: L(matches ? "rc.checksum.match" : "rc.checksum.mismatch"), error: !matches)
            } else {
                let output = hashes.count == 1 ? hashes[0] : zip(hashes, urls).map { "\($0)  \($1.lastPathComponent)" }.joined(separator: "\n")
                copy(output)
                showMessage(output, title: L("rc.checksum.copied"))
            }
        case .copyFileContents:
            let content = try await Task.detached { try RightClickContentService.readFile(at: first) }.value
            switch content {
            case .text(let text): copy(text)
            case .image(let png):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
            }
        case .copyDirectoryListing:
            guard let style = RightClickDirectoryListingStyle(rawValue: command.optionID ?? "") else {
                throw RightClickCommandError.invalidCommand
            }
            let listing = try await Task.detached {
                try RightClickContentService.directoryListing(
                    at: first, style: style, options: config.directoryListing)
            }.value
            copy(listing)
        case .copyFileInfo:
            guard let format = RightClickFileInfoFormat(rawValue: command.optionID ?? "") else {
                throw RightClickCommandError.invalidCommand
            }
            let information = try await RightClickFileInfoService.collect(urls)
            copy(RightClickFileInfoFormatter.format(information, as: format))
        case .batchRename:
            guard let rule = batchRenameRule(optionID: command.optionID) else { return }
            let plans = try await Task.detached {
                try RightClickBatchRenameService.plan(urls, rule: rule)
            }.value
            let preview = plans.prefix(20).map {
                "\($0.source.lastPathComponent) → \($0.destination.lastPathComponent)"
            }.joined(separator: "\n")
            let remaining = max(0, plans.count - 20)
            let message = remaining == 0 ? preview : preview + "\n" + L("rc.rename.preview.more", remaining)
            let alert = makeAlert(title: L(item.titleKey), message: message)
            alert.addButton(withTitle: L("rc.rename.apply"))
            alert.addButton(withTitle: L("rc.button.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let completions = try await Task.detached {
                try RightClickBatchRenameService.apply(plans)
            }.value
            let entries = try completions.map { completion in
                try undoEntry(source: completion.source.path, destination: completion.destination)
            }
            try RightClickUndoStore.save(.init(kind: .rename, entries: entries))
            reveal(completions.map(\.destination))
            showMessage(L("rc.rename.result", completions.count), title: L(item.titleKey))
        case .undoLastOperation:
            guard let record = RightClickUndoStore.load() else {
                showMessage(L("rc.undo.none"), title: L(item.titleKey))
                return
            }
            var message = L("rc.undo.confirm", record.entries.count)
            let queued = RightClickUndoStore.count() - 1
            if queued > 0 { message += "\n" + L("rc.undo.queued", queued) }
            let alert = makeAlert(title: L(item.titleKey), message: message)
            alert.addButton(withTitle: L("rc.item.undoLastOperation"))
            alert.addButton(withTitle: L("rc.button.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let result = await Task.detached { RightClickFileService.undo(record) }.value
            // 撤销失败时保留记录，用户可修复冲突后重试。
            if result.failures.isEmpty { try? RightClickUndoStore.removeLast() }
            var resultMessage = L("rc.undo.result", result.completed.count, result.failures.count)
            let remaining = RightClickUndoStore.count()
            if remaining > 0 { resultMessage += "\n" + L("rc.undo.remaining", remaining) }
            showMessage(resultMessage, title: L(item.titleKey), error: !result.failures.isEmpty)
        case .copyGitRelativePath:
            let paths = try await Task.detached {
                try urls.map(RightClickFileService.gitRelativePath)
            }.value
            copy(paths.joined(separator: "\n"))
        case .copyFilename: copy(urls.map(\.lastPathComponent).joined(separator: "\n"))
        case .copyFilenameWithoutExtension: copy(command.paths.map { RightClickPathFormatter.filenameWithoutExtension(path: $0) }.joined(separator: "\n"))
        case .copyAbsolutePath: copy(command.paths.joined(separator: "\n"))
        case .copyRelativePath:
            copy(command.paths.map { RightClickPathFormatter.homeRelativePath(path: $0, home: FileManager.default.homeDirectoryForCurrentUser.path) }.joined(separator: "\n"))
        case .copyCurrentRelativePath:
            guard let base = command.directoryPath else { throw RightClickCommandError.invalidCommand }
            copy(command.paths.map { RightClickPathFormatter.relativePath(path: $0, base: base) }.joined(separator: "\n"))
        case .copyEscapedPath: copy(command.paths.map(RightClickPathFormatter.shellEscaped).joined(separator: "\n"))
        case .copyFileURL: copy(urls.map(\.absoluteString).joined(separator: "\n"))
        case .copyMarkdownLink: copy(command.paths.map { RightClickPathFormatter.markdownLink(path: $0) }.joined(separator: "\n"))
        }
    }

    private static func open(_ urls: [URL], application: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func undoEntry(source: String?, destination: URL) throws -> RightClickUndoRecord.Entry {
        guard let identity = RightClickFileService.itemIdentity(destination) else {
            throw RightClickFileError.undoTargetChanged
        }
        return .init(source: source, destination: destination.path, destinationIdentity: identity)
    }

    private static func batchRenameRule(optionID: String?) -> RightClickBatchRenameRule? {
        switch optionID {
        case "regex":
            guard let pattern = promptText(
                title: L("rc.rename.regex.pattern"), message: L("rc.rename.regex.hint"),
                initial: "", placeholder: L("rc.rename.regex.pattern")) else { return nil }
            guard let replacement = promptText(
                title: L("rc.rename.regex.replacement"), message: L("rc.rename.regex.hint"),
                initial: "", placeholder: L("rc.rename.regex.replacement")) else { return nil }
            return .regex(pattern: pattern, replacement: replacement)
        case "sequence":
            guard let value = promptText(
                title: L("rc.rename.sequence.start"), message: L("rc.rename.sequence.hint"),
                initial: "1", placeholder: "1"), let start = Int(value), start >= 0 else { return nil }
            return .sequence(start: start)
        case "date":
            return .datePrefix(Date(), .current)
        case "extension":
            guard let value = promptText(
                title: L("rc.rename.extension.value"), message: L("rc.rename.extension.hint"),
                initial: "", placeholder: "md") else { return nil }
            return .extension(value)
        default:
            return nil
        }
    }

    private static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    private static func promptName(title: String, directory: URL, initial: String) -> String? {
        var value = initial
        while let input = promptText(title: title, message: directory.path, initial: value, placeholder: L("rc.settings.templateFilename")) {
            do { try RightClickFileService.validateName(input); return input }
            catch { showMessage(error.localizedDescription, title: L("rc.error.title"), error: true); value = input }
        }
        return nil
    }

    private static func promptText(title: String, message: String, initial: String, placeholder: String) -> String? {
        let alert = makeAlert(title: title, message: message)
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("rc.button.ok"))
        alert.addButton(withTitle: L("rc.button.cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private static func makeAlert(title: String, message: String) -> NSAlert {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        return alert
    }

    private static func showMessage(_ message: String, title: String, error: Bool = false) {
        let alert = makeAlert(title: title, message: message)
        alert.alertStyle = error ? .warning : .informational
        alert.addButton(withTitle: L("rc.button.ok"))
        alert.runModal()
    }

}

@MainActor
private final class RightClickProgressController: NSObject {
    let progress = Progress(totalUnitCount: 1)
    private let panel: NSPanel

    init(title: String, determinate: Bool) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 118),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 62, width: 340, height: 14))
        indicator.style = .bar
        indicator.isIndeterminate = !determinate
        if determinate { indicator.observedProgress = progress } else { indicator.startAnimation(nil) }
        let label = NSTextField(labelWithString: L("rc.operation.working"))
        label.frame = NSRect(x: 20, y: 84, width: 340, height: 20)
        panel.contentView?.addSubview(indicator)
        panel.contentView?.addSubview(label)
        if determinate {
            let cancel = NSButton(title: L("rc.button.cancel"), target: self, action: #selector(cancelOperation))
            cancel.frame = NSRect(x: 270, y: 16, width: 90, height: 30)
            panel.contentView?.addSubview(cancel)
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelOperation() { progress.cancel() }
    func close() { panel.close() }
}
