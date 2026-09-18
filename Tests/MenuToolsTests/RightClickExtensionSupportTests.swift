import Foundation
import Testing
@testable import MenuTools

// MARK: - 菜单 tag 快照

@Test("命令注册表为每个菜单项分配唯一 tag 并可按 tag 取回")
func rightClickCommandRegistryAssignsTags() {
    var registry = RightClickCommandRegistry()
    let first = RightClickCommand(action: "checksum", paths: ["/tmp/a"])
    let second = RightClickCommand(action: "newFolder", paths: ["/tmp"])
    let firstTag = registry.register(first)
    let secondTag = registry.register(second)

    #expect(firstTag != secondTag)
    #expect(registry.command(forTag: firstTag) == first)
    #expect(registry.command(forTag: secondTag) == second)
    #expect(registry.command(forTag: secondTag + 1) == nil)
    #expect(registry.count == 2)
}

@Test("命令注册表裁剪后旧菜单 tag 不会映射到新动作")
func rightClickCommandRegistryPrunesOldTags() {
    var registry = RightClickCommandRegistry()
    var tags: [Int] = []
    for index in 0..<10 {
        tags.append(registry.register(.init(action: "checksum", paths: ["/tmp/\(index)"])))
    }

    registry.prune(keeping: 3)

    #expect(registry.count == 3)
    #expect(registry.command(forTag: tags[9])?.paths == ["/tmp/9"])
    #expect(registry.command(forTag: tags[0]) == nil)
    // 裁剪不改变后续 tag 分配，旧菜单的 tag 仍然取不到新动作。
    let fresh = registry.register(.init(action: "newFolder", paths: ["/tmp"]))
    #expect(fresh > tags[9])
    #expect(registry.command(forTag: tags[6]) == nil)
}

// MARK: - 命令派发

@Test("命令派发未确认时唤醒宿主、重投并在超时后报告不可用")
func rightClickCommandDispatcherRetriesAndTimesOut() {
    var sent: [RightClickCommand] = []
    var wakeCompletions: [(Bool) -> Void] = []
    let scheduler = RightClickTestScheduler()
    let dispatcher = RightClickCommandDispatcher(
        send: { sent.append($0) },
        wake: { completion in wakeCompletions.append(completion) },
        schedule: { delay, work in scheduler.schedule(delay, work) })
    var unavailable: [String] = []
    dispatcher.onUnavailable = { unavailable.append($0) }

    dispatcher.dispatch(.init(action: "checksum", paths: ["/tmp/a"]), requestID: "r1")
    #expect(sent.count == 1)
    #expect(sent[0].requestID == "r1")
    #expect(scheduler.delays == [1])

    #expect(scheduler.runNext())
    #expect(wakeCompletions.count == 1)
    #expect(unavailable.isEmpty)

    wakeCompletions[0](true)
    #expect(scheduler.delays == [0.5])

    #expect(scheduler.runNext())
    #expect(sent.count == 2)
    #expect(sent[1].requestID == "r1")
    #expect(scheduler.delays == [3])

    #expect(scheduler.runNext())
    #expect(unavailable == ["r1"])
    #expect(dispatcher.pending.isEmpty)
    #expect(!scheduler.runNext())
}

@Test("宿主已确认的命令不会再次唤醒或重投")
func rightClickCommandDispatcherSkipsAcknowledgedCommands() {
    var sent: [RightClickCommand] = []
    var didWake = false
    let scheduler = RightClickTestScheduler()
    let dispatcher = RightClickCommandDispatcher(
        send: { sent.append($0) },
        wake: { _ in didWake = true },
        schedule: { delay, work in scheduler.schedule(delay, work) })

    dispatcher.dispatch(.init(action: "checksum", paths: ["/tmp/a"]), requestID: "r2")
    dispatcher.acknowledged(requestID: "r2")

    #expect(dispatcher.pending.isEmpty)
    #expect(scheduler.runNext())
    #expect(!didWake)
    #expect(sent.count == 1)
}

