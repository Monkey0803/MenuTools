import Foundation
import Testing
@testable import MenuTools

@Test("存储分析递归统计文件大小")
func storageAnalyzerCountsNestedFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsStorageTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(repeating: 1, count: 12).write(to: root.appendingPathComponent("one.bin"))
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 8).write(to: nested.appendingPathComponent("two.bin"))

    #expect(StorageAnalysisCalculator.directorySize(at: root) == 20)
}

@Test("存储分析不会删除分析目录本身")
func storageAnalyzerCleanupKeepsRootDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsStorageCleanupTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 4).write(to: root.appendingPathComponent("cache.bin"))

    try StorageAnalysisCalculator.cleanContents(of: root)

    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(StorageAnalysisCalculator.directorySize(at: root) == 0)
}
