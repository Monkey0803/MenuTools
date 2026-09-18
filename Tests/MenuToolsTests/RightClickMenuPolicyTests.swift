import Foundation
import Testing
@testable import MenuTools

private var configuredRightClickMenu: RightClickConfig {
    RightClickConfig(enabled: [:], applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "")], destinations: [.init(id: "archive", name: "归档", path: "/tmp/archive")])
}

@Test("空白目录菜单仅提供适用功能")
func rightClickBlankDirectoryMenu() {
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [], clipboard: .none)
    let visible = RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context)
    #expect(visible.contains(.newFile))
    #expect(visible.contains(.newFolder))
    #expect(visible.contains(.openWithApp))
    #expect(visible.contains(.openInTerminal))
    #expect(visible.contains(.copyAbsolutePath))
    for item: RightClickItem in [.saveClipboard, .copyToFolder, .moveToFolder, .checksum, .verifyChecksum, .copyCurrentRelativePath, .copyGitRelativePath] {
        #expect(!visible.contains(item))
    }
    #expect(RightClickMenuPolicy.targetDirectory(context: context) == "/tmp")
    #expect(RightClickMenuPolicy.affectedPaths(context: context) == ["/tmp"])
}

@Test("没有目录和选择时隐藏操作菜单")
func rightClickMissingContextMenu() {
    let context = RightClickMenuContext(directoryPath: nil, selection: [], clipboard: .text)
    #expect(RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context).isEmpty)
    #expect(RightClickMenuPolicy.targetDirectory(context: context) == nil)
    #expect(RightClickMenuPolicy.affectedPaths(context: context).isEmpty)
}

@Test("单选文件菜单支持校验和与文件移动")
func rightClickSingleFileMenu() {
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/a.txt", isDirectory: false)], clipboard: .text)
    let visible = RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context)
    for item: RightClickItem in [.openInTerminal, .openWithApp, .copyToFolder, .moveToFolder, .checksum, .verifyChecksum, .copyCurrentRelativePath, .copyGitRelativePath] {
        #expect(visible.contains(item))
    }
    for item: RightClickItem in [.newFile, .newFolder, .saveClipboard] { #expect(!visible.contains(item)) }
    #expect(RightClickMenuPolicy.targetDirectory(context: context) == "/tmp")
}

@Test("单选文件夹在该目录提供创建操作")
func rightClickSingleFolderMenu() {
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/folder", isDirectory: true)], clipboard: .image)
    let visible = RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context)
    #expect(visible.contains(.newFolder))
    #expect(visible.contains(.saveClipboard))
    #expect(!visible.contains(.checksum))
    #expect(!visible.contains(.verifyChecksum))
    #expect(RightClickMenuPolicy.targetDirectory(context: context) == "/tmp/folder")
    #expect(RightClickMenuPolicy.affectedPaths(context: context) == ["/tmp/folder"])
}

@Test("多选文件隐藏创建和单文件校验")
func rightClickMultipleFilesMenu() {
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/a", isDirectory: false), .init(path: "/tmp/b", isDirectory: false)], clipboard: .text)
    let visible = RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context)
    #expect(visible.contains(.checksum))
    #expect(visible.contains(.copyToFolder))
    #expect(visible.contains(.moveToFolder))
    #expect(visible.contains(.openWithApp))
    for item: RightClickItem in [.newFolder, .newFile, .saveClipboard, .openInTerminal, .verifyChecksum] { #expect(!visible.contains(item)) }
}

@Test("混合多选隐藏校验值操作")
func rightClickMixedSelectionMenu() {
    let context = RightClickMenuContext(directoryPath: nil, selection: [.init(path: "/tmp/a", isDirectory: false), .init(path: "/tmp/b", isDirectory: true)], clipboard: .image)
    let visible = RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context)
    #expect(!visible.contains(.checksum))
    #expect(!visible.contains(.copyCurrentRelativePath))
    #expect(visible.contains(.copyGitRelativePath))
    #expect(visible.contains(.copyToFolder))
}

