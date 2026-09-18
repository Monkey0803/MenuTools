import AppKit
import Foundation
import Testing
@testable import MenuTools

@Test("右键指令拒绝未知动作、禁用动作、相对路径和超量选择")
func rightClickCommandRejectsInvalidInput() throws {
    for command in [
        RightClickCommand(action: "unknown", paths: ["/tmp"]),
        RightClickCommand(action: "newFile", paths: ["relative"]),
        RightClickCommand(action: "newFolder", paths: []),
        RightClickCommand(action: "checksum", paths: Array(repeating: "/tmp/test", count: 1001)),
        RightClickCommand(action: "newFolder", paths: ["/tmp/../etc"])
    ] {
        #expect(throws: (any Error).self) { try RightClickCommandPolicy.validate(command, config: .default) }
    }
    #expect(throws: (any Error).self) {
        try RightClickCommandPolicy.validate(.init(action: "newFolder", paths: ["/tmp"]), config: .disabled)
    }
}

@Test("右键指令仅可使用已配置的应用、模板和目标目录")
func rightClickCommandResolvesConfiguredOptions() throws {
    var config = RightClickConfig.default
    config.applications = [.init(id: "app", name: "TextEdit", path: "/System/Applications/TextEdit.app", bundleIdentifier: "com.apple.TextEdit")]
    config.destinations = [.init(id: "dest", name: "Temp", path: "/tmp")]
    for (action, id) in [("openWithApp", "app"), ("copyToFolder", "dest"), ("moveToFolder", "dest"),
                         ("newFile", config.templates[0].id)] {
        let command = RightClickCommand(action: action, paths: ["/tmp/test"], optionID: id)
        #expect(try RightClickCommandPolicy.validate(command, config: config).rawValue == action)
        #expect(throws: (any Error).self) {
            try RightClickCommandPolicy.validate(.init(action: action, paths: ["/tmp/test"], optionID: "missing"), config: config)
        }
    }
}

@Test("校验比对仅接受单文件，当前相对路径要求明确基准目录")
func rightClickCommandChecksActionRequirements() throws {
    #expect(throws: (any Error).self) {
        try RightClickCommandPolicy.validate(.init(action: "verifyChecksum", paths: ["/a", "/b"]), config: .default)
    }
    #expect(throws: (any Error).self) {
        try RightClickCommandPolicy.validate(.init(action: "copyCurrentRelativePath", paths: ["/tmp/a"]), config: .default)
    }
    #expect(try RightClickCommandPolicy.validate(
        .init(action: "copyCurrentRelativePath", paths: ["/tmp/a"], directoryPath: "/tmp"), config: .default) == .copyCurrentRelativePath)
}

@Test("剪贴板快照识别文本、PNG 图片并排除文件引用")
@MainActor func rightClickClipboardSnapshotUsesContentType() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickTests.\(UUID())"))
    defer { board.releaseGlobally() }
    #expect(RightClickClipboardReader.read(from: board) == nil)
    board.setString("hello", forType: .string)
    #expect(RightClickClipboardReader.read(from: board) == .text("hello"))
    board.clearContents()
    board.setString("file:///tmp/file.txt", forType: .fileURL)
    board.setString("/tmp/file.txt", forType: .string)
    #expect(RightClickClipboardReader.read(from: board) == nil)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
    bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 0, y: 0)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    board.clearContents()
    board.setData(png, forType: .png)
    let decoded = try requireRightClickPNGSnapshot(RightClickClipboardReader.read(from: board))
    #expect(decoded.pixelsWide == 1)
    #expect(decoded.pixelsHigh == 1)
    var pixel = [Int](repeating: 0, count: decoded.samplesPerPixel)
    decoded.getPixel(&pixel, atX: 0, y: 0)
    #expect(Array(pixel.prefix(3)) == [0, 255, 0])
}

@Test("旧扩展发送的十一类文件创建指令仍然可用", arguments: ["txt", "md", "json", "yaml", "xml", "csv", "html", "css", "js", "py", "sh"])
func rightClickCommandAcceptsLegacyFileExtensions(fileExtension: String) throws {
    let legacyJSON = "{\"action\":\"newFile\",\"paths\":[\"/tmp\"],\"fileExtension\":\"\(fileExtension)\"}"
    let command = try #require(RightClickCommandStore.decode(legacyJSON))
    #expect(command.optionID == nil)
    #expect(try RightClickCommandPolicy.validate(command, config: .default) == .newFile)
}