@Test("宿主唤醒失败时立即报告不可用且不再等待")
func rightClickCommandDispatcherReportsFailedWake() {
    var wakeCompletions: [(Bool) -> Void] = []
    let scheduler = RightClickTestScheduler()
    let dispatcher = RightClickCommandDispatcher(
        send: { _ in },
        wake: { completion in wakeCompletions.append(completion) },
        schedule: { delay, work in scheduler.schedule(delay, work) })
    var unavailable: [String] = []
    dispatcher.onUnavailable = { unavailable.append($0) }

    dispatcher.dispatch(.init(action: "checksum", paths: ["/tmp/a"]), requestID: "r3")
    #expect(scheduler.runNext())
    wakeCompletions[0](false)

    #expect(unavailable == ["r3"])
    #expect(scheduler.pendingCount == 0)
}

@Test("配置广播到达时重投所有未确认命令")
func rightClickCommandDispatcherResendsPendingCommands() {
    var sent: [RightClickCommand] = []
    let scheduler = RightClickTestScheduler()
    let dispatcher = RightClickCommandDispatcher(
        send: { sent.append($0) },
        wake: { _ in },
        schedule: { delay, work in scheduler.schedule(delay, work) })

    dispatcher.dispatch(.init(action: "checksum", paths: ["/tmp/a"]), requestID: "a")
    dispatcher.dispatch(.init(action: "newFolder", paths: ["/tmp"]), requestID: "b")
    sent.removeAll()

    dispatcher.resendPending()

    #expect(sent.compactMap(\.requestID).sorted() == ["a", "b"])
}

// MARK: - 菜单构建

@Test("菜单构建把模板、应用、目录和剪贴板格式生成为带选项的子菜单")
func rightClickMenuBuilderBuildsConfiguredSubmenus() {
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [], clipboard: .text)
    let resources = RightClickMenuResources(
        terminals: [.init(title: .key("rc.terminal.default"), optionID: "default")],
        clipboardFormats: [.init(title: .literal("TXT"), optionID: "txt"),
                           .init(title: .literal("Markdown"), optionID: "md")])

    let nodes = RightClickMenuBuilder.nodes(
        config: rightClickBuilderConfig(), context: context, resources: resources)

    #expect(nodes.count == 1)
    guard case .submenu(let root) = nodes[0] else {
        Issue.record("默认样式应生成单一根子菜单")
        return
    }
    #expect(root.title == .key("rc.menu.root"))

    let newFile = submenu(in: root.children, titled: .key(RightClickItem.newFile.titleKey))
    #expect(newFile?.symbolName == RightClickItem.newFile.symbolName)
    #expect(newFile?.children.map(\.titleSnapshot) == [.literal("TXT")])
    #expect(newFile?.children.first?.commandSnapshot?.action == "newFile")
    #expect(newFile?.children.first?.commandSnapshot?.optionID == "txt")
    // 创建类动作作用在目标目录上，而不是选中项。
    #expect(newFile?.children.first?.commandSnapshot?.paths == ["/tmp"])

    let terminal = submenu(in: root.children, titled: .key(RightClickItem.openInTerminal.titleKey))
    #expect(terminal?.children.first?.commandSnapshot?.optionID == "default")

    let clipboard = submenu(in: root.children, titled: .key(RightClickItem.saveClipboard.titleKey))
    #expect(clipboard?.children.map(\.titleSnapshot) == [.literal("TXT"), .literal("Markdown")])

    let copy = submenu(in: root.children, titled: .key("rc.menu.copy"))
    #expect(copy?.children.contains { $0.commandSnapshot?.action == RightClickItem.copyAbsolutePath.rawValue } == true)
    #expect(copy?.children.first { $0.commandSnapshot?.action == RightClickItem.copyAbsolutePath.rawValue }?.symbolSnapshot
            == RightClickItem.copyAbsolutePath.symbolName)
}