@Test("无资源和关闭开关时不显示对应菜单")
func rightClickMenuRespectsConfiguration() {
    let blank = RightClickMenuContext(directoryPath: "/tmp", selection: [], clipboard: .text)
    let files = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/a", isDirectory: false)], clipboard: .none)
    let empty = RightClickConfig(enabled: [:], templates: [])
    #expect(!RightClickMenuPolicy.visibleItems(config: empty, context: blank).contains(.newFile))
    #expect(!RightClickMenuPolicy.visibleItems(config: empty, context: files).contains(.openWithApp))
    #expect(!RightClickMenuPolicy.visibleItems(config: empty, context: files).contains(.copyToFolder))
    #expect(!RightClickMenuPolicy.visibleItems(config: empty, context: files).contains(.moveToFolder))
    #expect(RightClickMenuPolicy.visibleItems(config: .disabled, context: files).isEmpty)
    var ordered = configuredRightClickMenu
    ordered.order = ["copyAbsolutePath", "newFolder"]
    #expect(RightClickMenuPolicy.visibleItems(config: ordered, context: blank).prefix(2) == [.copyAbsolutePath, .newFolder])
}

@Test("路径相对化按分量处理共同前缀")
func rightClickPathRelativeFormatting() {
    #expect(RightClickPathFormatter.relativePath(path: "/tmp/project/a.swift", base: "/tmp/project") == "a.swift")
    #expect(RightClickPathFormatter.relativePath(path: "/tmp/project2/a.swift", base: "/tmp/project") == "../project2/a.swift")
    #expect(RightClickPathFormatter.relativePath(path: "/tmp/project", base: "/tmp/project/") == ".")
    #expect(RightClickPathFormatter.relativePath(path: "/tmp/a/../b", base: "/tmp") == "b")
    #expect(RightClickPathFormatter.relativePath(path: "/tmp/a", base: "/") == "tmp/a")
}

@Test("用户目录缩写不会误判同名前缀")
func rightClickHomePathFormatting() {
    #expect(RightClickPathFormatter.homeRelativePath(path: "/Users/me", home: "/Users/me") == "~")
    #expect(RightClickPathFormatter.homeRelativePath(path: "/Users/me/中文 🎉", home: "/Users/me/") == "~/中文 🎉")
    #expect(RightClickPathFormatter.homeRelativePath(path: "/Users/me2/a", home: "/Users/me") == "/Users/me2/a")
}

@Test("路径复制正确处理点文件、特殊字符和 Markdown")
func rightClickSpecialPathFormatting() {
    #expect(RightClickPathFormatter.filenameWithoutExtension(path: "/tmp/.gitignore") == ".gitignore")
    #expect(RightClickPathFormatter.filenameWithoutExtension(path: "/tmp/archive.tar.gz") == "archive.tar")
    #expect(RightClickPathFormatter.filenameWithoutExtension(path: "/tmp/中文 🎉.md") == "中文 🎉")
    #expect(RightClickPathFormatter.shellEscaped("a'b $x") == "'a'\\''b $x'")
    #expect(RightClickPathFormatter.shellEscaped("") == "''")
    let link = RightClickPathFormatter.markdownLink(path: "/tmp/a[b](c) 中文.md")
    #expect(link.hasPrefix("[a\\[b\\](c) 中文.md](file:///tmp/"))
    #expect(link.contains("%20"))
    #expect(link.contains("%28c%29"))
}

@Test("一万项选择仍保留顺序且支持批量校验")
func rightClickLargeSelection() {
    let selection = (0..<10_000).map { RightClickSelection(path: "/tmp/\($0)", isDirectory: false) }
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: selection, clipboard: .none)
    #expect(RightClickMenuPolicy.affectedPaths(context: context) == selection.map(\.path))
    #expect(RightClickMenuPolicy.visibleItems(config: configuredRightClickMenu, context: context).contains(.checksum))
}

@Test("右键选中的文件或目录以父目录作为当前相对路径基准", arguments: [false, true])
func rightClickBrowsingDirectoryForSelectedItem(isDirectory: Bool) throws {
    let target = RightClickSelection(path: "/tmp/project/选中项", isDirectory: isDirectory)
    let base = try #require(RightClickMenuPolicy.browsingDirectory(target: target, selection: [target], isContainer: false))
    #expect(base == "/tmp/project")
    #expect(RightClickPathFormatter.relativePath(path: target.path, base: base) == "选中项")
}

@Test("容器菜单使用容器目录作为当前相对路径基准")
func rightClickBrowsingDirectoryForContainer() {
    let target = RightClickSelection(path: "/tmp/project", isDirectory: true)
    #expect(RightClickMenuPolicy.browsingDirectory(target: target, selection: [], isContainer: true) == "/tmp/project")
    #expect(RightClickMenuPolicy.browsingDirectory(target: target, selection: [target], isContainer: true) == "/tmp/project")
}