@Test("旧文件创建指令必须声明有效扩展", arguments: [nil, "", ".txt", "TXT", "exe", "../txt", "txt\0"] as [String?])
func rightClickCommandRejectsInvalidLegacyExtensions(fileExtension: String?) {
    let command = RightClickCommand(action: "newFile", paths: ["/tmp"], fileExtension: fileExtension)
    #expect(throws: RightClickCommandError.self) { try RightClickCommandPolicy.validate(command, config: .default) }
}

@Test("新模板标识优先于旧扩展且不能回退到其他模板")
func rightClickCommandUsesExplicitTemplateOption() throws {
    let template = RightClickTemplate(id: "custom-readme", name: "README", filename: "README.md", content: "# Test")
    let config = RightClickConfig(enabled: [:], templates: [template])
    let valid = RightClickCommand(action: "newFile", paths: ["/tmp"], fileExtension: "invalid", optionID: template.id)
    #expect(try RightClickCommandPolicy.validate(valid, config: config) == .newFile)
    let stale = RightClickCommand(action: "newFile", paths: ["/tmp"], fileExtension: "txt", optionID: "deleted-template")
    #expect(throws: RightClickCommandError.self) { try RightClickCommandPolicy.validate(stale, config: .default) }
}

@Test("应用和目录操作拒绝缺少标识及未配置选项", arguments: ["openWithApp", "copyToFolder", "moveToFolder"])
func rightClickCommandRequiresConfiguredOption(action: String) {
    var config = RightClickConfig.default
    config.applications = [.init(id: "app", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "example.Editor")]
    config.destinations = [.init(id: "destination", name: "目标", path: "/tmp")]
    for id: String? in [nil, "", "/Applications/Editor.app", "/tmp"] {
        let command = RightClickCommand(action: action, paths: ["/tmp/file"], optionID: id)
        #expect(throws: RightClickCommandError.self) { try RightClickCommandPolicy.validate(command, config: config) }
    }
}

@Test("剪贴板保存接受文本、Markdown、RTF、HTML 和 PNG", arguments: ["txt", "md", "rtf", "html", "png"])
func rightClickCommandAcceptsClipboardFormats(format: String) throws {
    let command = RightClickCommand(action: "saveClipboard", paths: ["/tmp"], optionID: format)
    #expect(try RightClickCommandPolicy.validate(command, config: .default) == .saveClipboard)
}

@Test("剪贴板保存拒绝未指定及其他扩展", arguments: [nil, "", "json", "tiff", "jpg", "TXT", ".png", "../png"] as [String?])
func rightClickCommandRejectsClipboardFormats(format: String?) {
    let command = RightClickCommand(action: "saveClipboard", paths: ["/tmp"], optionID: format)
    #expect(throws: RightClickCommandError.self) { try RightClickCommandPolicy.validate(command, config: .default) }
}

@Test("单目标动作不能把多选解释成一个目录", arguments: ["newFolder", "newFile", "openInTerminal", "saveClipboard", "verifyChecksum"])
func rightClickCommandRejectsMultipleCreationTargets(action: String) {
    let command = RightClickCommand(action: action, paths: ["/tmp/a", "/tmp/b"], fileExtension: "txt", optionID: "txt")
    #expect(throws: RightClickCommandError.self) { try RightClickCommandPolicy.validate(command, config: .default) }
}

@Test("命令路径与相对路径基准都拒绝 NUL、超长和相对路径")
func rightClickCommandValidatesPathBoundaries() throws {
    for path in ["relative", "", "/tmp/zero\0file", "/tmp/../etc", "/" + String(repeating: "a", count: 4096)] {
        #expect(throws: RightClickCommandError.self) {
            try RightClickCommandPolicy.validate(.init(action: "checksum", paths: [path]), config: .default)
        }
        #expect(throws: RightClickCommandError.self) {
            try RightClickCommandPolicy.validate(.init(action: "copyCurrentRelativePath", paths: ["/tmp/a"], directoryPath: path), config: .default)
        }
    }
    #expect(try RightClickCommandPolicy.validate(
        .init(action: "checksum", paths: ["/" + String(repeating: "a", count: 4095)]), config: .default) == .checksum)
    #expect(try RightClickCommandPolicy.validate(
        .init(action: "checksum", paths: Array(repeating: "/tmp/中文 🎉", count: 1000)), config: .default) == .checksum)
}

