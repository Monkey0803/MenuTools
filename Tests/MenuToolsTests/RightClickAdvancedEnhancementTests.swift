import AppKit
import Foundation
import Testing
@testable import MenuTools

@Test("旧配置补齐目录清单选项，新配置可往返")
func rightClickDirectoryListingOptionsMigrateAndRoundTrip() throws {
    let legacy = try JSONDecoder().decode(
        RightClickConfig.self,
        from: Data(#"{"enabled":{},"templates":[],"applications":[],"destinations":[]}"#.utf8)
    )
    #expect(legacy.directoryListing == .default)

    var configured = legacy
    configured.directoryListing = .init(
        includeHidden: true, maxDepth: 7, ignoredPatterns: [".git", "*.tmp", "build/**"])
    let encoded = try JSONEncoder().encode(configured)
    #expect(try JSONDecoder().decode(RightClickConfig.self, from: encoded) == configured)
    _ = try configured.validated()
}

@Test("模板增强变量在文件名和内容间共享 UUID、剪贴板和用户输入")
func rightClickTemplateRendererSupportsAdvancedVariables() {
    let context = RightClickTemplateRenderer.Context(
        directory: URL(fileURLWithPath: "/tmp/Project"),
        date: Date(timeIntervalSince1970: 1_704_164_645),
        timeZone: TimeZone(secondsFromGMT: 0)!,
        projectName: "Repo",
        uuid: "fixed-uuid",
        clipboard: "剪贴板内容",
        prompts: ["模块名": "账户"]
    )
    let template = "{{uuid}}|{{clipboard}}|{{prompt:模块名}}|{{prompt:缺失}}"
    #expect(RightClickTemplateRenderer.render(template, context: context)
            == "fixed-uuid|剪贴板内容|账户|{{prompt:缺失}}")
    #expect(RightClickTemplateRenderer.promptNames(in: [
        "{{prompt:模块名}}/{{prompt:作者}}", "{{prompt:模块名}}", "{{prompt: }}"
    ]) == ["模块名", "作者"])
}

@Test("模板文件名允许提示变量中的冒号但拒绝普通冒号")
func rightClickTemplatePromptFilenameValidation() throws {
    var config = RightClickConfig.default
    config.templates.append(.init(
        id: "prompt-name", name: "提示模板",
        filename: "{{prompt:模块名}}-{{uuid}}.txt", content: "{{prompt:模块名}}"))
    _ = try config.validated()

    config.templates[config.templates.count - 1].filename = "bad:name.txt"
    #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
}

@Test("目录清单支持 Markdown、JSON、忽略规则、深度和隐藏文件")
func rightClickDirectoryListingSupportsAdvancedOptions() throws {
    try withAdvancedRightClickDirectory { root in
        let visible = root.appendingPathComponent("Visible")
        let nested = visible.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: nested.appendingPathComponent("keep.txt"))
        try Data("tmp".utf8).write(to: visible.appendingPathComponent("drop.tmp"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".secret"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)

        let options = RightClickDirectoryListingOptions(
            includeHidden: false, maxDepth: 1, ignoredPatterns: [".git", "*.tmp"])
        let markdown = try RightClickContentService.directoryListing(
            at: root, style: .markdown, options: options)
        #expect(markdown.contains("- Visible/"))
        #expect(markdown.contains("  - Nested/"))
        #expect(!markdown.contains("keep.txt"))
        #expect(!markdown.contains("drop.tmp"))
        #expect(!markdown.contains(".secret"))
        #expect(!markdown.contains(".git"))

        let json = try RightClickContentService.directoryListing(
            at: root, style: .json,
            options: .init(includeHidden: true, maxDepth: 3, ignoredPatterns: [".git", "*.tmp"])
        )
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["name"] as? String == root.lastPathComponent)
        let children = try #require(object["children"] as? [[String: Any]])
        #expect(children.contains { $0["name"] as? String == ".secret" })
        #expect(!json.contains("drop.tmp"))
        #expect(json.contains("keep.txt"))
    }
}

@Test("批量重命名四种预设生成可预览计划")
func rightClickBatchRenameBuildsFourPresetPlans() throws {
    try withAdvancedRightClickDirectory { root in
        let first = try RightClickFileService.createFile(
            in: root, name: "alpha.txt", data: Data())
        let second = try RightClickFileService.createFile(
            in: root, name: "beta.txt", data: Data())
        let urls = [first, second]

        #expect(try RightClickBatchRenameService.plan(
            urls, rule: .regex(pattern: "a", replacement: "A")).map(\.destination.lastPathComponent)
                == ["AlphA.txt", "betA.txt"])
        #expect(try RightClickBatchRenameService.plan(
            urls, rule: .sequence(start: 3)).map(\.destination.lastPathComponent)
                == ["alpha 03.txt", "beta 04.txt"])
        #expect(try RightClickBatchRenameService.plan(
            urls, rule: .datePrefix(Date(timeIntervalSince1970: 1_704_153_600), TimeZone(secondsFromGMT: 0)!))
            .map(\.destination.lastPathComponent) == ["2024-01-02_alpha.txt", "2024-01-02_beta.txt"])
        #expect(try RightClickBatchRenameService.plan(
            urls, rule: .extension("md")).map(\.destination.lastPathComponent)
                == ["alpha.md", "beta.md"])
    }
}

