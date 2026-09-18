import Foundation
import Testing
@testable import MenuTools

@Test("右键配置通知可以解码为配置")
func rightClickNotificationDecodesConfig() throws {
    let expected = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false])
    let data = try JSONEncoder().encode(expected)
    let payload = try #require(String(data: data, encoding: .utf8))
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: payload
    )

    #expect(RightClickConfigStore.decode(notification) == expected)
}

@Test("无效右键配置通知会被忽略")
func invalidRightClickNotificationIsIgnored() {
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: "not-json"
    )

    #expect(RightClickConfigStore.decode(notification) == nil)
}

@Test("有效右键配置通知会替换过期状态")
func validRightClickNotificationReplacesStaleConfig() throws {
    let stale = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: true])
    let replacement = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false])
    let data = try JSONEncoder().encode(replacement)
    let payload = try #require(String(data: data, encoding: .utf8))
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: payload
    )

    #expect(RightClickConfigNotification.applying(notification, to: stale) == replacement)
}

@Test("无效右键配置通知会保留当前状态")
func invalidRightClickNotificationPreservesCurrentConfig() {
    let current = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false])
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: "not-json"
    )

    #expect(RightClickConfigNotification.applying(notification, to: current) == current)
}

@Test("禁用 Finder 工具时右键扩展配置不暴露任何菜单项")
func disabledRightClickConfigurationHidesEveryItem() {
    #expect(RightClickConfig.disabled.enabledItems.isEmpty)
    #expect(RightClickItem.allCases.allSatisfy { !RightClickConfig.disabled.isEnabled($0) })
}

@Test("旧右键配置补齐模板和新增字段")
func rightClickLegacyConfigurationMigrates() throws {
    let config = try JSONDecoder().decode(RightClickConfig.self, from: Data(#"{"enabled":{"newFile":false}}"#.utf8))
    #expect(!config.isEnabled(.newFile))
    #expect(config.templates == RightClickTemplate.builtIns)
    #expect(config.applications.isEmpty)
    #expect(config.destinations.isEmpty)
    #expect(config.order.isEmpty)
}

@Test("内置文件模板覆盖原有类型及项目配置")
func rightClickBuiltInTemplatesContainUsefulContent() throws {
    let templates = RightClickTemplate.builtIns
    for ext in ["txt", "md", "json", "yaml", "xml", "csv", "html", "css", "js", "py", "sh"] {
        #expect(templates.contains { URL(fileURLWithPath: $0.filename).pathExtension == ext })
    }
    #expect(templates.contains { $0.filename == "README.md" })
    #expect(templates.contains { $0.filename == ".gitignore" })
    #expect(templates.contains { $0.filename == ".editorconfig" })
    #expect(templates.first { $0.filename.hasSuffix(".json") }?.content == "{}\n")
    #expect(Set(templates.map(\.id)).count == templates.count)
    _ = try RightClickConfig.default.validated()
}

@Test("菜单排序去重并补齐未列出的菜单项")
func rightClickConfigurationOrdersItems() {
    let config = RightClickConfig(enabled: ["newFile": false], order: ["copyAbsolutePath", "newFile", "copyAbsolutePath", "removedItem"])
    #expect(config.orderedItems.prefix(2) == [.copyAbsolutePath, .newFile])
    #expect(config.orderedItems.count == RightClickItem.allCases.count)
    #expect(config.enabledItems.first == .copyAbsolutePath)
    #expect(!config.enabledItems.contains(.newFile))
}

@Test("自定义右键配置编码后保留所有设置")
func rightClickConfigurationRoundTrips() throws {
    let expected = RightClickConfig(
        enabled: ["checksum": false], order: ["openWithApp", "newFile"],
        templates: [.init(id: "template", name: "项目说明", filename: "说明 🎉.md", content: "# 中文\n")],
        applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "org.example.Editor")],
        destinations: [.init(id: "archive", name: "归档", path: "/Users/example/归档")]
    )
    let json = try JSONEncoder().encode(expected)
    #expect(try JSONDecoder().decode(RightClickConfig.self, from: json) == expected)
    #expect(RightClickConfigStore.decode(String(data: json, encoding: .utf8)) == expected)
}