@Test("未选中的目标目录与文件仍提供明确浏览位置")
func rightClickBrowsingDirectoryForUnselectedTarget() {
    let selection = [RightClickSelection(path: "/tmp/project/a.txt", isDirectory: false)]
    let directory = RightClickSelection(path: "/tmp/project", isDirectory: true)
    let file = RightClickSelection(path: "/tmp/project/b.txt", isDirectory: false)
    #expect(RightClickMenuPolicy.browsingDirectory(target: directory, selection: selection, isContainer: false) == "/tmp/project")
    #expect(RightClickMenuPolicy.browsingDirectory(target: file, selection: selection, isContainer: false) == "/tmp/project")
}

@Test("缺少右键目标时不从跨目录选择推测浏览位置")
func rightClickBrowsingDirectoryDoesNotGuessFromSelection() {
    let selection = [RightClickSelection(path: "/tmp/project/a.txt", isDirectory: false), RightClickSelection(path: "/tmp/other/b.txt", isDirectory: false)]
    #expect(RightClickMenuPolicy.browsingDirectory(target: nil, selection: selection, isContainer: false) == nil)
    #expect(RightClickMenuPolicy.browsingDirectory(target: nil, selection: selection, isContainer: true) == nil)
    #expect(RightClickMenuPolicy.browsingDirectory(target: nil, selection: [], isContainer: false) == nil)
}

@Test("文件名与路径复制集中在首个复制项位置且保留用户排序")
func rightClickMenuEntriesGroupCopyActionsInPlace() {
    var config = configuredRightClickMenu
    let ordered: [RightClickItem] = [.checksum, .copyFilename, .openInTerminal, .copyAbsolutePath, .copyToFolder, .moveToFolder]
    config.enabled = Dictionary(uniqueKeysWithValues: RightClickItem.allCases.map { ($0.rawValue, ordered.contains($0)) })
    config.order = ordered.map(\.rawValue)
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/a.txt", isDirectory: false)], clipboard: .none)

    let expected: [RightClickMenuEntry] = [
        .action(.checksum), .copy([.copyFilename, .copyAbsolutePath]),
        .action(.openInTerminal), .action(.copyToFolder), .action(.moveToFolder)
    ]
    #expect(RightClickMenuPolicy.entries(config: config, context: context) == expected)
}

@Test("复制子菜单仅包含启用且符合当前场景的操作")
func rightClickMenuEntriesFilterCopyActionsBeforeGrouping() {
    var config = RightClickConfig.disabled
    let ordered: [RightClickItem] = [.copyGitRelativePath, .openInTerminal, .copyAbsolutePath, .copyFilename, .copyCurrentRelativePath, .copyMarkdownLink]
    config.order = ordered.map(\.rawValue)
    for item in ordered where item != .copyMarkdownLink { config.enabled[item.rawValue] = true }
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [], clipboard: .none)

    let expected: [RightClickMenuEntry] = [.action(.openInTerminal), .copy([.copyAbsolutePath, .copyFilename])]
    #expect(RightClickMenuPolicy.entries(config: config, context: context) == expected)
}

@Test("复制功能全部关闭或当前场景不可用时不生成空子菜单")
func rightClickMenuEntriesOmitEmptyCopyGroup() {
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [], clipboard: .none)
    #expect(RightClickMenuPolicy.entries(config: .disabled, context: context).isEmpty)
    var config = RightClickConfig.disabled
    config.enabled[RightClickItem.openInTerminal.rawValue] = true
    #expect(RightClickMenuPolicy.entries(config: config, context: context) == [.action(.openInTerminal)])
    config.enabled[RightClickItem.copyCurrentRelativePath.rawValue] = true
    #expect(RightClickMenuPolicy.entries(config: config, context: context) == [.action(.openInTerminal)])
    let missingContext = RightClickMenuContext(directoryPath: nil, selection: [], clipboard: .none)
    #expect(RightClickMenuPolicy.entries(config: .default, context: missingContext).isEmpty)
}

@Test("全部复制操作形成唯一子菜单且重复排序不复制菜单项")
func rightClickMenuEntriesContainOneCompleteCopyGroup() {
    var config = RightClickConfig.disabled
    let copyItems: [RightClickItem] = [
        .copyMarkdownLink, .copyFilename, .copyFilenameWithoutExtension, .copyAbsolutePath,
        .copyRelativePath, .copyCurrentRelativePath, .copyGitRelativePath, .copyEscapedPath, .copyFileURL
    ]
    for item in copyItems { config.enabled[item.rawValue] = true }
    config.order = [RightClickItem.copyMarkdownLink.rawValue] + copyItems.map(\.rawValue)
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/a.txt", isDirectory: false)], clipboard: .none)
    #expect(RightClickMenuPolicy.entries(config: config, context: context) == [.copy(copyItems)])
}