@Test("批量重命名执行后可撤销，并拒绝目标冲突")
func rightClickBatchRenameAppliesSafely() throws {
    try withAdvancedRightClickDirectory { root in
        let first = try RightClickFileService.createFile(
            in: root, name: "first.txt", data: Data("1".utf8))
        let second = try RightClickFileService.createFile(
            in: root, name: "second.txt", data: Data("2".utf8))
        let plans = try RightClickBatchRenameService.plan(
            [first, second], rule: .sequence(start: 1))
        let completions = try RightClickBatchRenameService.apply(plans)
        #expect(completions.map(\.destination.lastPathComponent) == ["first 01.txt", "second 02.txt"])
        #expect(completions.allSatisfy { RightClickFileService.itemExists($0.destination) })

        let entries = try completions.map { completion in
            RightClickUndoRecord.Entry(
                source: completion.source.path,
                destination: completion.destination.path,
                destinationIdentity: try #require(RightClickFileService.itemIdentity(completion.destination)))
        }
        let undone = RightClickFileService.undo(.init(kind: .rename, entries: entries))
        #expect(undone.failures.isEmpty)
        #expect(RightClickFileService.itemExists(first))
        #expect(RightClickFileService.itemExists(second))

        _ = try RightClickFileService.createFile(in: root, name: "first.md", data: Data())
        #expect(throws: RightClickBatchRenameError.self) {
            try RightClickBatchRenameService.plan([first], rule: .extension("md"))
        }
        #expect(throws: RightClickBatchRenameError.self) {
            try RightClickBatchRenameService.plan(
                [first, second], rule: .regex(pattern: "first", replacement: "second"))
        }
    }
}

@Test("批量重命名撤销可处理目标与原文件名交叠")
func rightClickBatchRenameUndoHandlesOverlappingNames() throws {
    try withAdvancedRightClickDirectory { root in
        let first = try RightClickFileService.createFile(in: root, name: "a.txt", data: Data("a".utf8))
        let second = try RightClickFileService.createFile(in: root, name: "a 01.txt", data: Data("b".utf8))
        let plans = try RightClickBatchRenameService.plan([first, second], rule: .sequence(start: 1))
        let completions = try RightClickBatchRenameService.apply(plans)
        let entries = try completions.map { completion in
            RightClickUndoRecord.Entry(
                source: completion.source.path, destination: completion.destination.path,
                destinationIdentity: try #require(RightClickFileService.itemIdentity(completion.destination)))
        }

        let result = RightClickFileService.undo(.init(kind: .rename, entries: entries))

        #expect(result.failures.isEmpty)
        #expect(try String(contentsOf: first, encoding: .utf8) == "a")
        #expect(try String(contentsOf: second, encoding: .utf8) == "b")
    }
}

@Test("文件信息可输出文本、Markdown 和 JSON")
func rightClickFileInfoFormatsContainRequestedMetadata() throws {
    let info = RightClickFileInfo(
        name: "photo.png", path: "/tmp/photo.png", sizeBytes: 1_024,
        typeIdentifier: "public.png", mimeType: "image/png",
        createdAt: Date(timeIntervalSince1970: 1_704_153_600),
        modifiedAt: Date(timeIntervalSince1970: 1_704_157_200),
        permissions: "644", imageWidth: 800, imageHeight: 600, durationSeconds: nil)
    let zone = TimeZone(secondsFromGMT: 0)!
    let text = RightClickFileInfoFormatter.format([info], as: .text, timeZone: zone)
    #expect(text.contains("photo.png"))
    #expect(text.contains("1 KB"))
    #expect(text.contains("800 × 600"))
    #expect(text.contains("644"))

    let markdown = RightClickFileInfoFormatter.format([info], as: .markdown, timeZone: zone)
    #expect(markdown.contains("| photo.png |"))
    #expect(markdown.contains("image/png"))

    let json = RightClickFileInfoFormatter.format([info], as: .json, timeZone: zone)
    #expect(json.contains("2024-01-02T00:00:00Z"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([RightClickFileInfo].self, from: Data(json.utf8))
    #expect(decoded == [info])
}

@Test("文件信息从真实文件读取大小、类型、权限、图片尺寸和媒体时长")
func rightClickFileInfoCollectsRealMetadata() async throws {
    try await withAdvancedRightClickDirectory { root in
        let text = root.appendingPathComponent("note.txt")
        try Data("abc".utf8).write(to: text)
        let textInfo = try #require(try await RightClickFileInfoService.collect([text]).first)
        #expect(textInfo.sizeBytes == 3)
        #expect(!textInfo.typeIdentifier.isEmpty)
        #expect(textInfo.permissions.count == 3)

        let image = root.appendingPathComponent("pixel.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: image)
        let imageInfo = try #require(try await RightClickFileInfoService.collect([image]).first)
        #expect(imageInfo.imageWidth == 2)
        #expect(imageInfo.imageHeight == 3)

        let wave = root.appendingPathComponent("tone.wav")
        try makeOneSecondWave().write(to: wave)
        let waveInfo = try #require(try await RightClickFileInfoService.collect([wave]).first)
        #expect(abs((waveInfo.durationSeconds ?? 0) - 1) < 0.05)
    }
}

@Test("批量重命名拒绝非法正则替换捕获组和目录")
func rightClickBatchRenameRejectsUnsafeInputs() throws {
    try withAdvancedRightClickDirectory { root in
        let file = try RightClickFileService.createFile(in: root, name: "item.txt", data: Data())
        #expect(throws: RightClickBatchRenameError.self) {
            try RightClickBatchRenameService.plan(
                [file], rule: .regex(pattern: "(item)", replacement: "$2.txt"))
        }

        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: RightClickBatchRenameError.self) {
            try RightClickBatchRenameService.plan([folder], rule: .sequence(start: 1))
        }
    }
}