@Test("无模板配置保持用户删除结果")
func rightClickConfigurationPreservesEmptyTemplates() throws {
    let data = Data(#"{"enabled":{},"templates":[]}"#.utf8)
    #expect(try JSONDecoder().decode(RightClickConfig.self, from: data).templates.isEmpty)
}

@Test("通知拒绝未知菜单项与类型错误")
func rightClickNotificationRejectsInvalidConfiguration() {
    for json in [#"{"enabled":{"invalid":true}}"#, #"{"enabled":[],"templates":[]}"#, #"{"enabled":{},"templates":null}"#] {
        #expect(RightClickConfigStore.decode(json) == nil)
    }
    #expect(RightClickConfigStore.decode(nil as String?) == nil)
}

@Test("配置拒绝不安全模板名", arguments: ["", " ", ".", "..", "../a", "a/b", "a\\b", "a\0b", "a\nb"])
func rightClickConfigurationRejectsUnsafeFilenames(filename: String) {
    let config = RightClickConfig(enabled: [:], templates: [.init(id: "test", name: "模板", filename: filename, content: "")])
    #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
}

@Test("配置拒绝不安全显示名", arguments: ["", " ", "../模板", "a/b", "a\nb"])
func rightClickConfigurationRejectsUnsafeNames(name: String) {
    let config = RightClickConfig(enabled: [:], templates: [.init(id: "test", name: name, filename: "test.md", content: "")])
    #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
}

@Test("配置拒绝重复资源 ID")
func rightClickConfigurationRejectsDuplicateIDs() {
    let template = RightClickTemplate(id: "same", name: "文本", filename: "a.txt", content: "")
    let app = RightClickApplication(id: "same", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "")
    let destination = RightClickDestination(id: "same", name: "归档", path: "/tmp/archive")
    for config in [
        RightClickConfig(enabled: [:], templates: [template, template]),
        RightClickConfig(enabled: [:], applications: [app, app]),
        RightClickConfig(enabled: [:], destinations: [destination, destination])
    ] {
        #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
    }
}

@Test("配置拒绝超限条目、内容与空 ID")
func rightClickConfigurationRejectsOversizedData() {
    let templates = (0..<129).map { RightClickTemplate(id: "\($0)", name: "模板", filename: "a.txt", content: "") }
    let apps = (0..<33).map { RightClickApplication(id: "\($0)", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "") }
    let destinations = (0..<33).map { RightClickDestination(id: "\($0)", name: "归档", path: "/tmp") }
    for config in [
        RightClickConfig(enabled: [:], templates: templates),
        RightClickConfig(enabled: [:], applications: apps),
        RightClickConfig(enabled: [:], destinations: destinations),
        RightClickConfig(enabled: [:], templates: [.init(id: "huge", name: "模板", filename: "a.txt", content: String(repeating: "a", count: 32_769))]),
        RightClickConfig(enabled: [:], templates: [.init(id: "", name: "模板", filename: "a.txt", content: "")]),
        RightClickConfig(enabled: [:], templates: [.init(id: "long", name: "模板", filename: String(repeating: "a", count: 256), content: "")])
    ] {
        #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
    }
}

@Test("配置接受上限以内的模板")
func rightClickConfigurationAcceptsTemplateBoundary() throws {
    let config = RightClickConfig(enabled: [:], templates: [.init(id: "boundary", name: "模板", filename: String(repeating: "a", count: 255), content: String(repeating: "a", count: 32_768))])
    #expect(try config.validated() == config)
}

@Test("配置拒绝非绝对应用路径和错误后缀", arguments: ["Editor.app", "~/Editor.app", "/Applications/Editor", "/Applications/../Editor.app", "/Applications/E\n.app"])
func rightClickConfigurationRejectsInvalidApplicationPath(path: String) {
    let config = RightClickConfig(enabled: [:], applications: [.init(id: "editor", name: "编辑器", path: path, bundleIdentifier: "")])
    #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
}

@Test("配置拒绝相对目标目录", arguments: ["", "archive", "~/archive", "/tmp/../archive", "/tmp/a\0b"])
func rightClickConfigurationRejectsInvalidDestinationPath(path: String) {
    let config = RightClickConfig(enabled: [:], destinations: [.init(id: "archive", name: "归档", path: path)])
    #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
}

@Test("旧操作指令兼容并保留新选项")
func rightClickCommandRemainsBackwardCompatible() throws {
    let legacy = try JSONDecoder().decode(RightClickCommand.self, from: Data(#"{"action":"newFile","paths":["/tmp"],"fileExtension":"txt"}"#.utf8))
    #expect(legacy.requestID == nil)
    #expect(legacy.optionID == nil)
    #expect(legacy.directoryPath == nil)
    #expect(legacy.fileExtension == "txt")
    let command = RightClickCommand(action: "newFile", paths: ["/tmp"], optionID: "readme", directoryPath: "/tmp", requestID: "request-1")
    let encoded = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(RightClickCommand.self, from: encoded)
    #expect(decoded.requestID == "request-1")
    #expect(decoded.optionID == "readme")
    #expect(decoded.directoryPath == "/tmp")
}

@Test("模板总内容不能超出通知承载上限")
func rightClickConfigurationLimitsTotalContent() {
    let templates = (0..<9).map { RightClickTemplate(id: "\($0)", name: "模板", filename: "a.txt", content: String(repeating: "a", count: 32_768)) }
    #expect(throws: RightClickConfigValidationError.self) { try RightClickConfig(enabled: [:], templates: templates).validated() }
}

@Test("保存完整配置后可读取且只在落盘成功后广播")
func rightClickConfigurationPersistsBeforeBroadcasting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rightclick.json")
    let expected = RightClickConfig(enabled: [:], order: ["checksum"], templates: [], applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "org.example.Editor")], destinations: [.init(id: "archive", name: "归档", path: "/tmp")])
    var didNotify = false
    try RightClickConfigStore.save(expected, at: file) { config in
        didNotify = true
        #expect(config == expected)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    #expect(didNotify)
    let reloaded = RightClickConfigStore.load(at: file)
    #expect(reloaded.templates.isEmpty)
    #expect(reloaded.applications == expected.applications)
    #expect(reloaded.destinations == expected.destinations)
    #expect(reloaded.order == expected.order)
    #expect(reloaded.enabledItems.count == RightClickItem.allCases.count)
}

@Test("落盘或配置验证失败时不广播")
func rightClickConfigurationDoesNotBroadcastFailure() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    var didNotify = false
    #expect(throws: (any Error).self) {
        try RightClickConfigStore.save(.default, at: file.appendingPathComponent("child")) { _ in didNotify = true }
    }
    #expect(!didNotify)
    #expect(throws: RightClickConfigValidationError.self) {
        try RightClickConfigStore.save(RightClickConfig(enabled: ["unknown": false]), at: file) { _ in didNotify = true }
    }
    #expect(!didNotify)
}