@Test("菜单构建按应用筛选生成打开方式子菜单")
func rightClickMenuBuilderFiltersApplications() {
    let file = RightClickMenuContext(
        directoryPath: "/tmp", selection: [.init(path: "/tmp/a.txt", isDirectory: false)], clipboard: .none)
    let nodes = RightClickMenuBuilder.nodes(
        config: rightClickBuilderConfig(), context: file, resources: RightClickMenuResources())

    guard case .submenu(let root) = nodes.first else {
        Issue.record("默认样式应生成单一根子菜单")
        return
    }
    let openWith = submenu(in: root.children, titled: .key(RightClickItem.openWithApp.titleKey))
    #expect(openWith?.children.map(\.titleSnapshot) == [.literal("编辑器")])
    #expect(openWith?.children.first?.commandSnapshot?.paths == ["/tmp/a.txt"])
}

@Test("分组样式生成目录、复制和文件三组，扁平样式直接平铺")
func rightClickMenuBuilderSupportsMenuStyles() {
    var config = rightClickBuilderConfig()
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [], clipboard: .none)
    let resources = RightClickMenuResources(
        terminals: [.init(title: .key("rc.terminal.default"), optionID: "default")])

    config.menuStyle = .grouped
    let grouped = RightClickMenuBuilder.nodes(config: config, context: context, resources: resources)
    guard case .submenu(let root) = grouped.first else {
        Issue.record("分组样式应生成根子菜单")
        return
    }
    #expect(root.children.compactMap(\.submenuSnapshot?.title)
            == [.key("rc.group.directory"), .key("rc.group.copy"), .key("rc.group.file")])

    config.menuStyle = .flat
    let flat = RightClickMenuBuilder.nodes(config: config, context: context, resources: resources)
    #expect(flat.contains { $0.commandSnapshot?.action == RightClickItem.newFolder.rawValue })
    #expect(flat.contains { $0.submenuSnapshot?.title == .key("rc.menu.copy") })
    #expect(!flat.contains { $0.submenuSnapshot?.title == .key("rc.menu.root") })
}

@Test("右键配置缺省菜单样式并拒绝未知取值")
func rightClickMenuStyleMigrates() throws {
    let legacy = try JSONDecoder().decode(
        RightClickConfig.self, from: Data(#"{"enabled":{}}"#.utf8))
    #expect(legacy.menuStyle == .nested)
    var config = RightClickConfig.default
    config.menuStyle = .flat
    let encoded = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(RightClickConfig.self, from: encoded).menuStyle == .flat)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(RightClickConfig.self, from: Data(#"{"enabled":{},"menuStyle":"invalid"}"#.utf8))
    }
}

// MARK: - 测试辅助

private func rightClickBuilderConfig() -> RightClickConfig {
    RightClickConfig(
        enabled: [:],
        templates: [.init(id: "txt", name: "TXT", filename: "Untitled.txt", content: "")],
        applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app",
                             bundleIdentifier: "org.example.Editor")],
        destinations: [.init(id: "dest", name: "归档", path: "/tmp/archive")])
}

private func submenu(in nodes: [RightClickMenuNode], titled title: RightClickMenuTitle) -> RightClickMenuSubmenu? {
    for node in nodes {
        if case .submenu(let value) = node, value.title == title { return value }
    }
    return nil
}

private final class RightClickTestScheduler {
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    var pendingCount: Int { scheduled.count }
    var delays: [TimeInterval] { scheduled.map(\.delay) }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        scheduled.append((delay, work))
    }

    @discardableResult
    func runNext() -> Bool {
        guard !scheduled.isEmpty else { return false }
        scheduled.removeFirst().work()
        return true
    }
}

private extension RightClickMenuNode {
    var titleSnapshot: RightClickMenuTitle? {
        if case .action(let action) = self { return action.title }
        return submenuSnapshot?.title
    }

    var symbolSnapshot: String? {
        if case .action(let action) = self { return action.symbolName }
        return submenuSnapshot?.symbolName
    }

    var commandSnapshot: RightClickCommand? {
        if case .action(let action) = self { return action.command }
        return nil
    }

    var submenuSnapshot: RightClickMenuSubmenu? {
        if case .submenu(let submenu) = self { return submenu }
        return nil
    }
}