@Test("新菜单动作按文件选择显示且命令格式受白名单约束")
func rightClickAdvancedMenuAndCommandPolicy() throws {
    let file = RightClickMenuContext(
        directoryPath: "/tmp", selection: [.init(path: "/tmp/a.txt", isDirectory: false)], clipboard: .none)
    let folder = RightClickMenuContext(
        directoryPath: "/tmp", selection: [.init(path: "/tmp/Folder", isDirectory: true)], clipboard: .none)
    let fileItems = RightClickMenuPolicy.visibleItems(config: .default, context: file)
    #expect(fileItems.contains(.batchRename))
    #expect(fileItems.contains(.copyFileInfo))
    #expect(!RightClickMenuPolicy.visibleItems(config: .default, context: folder).contains(.batchRename))
    #expect(!RightClickMenuPolicy.visibleItems(config: .default, context: folder).contains(.copyFileInfo))

    for preset in ["regex", "sequence", "date", "extension"] {
        #expect(try RightClickCommandPolicy.validate(
            .init(action: "batchRename", paths: ["/tmp/a.txt"], optionID: preset), config: .default) == .batchRename)
    }
    for format in ["text", "markdown", "json"] {
        #expect(try RightClickCommandPolicy.validate(
            .init(action: "copyFileInfo", paths: ["/tmp/a.txt"], optionID: format), config: .default) == .copyFileInfo)
    }
    for format in ["list", "tree", "markdown", "json"] {
        #expect(try RightClickCommandPolicy.validate(
            .init(action: "copyDirectoryListing", paths: ["/tmp/Folder"], optionID: format), config: .default) == .copyDirectoryListing)
    }
    for invalid in [nil, "", "shell", "../json"] as [String?] {
        #expect(throws: RightClickCommandError.self) {
            try RightClickCommandPolicy.validate(
                .init(action: "batchRename", paths: ["/tmp/a.txt"], optionID: invalid), config: .default)
        }
        #expect(throws: RightClickCommandError.self) {
            try RightClickCommandPolicy.validate(
                .init(action: "copyFileInfo", paths: ["/tmp/a.txt"], optionID: invalid), config: .default)
        }
    }
}

@Test("目录清单设置拒绝越界深度和不安全忽略规则")
func rightClickDirectoryListingOptionsValidateLimits() {
    for options in [
        RightClickDirectoryListingOptions(includeHidden: false, maxDepth: -1, ignoredPatterns: []),
        RightClickDirectoryListingOptions(includeHidden: false, maxDepth: 51, ignoredPatterns: []),
        RightClickDirectoryListingOptions(includeHidden: false, maxDepth: 3, ignoredPatterns: [""]),
        RightClickDirectoryListingOptions(includeHidden: false, maxDepth: 3, ignoredPatterns: ["bad\0pattern"]),
        RightClickDirectoryListingOptions(includeHidden: false, maxDepth: 3, ignoredPatterns: Array(repeating: "*", count: 33))
    ] {
        var config = RightClickConfig.default
        config.directoryListing = options
        #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
    }
}

private func withAdvancedRightClickDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Advanced-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func withAdvancedRightClickDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Advanced-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func makeOneSecondWave() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount: UInt32 = 8_000
    var data = Data("RIFF".utf8)
    appendLittleEndian(UInt32(36) + sampleCount, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(8), to: &data)
    data.append(Data("data".utf8))
    appendLittleEndian(sampleCount, to: &data)
    data.append(Data(repeating: 128, count: Int(sampleCount)))
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