@Test("损坏缓存使用缺省配置且旧缓存移除未知菜单项")
func rightClickConfigurationRecoversDiskCache() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(RightClickConfigStore.load(at: file) == .default)
    try Data("invalid".utf8).write(to: file)
    #expect(RightClickConfigStore.load(at: file) == .default)
    try Data(#"{"enabled":{"oldRemovedMenu":false,"newFile":false}}"#.utf8).write(to: file)
    let recovered = RightClickConfigStore.load(at: file)
    #expect(recovered.enabled["oldRemovedMenu"] == nil)
    #expect(!recovered.isEnabled(.newFile))
    #expect(recovered.templates == RightClickTemplate.builtIns)
}

@Test("菜单元数据提供稳定标识及对应本地化键")
func rightClickMenuMetadataSupportsSettingsAndExtension() {
    #expect(Set(RightClickItem.allCases.map(\.id)).count == RightClickItem.allCases.count)
    for item in RightClickItem.allCases {
        #expect(RightClickItem(rawValue: item.id) == item)
        #expect(item.titleKey == "rc.item.\(item.id)")
        #expect(item.group.titleKey == "rc.group.\(item.group.id)")
        if let subtitle = item.subtitleKey { #expect(subtitle == item.titleKey + ".desc") }
    }
    #expect(RightClickItem.newFile.group == .directory)
    #expect(RightClickItem.copyAbsolutePath.group == .copy)
    #expect(RightClickItem.checksum.group == .file)
    #expect(RightClickItem.newFile.subtitleKey != nil)
    #expect(RightClickItem.newFolder.subtitleKey == nil)
}

@Test("验证失败提供可展示原因")
func rightClickValidationErrorsHaveDescriptions() {
    let errors: [RightClickConfigValidationError] = [.unknownItem("invalid"), .tooManyEntries("模板"), .duplicateID("same"), .invalidField("文件名称"), .templateContentTooLarge]
    #expect(errors.allSatisfy { !($0.errorDescription?.isEmpty ?? true) })
    #expect(RightClickConfigValidationError.templateContentTooLarge.errorDescription?.contains("32 KiB") == true)
}

@Test("配置拒绝过长排序及非法应用标识")
func rightClickConfigurationRejectsOversizedOrderAndBundleID() {
    let configs = [
        RightClickConfig(enabled: [:], order: Array(repeating: "newFile", count: 129)),
        RightClickConfig(enabled: [:], applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "com.example\nEditor")]),
        RightClickConfig(enabled: [:], applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: String(repeating: "a", count: 256))])
    ]
    for config in configs { #expect(throws: RightClickConfigValidationError.self) { try config.validated() } }
}