@Test("TIFF 剪贴板保存为带 PNG 文件头的图像并保留像素")
@MainActor func rightClickClipboardConvertsTIFFToPNG() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickTIFFTests.\(UUID())"))
    defer { board.releaseGlobally() }
    let bitmap = try makeRightClickClipboardBitmap()
    let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
    #expect(board.setData(tiff, forType: .tiff))
    guard case .image(let png) = RightClickClipboardReader.read(from: board) else {
        Issue.record("TIFF 剪贴板必须转换为图片快照")
        return
    }
    #expect(png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
    let decoded = try #require(NSBitmapImageRep(data: png))
    #expect(decoded.pixelsWide == 2)
    #expect(decoded.pixelsHigh == 1)
    var redPixel = [Int](repeating: 0, count: decoded.samplesPerPixel)
    var bluePixel = [Int](repeating: 0, count: decoded.samplesPerPixel)
    decoded.getPixel(&redPixel, atX: 0, y: 0)
    decoded.getPixel(&bluePixel, atX: 1, y: 0)
    #expect(Array(redPixel.prefix(3)) == [255, 0, 0])
    #expect(Array(bluePixel.prefix(3)) == [0, 0, 255])
}

@Test("损坏 PNG 与 TIFF 不会生成图片，存在文本时保留文本")
@MainActor func rightClickClipboardRejectsCorruptImageData() {
    let board = NSPasteboard(name: .init("MenuTools.RightClickCorruptImageTests.\(UUID())"))
    defer { board.releaseGlobally() }
    for format: NSPasteboard.PasteboardType in [.png, .tiff] {
        for data in [Data(), Data("not an image".utf8), Data([137, 80, 78, 71, 13, 10, 26, 10])] {
            board.clearContents()
            #expect(board.setData(data, forType: format))
            #expect(RightClickClipboardReader.read(from: board) == nil)
            #expect(board.setString("图片说明 中文 🎉", forType: .string))
            #expect(RightClickClipboardReader.read(from: board) == .text("图片说明 中文 🎉"))
        }
    }
}

@Test("空文本不可保存但空白、换行和特殊字符内容原样保留")
@MainActor func rightClickClipboardPreservesTextContent() {
    let board = NSPasteboard(name: .init("MenuTools.RightClickTextTests.\(UUID())"))
    defer { board.releaseGlobally() }
    #expect(board.setString("", forType: .string))
    #expect(RightClickClipboardReader.read(from: board) == nil)
    for text in [" ", "\n\t", "中文 🎉\n'\"; DROP TABLE docs;", String(repeating: "字", count: 10_000)] {
        board.clearContents()
        #expect(board.setString(text, forType: .string))
        #expect(RightClickClipboardReader.read(from: board) == .text(text))
    }
}

@Test("剪贴板图片优先于文本而文件引用不能作为图片导出")
@MainActor func rightClickClipboardPrioritizesImagesAndRejectsFileReferences() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickPriorityTests.\(UUID())"))
    defer { board.releaseGlobally() }
    let bitmap = try makeRightClickClipboardBitmap()
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    // 两种格式放入不同像素，确保读取器确实选择 PNG 而不是碰巧得到相同图片。
    bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 0, y: 0)
    let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
    #expect(board.setString("preview", forType: .string))
    #expect(board.setData(tiff, forType: .tiff))
    #expect(board.setData(png, forType: .png))
    let decoded = try requireRightClickPNGSnapshot(RightClickClipboardReader.read(from: board))
    #expect(decoded.pixelsWide == 2)
    #expect(decoded.pixelsHigh == 1)
    var pixel = [Int](repeating: 0, count: decoded.samplesPerPixel)
    decoded.getPixel(&pixel, atX: 0, y: 0)
    #expect(Array(pixel.prefix(3)) == [255, 0, 0])
    #expect(board.setString("file:///tmp/preview.png", forType: .fileURL))
    #expect(RightClickClipboardReader.read(from: board) == nil)
}

