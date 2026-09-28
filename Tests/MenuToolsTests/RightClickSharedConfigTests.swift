import Foundation
import Testing
@testable import MenuTools

@Test("右键配置文件名固定在应用支持目录的 MenuTools 子目录")
func rightClickConfigUsesApplicationSupportDirectory() {
    let base = URL(fileURLWithPath: "/tmp/MenuToolsBase")
    #expect(RightClickConfigStore.configFileURL(inBaseDirectory: base).path
            == "/tmp/MenuToolsBase/MenuTools/rightclick.json")
    #expect(RightClickConfigStore.appGroupIdentifier == "group.com.qoder.menutools")
}

@Test("只有真正可写的目录才会被选中")
func rightClickConfigPrefersWritableDirectory() throws {
    try withSharedConfigDirectory { directory in
        let writable = directory.appendingPathComponent("group")
        let fileNotDirectory = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: fileNotDirectory)

        // 伪造的候选目录（其实是一个文件）必须被跳过，而不是让写入在运行期失败。
        #expect(!RightClickConfigStore.isWritableDirectory(fileNotDirectory))
        #expect(RightClickConfigStore.writableBaseDirectory(candidates: [fileNotDirectory, writable])?.path
                == writable.path)
        #expect(RightClickConfigStore.isWritableDirectory(writable))
        // 探针文件必须被清理，不能留在配置目录里。
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: writable.appendingPathComponent("MenuTools").path)
        #expect(leftovers.isEmpty)
    }
}

@Test("没有可写候选目录时返回 nil")
func rightClickConfigReportsNoWritableCandidate() throws {
    try withSharedConfigDirectory { directory in
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        #expect(RightClickConfigStore.writableBaseDirectory(candidates: [blocked]) == nil)
    }
}

@Test("当前进程的配置目录始终可解析")
func rightClickConfigResolvesCurrentProcessDirectory() {
    let base = RightClickConfigStore.resolveBaseDirectory()
    #expect(RightClickConfigStore.isWritableDirectory(base))
    #expect(RightClickConfigStore.fileURL.path.hasSuffix("/MenuTools/rightclick.json"))
}

@Test("旧路径配置迁移到当前目录且不覆盖已有文件")
func rightClickConfigMigratesLegacyFile() throws {
    try withSharedConfigDirectory { directory in
        let legacy = directory.appendingPathComponent("legacy/rightclick.json")
        let shared = directory.appendingPathComponent("group/MenuTools/rightclick.json")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = RightClickConfig(
            enabled: [RightClickItem.newFile.rawValue: false], order: ["checksum"], templates: [])
        try JSONEncoder().encode(expected).write(to: legacy)

        RightClickConfigStore.migrateConfig(from: legacy, to: shared)
        let migrated = RightClickConfigStore.load(at: shared)
        #expect(migrated.enabled[RightClickItem.newFile.rawValue] == false)
        #expect(migrated.order == ["checksum"])
        #expect(migrated.templates.isEmpty)

        // 目标已有配置时，旧缓存不得覆盖用户当前设置。
        let current = RightClickConfig(
            enabled: [RightClickItem.newFile.rawValue: true], order: ["newFolder"], templates: [])
        try RightClickConfigStore.replace(current, at: shared)
        RightClickConfigStore.migrateConfig(from: legacy, to: shared)
        let reloaded = RightClickConfigStore.load(at: shared)
        #expect(reloaded.enabled[RightClickItem.newFile.rawValue] == true)
        #expect(reloaded.order == ["newFolder"])
    }
}

@Test("没有旧配置时不创建目标文件")
func rightClickConfigSkipsMigrationWithoutLegacyFile() throws {
    try withSharedConfigDirectory { directory in
        let legacy = directory.appendingPathComponent("legacy/rightclick.json")
        let shared = directory.appendingPathComponent("group/MenuTools/rightclick.json")
        RightClickConfigStore.migrateConfig(from: legacy, to: shared)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
    }
}

@Test("迁移对同一路径是空操作")
func rightClickConfigMigrationIsNoOpForSamePath() throws {
    try withSharedConfigDirectory { directory in
        let shared = directory.appendingPathComponent("group/MenuTools/rightclick.json")
        try RightClickConfigStore.replace(.default, at: shared)
        RightClickConfigStore.migrateConfig(from: shared, to: shared)
        #expect(RightClickConfigStore.load(at: shared) == .default)
    }
}

private func withSharedConfigDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-SharedConfig-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test("通道令牌只生成一次并只有当前用户可读")
func channelSecretIsGeneratedOnceAndPrivate() throws {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("ChannelSecret-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: base) }

    #expect(RightClickChannelSecret.load(inBaseDirectory: base) == nil)

    let created = try #require(
        RightClickChannelSecret.loadOrCreate(inBaseDirectory: base, fileManager: fileManager)
    )
    #expect(created.count == RightClickChannelSecret.tokenByteCount * 2)

    // 二次调用必须返回同一个令牌，否则扩展与宿主会各说各话
    #expect(RightClickChannelSecret.loadOrCreate(inBaseDirectory: base, fileManager: fileManager) == created)
    #expect(RightClickChannelSecret.load(inBaseDirectory: base, fileManager: fileManager) == created)

    let url = RightClickChannelSecret.secretFileURL(inBaseDirectory: base)
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o600)
}

@Test("令牌比较拒绝缺失、空值与长度不同的输入")
func channelSecretMatchingRejectsSpoofs() {
    #expect(RightClickChannelSecret.matches("abc", expected: "abc"))
    #expect(!RightClickChannelSecret.matches(nil, expected: "abc"))
    #expect(!RightClickChannelSecret.matches("", expected: "abc"))
    #expect(!RightClickChannelSecret.matches("abcd", expected: "abc"))
    #expect(!RightClickChannelSecret.matches("abd", expected: "abc"))
    // 宿主读不到令牌时一律拒绝（fail closed）
    #expect(!RightClickCommandStore.isAuthentic(
        RightClickCommand(action: "copyFilename", paths: ["/tmp/a"]),
        secret: nil
    ))
}

@Test("命令载荷必须带正确令牌才算可信")
func commandAuthenticityRequiresToken() throws {
    let command = RightClickCommand(action: "copyFilename", paths: ["/tmp/a"])
    let authenticated = RightClickCommandStore.authenticated(command, secret: "secret-token")

    #expect(authenticated.channelToken == "secret-token")
    #expect(RightClickCommandStore.isAuthentic(authenticated, secret: "secret-token"))
    #expect(!RightClickCommandStore.isAuthentic(authenticated, secret: "other-token"))
    // 没有令牌的裸命令（任意进程都能伪造出来的那种）必须被拒
    #expect(!RightClickCommandStore.isAuthentic(command, secret: "secret-token"))

    // 令牌要随 JSON 一起传输
    let json = try JSONEncoder().encode(authenticated)
    let decoded = try JSONDecoder().decode(RightClickCommand.self, from: json)
    #expect(RightClickCommandStore.isAuthentic(decoded, secret: "secret-token"))
}