@Test("操作指令通知解码拒绝畸形载荷")
func rightClickCommandNotificationDecoding() throws {
    let command = RightClickCommand(action: "checksum", paths: ["/tmp/a.txt"], requestID: "request-1")
    let data = try JSONEncoder().encode(command)
    #expect(RightClickCommandStore.decode(String(data: data, encoding: .utf8)) == command)
    #expect(RightClickCommandStore.decode(nil) == nil)
    for json in ["", "[]", "not-json", #"{"action":"newFile","paths":[null]}"#, #"{"action":true,"paths":[]}"#] {
        #expect(RightClickCommandStore.decode(json) == nil)
    }
}

@Test("磁盘配置验证失败时使用缺省值")
func rightClickConfigurationRejectsInvalidDiskResources() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let invalid = RightClickConfig(enabled: [:], destinations: [.init(id: "destination", name: "目录", path: "relative")])
    try JSONEncoder().encode(invalid).write(to: file)
    #expect(RightClickConfigStore.load(at: file) == .default)
}

@Test("通知拒绝未知排序项且磁盘迁移保留有效排序")
func rightClickConfigurationValidatesAndMigratesOrdering() throws {
    let config = RightClickConfig(enabled: [:], order: ["removedItem", "newFile"])
    #expect(throws: RightClickConfigValidationError.self) { try config.validated() }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try JSONEncoder().encode(config).write(to: file)
    #expect(RightClickConfigStore.load(at: file).order == ["newFile"])
}

@Test("配置接受模板总内容上限")
func rightClickConfigurationAcceptsTotalContentBoundary() throws {
    let templates = (0..<8).map { RightClickTemplate(id: "\($0)", name: "模板", filename: "a.txt", content: String(repeating: "a", count: 32_768)) }
    let config = RightClickConfig(enabled: [:], templates: templates)
    #expect(try config.validated() == config)
}

@Test("模板文件名拒绝冒号而显示名称可以包含冒号")
func rightClickTemplateFilenameRejectsColon() throws {
    let invalid = RightClickConfig(enabled: [:], templates: [.init(id: "colon", name: "配置: JSON", filename: "config:local.json", content: "{}")])
    #expect(throws: RightClickConfigValidationError.self) { try invalid.validated() }
    let valid = RightClickConfig(enabled: [:], templates: [.init(id: "colon", name: "配置: JSON", filename: "config.json", content: "{}")])
    #expect(try valid.validated() == valid)
}

@Test("右键配置错误使用本地化格式与字段名")
func rightClickValidationErrorsLocalizeFormatsAndFields() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
    defer { try? FileManager.default.removeItem(at: directory) }
    let localizedDirectory = directory.appendingPathComponent("en.lproj")
    try FileManager.default.createDirectory(at: localizedDirectory, withIntermediateDirectories: true)
    try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.RightClickTests</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>"#.utf8).write(to: directory.appendingPathComponent("Info.plist"))
    let strings = #"""
    "rc.config.unknownItem" = "Unknown menu item: %@";
    "rc.config.tooManyEntries" = "Too many %@.";
    "rc.config.duplicateID" = "Duplicate identifier.";
    "rc.config.invalidField" = "Invalid %@.";
    "rc.config.templateContentTooLarge" = "Limit %@ per template and %@ total.";
    "rc.config.field.templates" = "templates";
    "rc.config.field.filename" = "filename";
    """#
    try Data(strings.utf8).write(to: localizedDirectory.appendingPathComponent("Localizable.strings"))
    let bundle = try #require(Bundle(path: directory.path))
    #expect(RightClickConfigValidationError.unknownItem("newFile").localizedDescription(in: bundle) == "Unknown menu item: newFile")
    #expect(RightClickConfigValidationError.tooManyEntries("rc.config.field.templates").localizedDescription(in: bundle) == "Too many templates.")
    #expect(RightClickConfigValidationError.duplicateID("id").localizedDescription(in: bundle) == "Duplicate identifier.")
    #expect(RightClickConfigValidationError.invalidField("rc.config.field.filename").localizedDescription(in: bundle) == "Invalid filename.")
    #expect(RightClickConfigValidationError.templateContentTooLarge.localizedDescription(in: bundle) == "Limit 32 KiB per template and 256 KiB total.")

    let invalid = RightClickConfig(enabled: [:], templates: [.init(id: "test", name: "模板", filename: "test:name", content: "")])
    do {
        _ = try invalid.validated()
        Issue.record("无效文件名称应返回本地化验证错误")
    } catch let error as RightClickConfigValidationError {
        #expect(error.localizedDescription(in: bundle) == "Invalid filename.")
    }
}