@MainActor private func makeRightClickClipboardBitmap() throws -> NSBitmapImageRep {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 8, bitsPerPixel: 32))
    bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
    bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 1, y: 0)
    return bitmap
}

@Test("PNG 类型槽中的 TIFF 数据必须重新编码为真实 PNG")
@MainActor func rightClickClipboardNormalizesMislabeledPNG() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickMislabeledPNGTests.\(UUID())"))
    defer { board.releaseGlobally() }
    let bitmap = try makeRightClickClipboardBitmap()
    let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
    #expect(board.setData(tiff, forType: .png))
    guard case .image(let exported) = RightClickClipboardReader.read(from: board) else {
        Issue.record("可解码图片应提供 PNG 格式的快照")
        return
    }
    #expect(exported.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
    let decoded = try #require(NSBitmapImageRep(data: exported))
    #expect(decoded.pixelsWide == 2)
    #expect(decoded.pixelsHigh == 1)
}

@MainActor private func requireRightClickPNGSnapshot(_ snapshot: RightClickClipboardSnapshot?) throws -> NSBitmapImageRep {
    let data: Data? = if case .image(let imageData) = snapshot { imageData } else { nil }
    let exported = try #require(data, "剪贴板必须提供图片快照")
    #expect(exported.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
    return try #require(NSBitmapImageRep(data: exported))
}

@Test("默认终端选项与旧指令都尊重已配置的终端偏好")
func rightClickTerminalDefaultOptionUsesPreference() {
    #expect(TerminalApp.defaultOptionID == "default")
    for optionID: String? in [nil, TerminalApp.defaultOptionID] {
        #expect(TerminalApp.resolve(optionID: optionID, preferredID: TerminalApp.iterm.rawValue, fallback: .terminal) == .iterm)
        #expect(TerminalApp.resolve(optionID: optionID, preferredID: TerminalApp.ghostty.rawValue, fallback: .warp) == .ghostty)
    }
}

@Test("默认终端在偏好缺失或过期时使用明确回退值")
func rightClickTerminalDefaultOptionUsesFallback() {
    for optionID: String? in [nil, TerminalApp.defaultOptionID] {
        for preferredID: String? in [nil, "", "removed-terminal", TerminalApp.defaultOptionID] {
            #expect(TerminalApp.resolve(optionID: optionID, preferredID: preferredID, fallback: .kitty) == .kitty)
        }
    }
}

@Test("显式终端选择不受默认偏好或回退终端影响")
func rightClickTerminalExplicitChoiceOverridesPreference() {
    for terminal in TerminalApp.allCases {
        #expect(TerminalApp.resolve(optionID: terminal.rawValue, preferredID: TerminalApp.warp.rawValue, fallback: .terminal) == terminal)
        #expect(TerminalApp.resolve(optionID: terminal.rawValue, preferredID: nil, fallback: .alacritty) == terminal)
    }
}

@Test("未知终端选择不会悄悄回退或作为应用路径使用", arguments: ["", "terminal", "com.example.Terminal", "/Applications/Terminal.app", "../default", "com.apple.Terminal\0"])
func rightClickTerminalRejectsUnknownOption(optionID: String) {
    #expect(TerminalApp.resolve(optionID: optionID, preferredID: TerminalApp.iterm.rawValue, fallback: .terminal) == nil)
    let command = RightClickCommand(action: "openInTerminal", paths: ["/tmp"], optionID: optionID)
    #expect(throws: RightClickCommandError.self) {
        try RightClickCommandPolicy.validate(command, config: .default)
    }
}

@Test("打开终端指令接受默认选项、旧指令及全部六种终端")
func rightClickCommandAcceptsSupportedTerminalOptions() throws {
    let terminalIDs = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty"
    ]
    for optionID in [nil, TerminalApp.defaultOptionID] + terminalIDs.map(Optional.some) {
        let command = RightClickCommand(action: "openInTerminal", paths: ["/tmp/中文 🎉"], optionID: optionID)
        #expect(try RightClickCommandPolicy.validate(command, config: .default) == .openInTerminal)
    }
}
