import AppKit
import Foundation
import Testing
@testable import MenuTools

@Test("常用应用筛选支持代码优先、目录及多选交集")
func rightClickApplicationFilterMatchesKinds() {
    let sourceOnly = RightClickApplicationFilter(kinds: [.code])
    #expect(sourceOnly.matches(path: "/tmp/main.swift", isDirectory: false))
    #expect(!sourceOnly.matches(path: "/tmp/readme.txt", isDirectory: false))
    #expect(!sourceOnly.matches(path: "/tmp/project", isDirectory: true))
    #expect(RightClickApplicationFilter(kinds: [.directory]).matches(path: "/tmp/project", isDirectory: true))
    #expect(RightClickApplicationFilter.all.matches(path: "/tmp/archive.zip", isDirectory: false))
}

@Test("旧常用应用配置解码时默认允许全部文件类型")
func rightClickApplicationFilterMigratesOldConfig() throws {
    let json = Data(#"{"id":"editor","name":"Editor","path":"/Applications/Editor.app","bundleIdentifier":"org.example.Editor"}"#.utf8)
    let app = try JSONDecoder().decode(RightClickApplication.self, from: json)
    #expect(app.filter == .all)
}

@Test("模板变量使用同一时间上下文且未知变量保留")
func rightClickTemplateRendererUsesStableContext() {
    let date = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02 03:04:05 UTC
    let context = RightClickTemplateRenderer.Context(
        directory: URL(fileURLWithPath: "/tmp/MyProject"), date: date,
        timeZone: TimeZone(secondsFromGMT: 0)!, projectName: "Repo")
    let rendered = RightClickTemplateRenderer.render(
        "{{date}} {{time}} {{datetime}} {{directory}} {{project}} {{unknown}}", context: context)
    #expect(rendered == "2024-01-02 03-04-05 2024-01-02_03-04-05 MyProject Repo {{unknown}}")
}

@Test("复制文件内容支持 UTF-8、UTF-16 BOM 并拒绝二进制")
func rightClickContentServiceReadsText() throws {
    try withRightClickEnhancementDirectory { directory in
        let utf8 = directory.appendingPathComponent("中文.txt")
        try Data("你好\n".utf8).write(to: utf8)
        #expect(try RightClickContentService.readFile(at: utf8) == .text("你好\n"))

        let utf16 = directory.appendingPathComponent("utf16.txt")
        var data = Data([0xFF, 0xFE])
        data.append("A中".data(using: .utf16LittleEndian)!)
        try data.write(to: utf16)
        #expect(try RightClickContentService.readFile(at: utf16) == .text("A中"))

        let binary = directory.appendingPathComponent("binary.bin")
        try Data([0, 1, 2, 3]).write(to: binary)
        #expect(throws: RightClickContentError.self) { try RightClickContentService.readFile(at: binary) }

        let nul = directory.appendingPathComponent("nul.txt")
        try Data([0x61, 0x00]).write(to: nul)
        #expect(throws: RightClickContentError.self) { try RightClickContentService.readFile(at: nul) }
    }
}

@Test("复制图片内容统一为 PNG")
func rightClickContentServiceConvertsImageToPNG() throws {
    try withRightClickEnhancementDirectory { directory in
        let image = NSImage(size: NSSize(width: 2, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 1).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let file = directory.appendingPathComponent("pixel.tiff")
        try tiff.write(to: file)
        guard case .image(let png) = try RightClickContentService.readFile(at: file) else {
            Issue.record("图片必须返回 PNG 内容")
            return
        }
        #expect(png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }
}

@Test("目录清单支持列表与树形并且不递归符号链接")
func rightClickDirectoryListingFormatsAndProtectsSymlinks() throws {
    try withRightClickEnhancementDirectory { directory in
        let folder = directory.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: folder.appendingPathComponent("b.txt"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: folder)

        let list = try RightClickContentService.directoryListing(at: directory, style: .list)
        #expect(list == "Folder/\na.txt\nlink@")
        let tree = try RightClickContentService.directoryListing(at: directory, style: .tree)
        #expect(tree.contains("Folder/"))
        #expect(tree.contains("b.txt"))
        #expect(tree.contains("link@"))
        #expect(tree.components(separatedBy: "b.txt").count == 2)
    }
}

private func withRightClickEnhancementDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuTools-Enhancement-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test("内容、目录清单和撤销操作按 Finder 场景显示")
func rightClickEnhancementMenuVisibility() {
    let file = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/a.txt", isDirectory: false)], clipboard: .none)
    let folder = RightClickMenuContext(directoryPath: "/tmp", selection: [.init(path: "/tmp/Folder", isDirectory: true)], clipboard: .none)
    let files = RightClickMenuContext(directoryPath: "/tmp", selection: [
        .init(path: "/tmp/a.txt", isDirectory: false), .init(path: "/tmp/b.txt", isDirectory: false)
    ], clipboard: .none)
    #expect(RightClickMenuPolicy.visibleItems(config: .default, context: file).contains(.copyFileContents))
    #expect(!RightClickMenuPolicy.visibleItems(config: .default, context: files).contains(.copyFileContents))
    #expect(RightClickMenuPolicy.visibleItems(config: .default, context: folder).contains(.copyDirectoryListing))
    #expect(!RightClickMenuPolicy.visibleItems(config: .default, context: file).contains(.copyDirectoryListing))
    #expect(RightClickMenuPolicy.visibleItems(config: .default, context: file).contains(.undoLastOperation))
}

@Test("目录清单命令仅接受支持的四种格式且内容复制只接受单文件")
func rightClickEnhancementCommandValidation() throws {
    #expect(try RightClickCommandPolicy.validate(
        .init(action: "copyFileContents", paths: ["/tmp/a.txt"]), config: .default) == .copyFileContents)
    #expect(throws: RightClickCommandError.self) {
        try RightClickCommandPolicy.validate(.init(action: "copyFileContents", paths: ["/tmp/a", "/tmp/b"]), config: .default)
    }
    for style in ["list", "tree", "markdown", "json"] {
        #expect(try RightClickCommandPolicy.validate(
            .init(action: "copyDirectoryListing", paths: ["/tmp/Folder"], optionID: style), config: .default) == .copyDirectoryListing)
    }
    #expect(throws: RightClickCommandError.self) {
        try RightClickCommandPolicy.validate(.init(action: "copyDirectoryListing", paths: ["/tmp/Folder"], optionID: "xml"), config: .default)
    }
}

@Test("常用应用列表按全部选中项做交集筛选")
func rightClickApplicationsUseSelectionIntersection() {
    let code = RightClickApplication(id: "code", name: "Code", path: "/Applications/Code.app",
                                     bundleIdentifier: "example.code", filter: .init(kinds: [.code]))
    let all = RightClickApplication(id: "all", name: "All", path: "/Applications/All.app",
                                    bundleIdentifier: "example.all")
    let context = RightClickMenuContext(directoryPath: "/tmp", selection: [
        .init(path: "/tmp/a.swift", isDirectory: false), .init(path: "/tmp/readme.txt", isDirectory: false)
    ], clipboard: .none)
    #expect(RightClickMenuPolicy.applications([code, all], context: context).map(\.id) == ["all"])
}
