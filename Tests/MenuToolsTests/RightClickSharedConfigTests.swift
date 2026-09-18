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
