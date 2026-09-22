import Foundation
import Testing
@testable import MenuTools

@Test("存储分析递归统计文件大小")
func storageAnalyzerCountsNestedFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsStorageTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = root.appendingPathComponent("one.bin")
    try Data(repeating: 1, count: 12).write(to: first)
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let second = nested.appendingPathComponent("two.bin")
    try Data(repeating: 2, count: 8).write(to: second)

    #expect(StorageAnalysisCalculator.directorySize(at: root) == allocatedSize(of: first) + allocatedSize(of: second))
}

@Test("存储分析按实际占用统计，DerivedData 快捷卡可复用同一结果")
func storageAnalyzerCountsAllocatedBytes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsAllocatedStorageTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = root.appendingPathComponent("one.bin")
    let second = root.appendingPathComponent("two.bin")
    try Data(repeating: 1, count: 12).write(to: first)
    try Data(repeating: 2, count: 8).write(to: second)

    let expected = allocatedSize(of: first) + allocatedSize(of: second)
    #expect(StorageAnalysisCalculator.directorySize(at: root) == expected)
    #expect(expected > 20)
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

private func allocatedSize(of url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
    return Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0)
}

@Test("系统存储清理仅允许已审核目录")
func storageCleanupOnlyAllowsAuditedDirectory() {
    #expect(StorageCategory.derivedData.isSafeToClean)
    #expect(!StorageCategory.caches.isSafeToClean)
    #expect(!StorageCategory.logs.isSafeToClean)
    #expect(!StorageCategory.downloads.isSafeToClean)
}

@Test("系统存储卷总览读取可用与总容量")
func storageVolumeOverviewReadsCapacity() {
    let overview = StorageAnalysisCalculator.volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser)

    #expect(overview.totalBytes > 0)
    #expect(overview.availableBytes >= 0)
    #expect(overview.availableBytes <= overview.totalBytes)
}

@Test("Xcode 运行时禁止清理 DerivedData")
func storageCleanupDefersWhileXcodeIsRunning() {
    #expect(!StorageCleanupPolicy.canClean(.derivedData, isXcodeRunning: true))
    #expect(StorageCleanupPolicy.canClean(.derivedData, isXcodeRunning: false))
    #expect(!StorageCleanupPolicy.canClean(.caches, isXcodeRunning: false))
}

@Test("新一代存储扫描会拒绝旧结果回写")
func storageScanGenerationRejectsStaleResults() {
    var generation = StorageScanGeneration()
    let first = generation.begin()
    let second = generation.begin()

    #expect(!generation.accepts(first))
    #expect(generation.accepts(second))
    generation.invalidate()
    #expect(!generation.accepts(second))
}

@Test("清理路径必须位于白名单根目录且不含符号链接")
func storageCleanupPathValidationRejectsEscapesAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsStoragePathTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let allowed = root.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)

    try StorageCleanupPathPolicy.validate(allowed, allowedRoot: allowed, homeDirectory: root)

    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    #expect(throws: StorageAnalysisError.self) {
        try StorageCleanupPathPolicy.validate(outside, allowedRoot: allowed, homeDirectory: root)
    }

    let linked = root.appendingPathComponent("LinkedDerivedData", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: allowed)
    #expect(throws: StorageAnalysisError.self) {
        try StorageCleanupPathPolicy.validate(linked, allowedRoot: linked, homeDirectory: root)
    }
}

@Test("清理确认保留明确路径与预计释放容量")
func storageCleanupPreviewIncludesPathAndReclaimableBytes() {
    let preview = StorageCleanupPreview(category: .derivedData, reclaimableBytes: 4_096)

    #expect(preview.path == StorageCategory.derivedData.directoryURL.path)
    #expect(preview.reclaimableBytes == 4_096)
}

@Test("服务只发布最新一代扫描结果")
@MainActor
func storageServicePublishesNewestScanOnly() async throws {
    let older = StorageAnalysisSnapshot(
        entries: [],
        volume: StorageVolumeOverview(totalBytes: 100, availableBytes: 10)
    )
    let newer = StorageAnalysisSnapshot(
        entries: [],
        volume: StorageVolumeOverview(totalBytes: 100, availableBytes: 90)
    )
    let loader = DelayedStorageSnapshotLoader(first: older, subsequent: newer)
    let service = StorageAnalysisService(snapshotLoader: loader.load)

    service.refresh()
    try await Task.sleep(for: .milliseconds(20))
    service.refresh()
    try await Task.sleep(for: .milliseconds(180))

    #expect(service.snapshot == newer)
    #expect(!service.isLoading)
}

private final class DelayedStorageSnapshotLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let first: StorageAnalysisSnapshot
    private let subsequent: StorageAnalysisSnapshot

    init(first: StorageAnalysisSnapshot, subsequent: StorageAnalysisSnapshot) {
        self.first = first
        self.subsequent = subsequent
    }

    func load() -> StorageAnalysisSnapshot {
        lock.lock()
        callCount += 1
        let isFirst = callCount == 1
        lock.unlock()
        if isFirst {
            Thread.sleep(forTimeInterval: 0.12)
            return first
        }
        return subsequent
    }
}
