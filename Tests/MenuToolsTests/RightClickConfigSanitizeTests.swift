import Foundation
import Testing
@testable import MenuTools

@Test("损坏的单个条目不会连带丢弃其余设置")
func rightClickSanitizeKeepsHealthyEntries() throws {
    let config = RightClickConfig(
        enabled: ["unknownItem": true, RightClickItem.checksum.rawValue: false],
        order: ["removedItem", RightClickItem.openWithApp.rawValue],
        templates: [
            .init(id: "good", name: "模板", filename: "a.txt", content: "ok"),
            .init(id: "bad", name: "模板", filename: "a/b", content: "broken")
        ],
        applications: [
            .init(id: "editor", name: "编辑器", path: "/Applications/Editor.app", bundleIdentifier: "org.example.Editor"),
            .init(id: "broken", name: "损坏", path: "relative/Editor.app", bundleIdentifier: "x")
        ],
        destinations: [
            .init(id: "dest", name: "归档", path: "/tmp/archive"),
            .init(id: "broken", name: "损坏", path: "relative")
        ])

    let sanitized = config.sanitized()

    #expect(sanitized.enabled["unknownItem"] == nil)
    #expect(sanitized.enabled[RightClickItem.checksum.rawValue] == false)
    #expect(sanitized.enabled[RightClickItem.newFolder.rawValue] == true)
    #expect(sanitized.order == [RightClickItem.openWithApp.rawValue])
    #expect(sanitized.templates.map(\.id) == ["good"])
    #expect(sanitized.applications.map(\.id) == ["editor"])
    #expect(sanitized.destinations.map(\.id) == ["dest"])
}

@Test("逐项降级丢弃重复 ID 与非法模板内容")
func rightClickSanitizeRejectsDuplicatesAndOversizedContent() {
    let config = RightClickConfig(
        enabled: [:],
        templates: [
            .init(id: "same", name: "模板", filename: "a.txt", content: ""),
            .init(id: "same", name: "模板", filename: "b.txt", content: ""),
            .init(id: "", name: "模板", filename: "c.txt", content: ""),
            .init(id: "huge", name: "模板", filename: "d.txt",
                  content: String(repeating: "a", count: 32_769))
        ],
        applications: [
            .init(id: "same", name: "编辑器", path: "/Applications/A.app", bundleIdentifier: "a"),
            .init(id: "same", name: "编辑器", path: "/Applications/B.app", bundleIdentifier: "b")
        ])

    let sanitized = config.sanitized()

    #expect(sanitized.templates.map(\.id) == ["same"])
    #expect(sanitized.applications.map(\.id) == ["same"])
    #expect(sanitized.applications.first?.path == "/Applications/A.app")
}

@Test("目录清单越界数值夹取回可用范围")
func rightClickSanitizeClampsListingOptions() {
    let config = RightClickConfig(
        enabled: [:],
        directoryListing: .init(
            includeHidden: true, maxDepth: 999,
            ignoredPatterns: ["", ".git", "*.tmp", String(repeating: "a", count: 129)]))
    let sanitized = config.sanitized()

    #expect(sanitized.directoryListing.includeHidden)
    #expect(sanitized.directoryListing.maxDepth == 50)
    #expect(sanitized.directoryListing.ignoredPatterns == [".git", "*.tmp"])
    #expect(sanitized.directoryListing != config.directoryListing)

    let negative = RightClickConfig(enabled: [:],
                                    directoryListing: .init(includeHidden: false, maxDepth: -5, ignoredPatterns: []))
    #expect(negative.sanitized().directoryListing.maxDepth == 0)
}

@Test("磁盘缓存只有损坏条目被丢弃")
func rightClickSanitizeLoadKeepsUserConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("rightclick.json")
    let expected = RightClickConfig(
        enabled: [RightClickItem.checksum.rawValue: false],
        order: [RightClickItem.openWithApp.rawValue],
        templates: [.init(id: "good", name: "模板", filename: "a.txt", content: "ok")],
        applications: [.init(id: "editor", name: "编辑器", path: "/Applications/Editor.app",
                             bundleIdentifier: "org.example.Editor")],
        destinations: [.init(id: "dest", name: "归档", path: "/tmp/archive")],
        menuStyle: .flat)
    var broken = expected
    broken.templates.append(.init(id: "bad", name: "模板", filename: "../escape.txt", content: ""))
    try JSONEncoder().encode(broken).write(to: file, options: .atomic)

    let loaded = RightClickConfigStore.load(at: file)

    #expect(loaded != .default)
    #expect(loaded.templates.map(\.id) == ["good"])
    #expect(loaded.applications == expected.applications)
    #expect(loaded.destinations == expected.destinations)
    #expect(loaded.order == expected.order)
    #expect(loaded.isEnabled(.checksum) == false)
    #expect(loaded.menuStyle == .flat)
}

@Test("完全损坏的缓存仍然回退默认配置")
func rightClickSanitizeFallsBackForUnreadableCache() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("rightclick.json")
    try Data("not json".utf8).write(to: file)
    #expect(RightClickConfigStore.load(at: file) == .default)
    try Data(#"{"enabled":[]}"#.utf8).write(to: file)
    #expect(RightClickConfigStore.load(at: file) == .default)
}
