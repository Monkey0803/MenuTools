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

@Test("存储扫描缓存会保存快照和完成时间")
func storageAnalysisCacheRoundTripsSnapshotAndDate() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsStorageCache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let result = StorageAnalysisCachedResult(
        snapshot: StorageAnalysisSnapshot(
            entries: [.init(category: .downloads, bytes: 4_096, exists: true)],
            volume: .init(totalBytes: 10_000, availableBytes: 6_000)
        ),
        scanDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    try StorageAnalysisCacheStore.save(result, at: url)

    #expect(StorageAnalysisCacheStore.load(at: url) == result)
}

@Test("服务会先展示缓存快照，再后台替换为新扫描结果")
@MainActor
func storageServiceShowsCachedSnapshotBeforeRefresh() async throws {
    let cachedSnapshot = StorageAnalysisSnapshot(
        entries: [.init(category: .downloads, bytes: 1_000, exists: true)],
        volume: .init(totalBytes: 10_000, availableBytes: 7_000)
    )
    let freshSnapshot = StorageAnalysisSnapshot(
        entries: [.init(category: .downloads, bytes: 2_000, exists: true)],
        volume: .init(totalBytes: 10_000, availableBytes: 6_000)
    )
    let cached = StorageAnalysisCachedResult(
        snapshot: cachedSnapshot,
        scanDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let service = StorageAnalysisService(cachedResult: cached, snapshotLoader: {
        Thread.sleep(forTimeInterval: 0.12)
        return freshSnapshot
    })

    #expect(service.snapshot == cachedSnapshot)
    #expect(service.lastScanDate == cached.scanDate)
    #expect(!service.isLoading)

    service.refresh()
    try await Task.sleep(for: .milliseconds(30))

    #expect(service.snapshot == cachedSnapshot)
    #expect(service.isLoading)

    try await Task.sleep(for: .milliseconds(150))

    #expect(service.snapshot == freshSnapshot)
    #expect(service.lastScanDate != cached.scanDate)
}

@Test("同一存储服务在扫描中忽略重复刷新请求")
@MainActor
func storageServiceCoalescesConcurrentRefreshRequests() async throws {
    let counter = StorageScanInvocationCounter()
    let result = StorageAnalysisSnapshot(
        entries: [],
        volume: .init(totalBytes: 10_000, availableBytes: 6_000)
    )
    let service = StorageAnalysisService(snapshotLoader: {
        counter.increment()
        Thread.sleep(forTimeInterval: 0.12)
        return result
    })

    service.refresh()
    service.refresh()
    for _ in 0..<750 where counter.count == 0 {
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(counter.count == 1)
}

@Test("分批扫描会在完成前发布可用的部分结果")
@MainActor
func storageServicePublishesPartialResultsDuringRefresh() async throws {
    let partial = StorageAnalysisSnapshot(
        entries: [.init(category: .derivedData, bytes: 1_000, exists: true)],
        volume: .init(totalBytes: 10_000, availableBytes: 8_000)
    )
    let completed = StorageAnalysisSnapshot(
        entries: [.init(category: .derivedData, bytes: 2_000, exists: true)],
        volume: .init(totalBytes: 10_000, availableBytes: 7_000)
    )
    let gate = StoragePartialScanGate()
    let service = StorageAnalysisService(progressiveSnapshotLoader: { _, reportPartial, isCancelled in
        reportPartial(partial)
        gate.waitForRelease()
        return isCancelled() ? nil : completed
    })

    service.refresh()
    for _ in 0..<750 where service.snapshot != partial {
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(service.snapshot == partial)
    #expect(service.isLoading)

    gate.release()
    for _ in 0..<750 where service.snapshot != completed {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(service.snapshot == completed)
    #expect(!service.isLoading)
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

private final class StoragePartialScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func waitForRelease() {
        condition.lock()
        defer { condition.unlock() }
        while !released {
            condition.wait(until: .now.addingTimeInterval(15))
            if !released { break }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class StorageDeveloperBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func record(_ items: [StorageDeveloperItem]) {
        lock.lock()
        if !items.isEmpty { count += 1 }
        lock.unlock()
    }
}

private final class StorageScanInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Test("开发者目录分别纳入分析，并只允许经过审核的目录清理")
func storageCategoriesSeparateDeveloperDirectories() {
    #expect(StorageCategory.developerFiles == [.derivedData, .xcodeArchives, .iOSDeviceSupport, .coreSimulator])
    #expect(StorageCategory.xcodeArchives.isSafeToClean)
    #expect(StorageCategory.iOSDeviceSupport.isSafeToClean)
    #expect(!StorageCategory.coreSimulator.isSafeToClean)
    #expect(StorageCategory.coreSimulator.requiresManualReview)
}

@Test("存储快照按占用排序，并只建议长期未使用的开发者文件和下载文件")
func storageSnapshotSortsAndBuildsReadOnlyRecommendations() {
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let old = now.addingTimeInterval(-31 * 24 * 60 * 60)
    let current = now.addingTimeInterval(-2 * 24 * 60 * 60)
    let snapshot = StorageAnalysisSnapshot(
        entries: [
            StorageDirectoryInfo(category: .downloads, bytes: 3_000, exists: true, lastModified: old),
            StorageDirectoryInfo(category: .derivedData, bytes: 1_000, exists: true, lastModified: current),
            StorageDirectoryInfo(category: .xcodeArchives, bytes: 2_000, exists: true, lastModified: old)
        ],
        volume: StorageVolumeOverview(totalBytes: 10_000, availableBytes: 5_000)
    )

    #expect(snapshot.sortedEntries.map(\.category) == [.downloads, .xcodeArchives, .derivedData])
    let recommendations = StorageAnalysisCalculator.recommendations(for: snapshot.entries, now: now)
    #expect(recommendations.map(\.category) == [.downloads, .xcodeArchives])
    #expect(recommendations.allSatisfy { $0.isReadOnly })
}

@Test("取消存储扫描后不会发布已取消的结果")
@MainActor
func storageServiceCancelsRefreshWithoutPublishingResult() async throws {
    let snapshot = StorageAnalysisSnapshot(
        entries: [],
        volume: StorageVolumeOverview(totalBytes: 100, availableBytes: 50)
    )
    let loader = DelayedStorageSnapshotLoader(first: snapshot, subsequent: snapshot)
    let service = StorageAnalysisService(snapshotLoader: loader.load)

    service.refresh()
    try await Task.sleep(for: .milliseconds(20))
    service.cancelRefresh()
    try await Task.sleep(for: .milliseconds(180))

    #expect(service.snapshot == nil)
    #expect(!service.isLoading)
    #expect(service.lastScanWasCancelled)
}

@Test("经过审核的开发目录通过白名单校验，CoreSimulator 保持只读")
func storageCleanupAllowlistCoversDeveloperDirectories() throws {
    try StorageCleanupPathPolicy.validate(category: .derivedData)
    try StorageCleanupPathPolicy.validate(category: .xcodeArchives)
    try StorageCleanupPathPolicy.validate(category: .iOSDeviceSupport)
    #expect(throws: StorageAnalysisError.unsafeCategory) {
        try StorageCleanupPathPolicy.validate(category: .coreSimulator)
    }
}

@Test("扫描取消令牌可跨后台任务安全传递")
func storageScanCancellationTokenStopsWorker() {
    let token = StorageScanCancellationToken()
    #expect(!token.isCancelled)
    token.cancel()
    #expect(token.isCancelled)
}

@Test("开发者目录细分为可独立清理的项目，并保留实际占用与项目名")
func storageDeveloperItemsSplitDerivedDataByProject() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsDeveloperItems-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let alpha = root.appendingPathComponent("Alpha-0123456789abcdef", isDirectory: true)
    let beta = root.appendingPathComponent("Beta-abcdef0123456789", isDirectory: true)
    let gamma = root.appendingPathComponent("Gamma-avkpvhrnhlfdivguqaetwgmebmjy", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gamma, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8_192).write(to: alpha.appendingPathComponent("build.bin"))
    try Data(repeating: 2, count: 20_480).write(to: beta.appendingPathComponent("index.bin"))
    try Data(repeating: 3, count: 4_096).write(to: gamma.appendingPathComponent("index.bin"))

    let items = try #require(StorageAnalysisCalculator.developerItems(at: root, category: .derivedData))

    #expect(items.map(\.title) == ["Beta", "Alpha", "Gamma"])
    #expect(items.map(\.bytes) == [
        allocatedSize(of: beta.appendingPathComponent("index.bin")),
        allocatedSize(of: alpha.appendingPathComponent("build.bin")),
        allocatedSize(of: gamma.appendingPathComponent("index.bin"))
    ])
    #expect(items.allSatisfy { $0.category == .derivedData })
}

@Test("大型开发目录会在统计完成前分批发布项目结果")
func storageDeveloperItemsPublishBatchesForLargeDirectories() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsDeveloperBatches-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("Project-0123456789abcdef", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<500 {
        try Data([UInt8(index % 255)]).write(to: project.appendingPathComponent("\(index).bin"))
    }
    let collector = StorageDeveloperBatchCollector()

    let items = StorageAnalysisCalculator.developerItems(
        at: root,
        category: .derivedData,
        onBatch: { collector.record($0) }
    )

    #expect(items?.count == 1)
    #expect(collector.count >= 2)
}

@Test("归档细分为日期下的单个 xcarchive")
func storageDeveloperItemsSplitArchivesByDateAndArchive() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsArchiveItems-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let date = root.appendingPathComponent("2026-09-22", isDirectory: true)
    let archive = date.appendingPathComponent("MenuTools.xcarchive", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 48).write(to: archive.appendingPathComponent("Info.plist"))

    let items = try #require(StorageAnalysisCalculator.developerItems(at: root, category: .xcodeArchives))

    #expect(items.count == 1)
    #expect(items[0].title == "MenuTools")
    #expect(items[0].relativePath == "2026-09-22/MenuTools.xcarchive")
    #expect(items[0].bytes == allocatedSize(of: archive.appendingPathComponent("Info.plist")))
}

@Test("细分清理路径只能位于对应开发目录，且不能把根目录作为项目删除")
func storageDeveloperItemPathValidationRejectsRootAndEscapes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsDeveloperItemPath-\(UUID().uuidString)", isDirectory: true)
    let item = root.appendingPathComponent("Project-0123456789abcdef", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsDeveloperItemOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    try StorageCleanupPathPolicy.validateItem(item, allowedRoot: root, homeDirectory: root.deletingLastPathComponent())
    #expect(throws: StorageAnalysisError.unsafePath) {
        try StorageCleanupPathPolicy.validateItem(root, allowedRoot: root, homeDirectory: root.deletingLastPathComponent())
    }
    #expect(throws: StorageAnalysisError.unsafePath) {
        try StorageCleanupPathPolicy.validateItem(outside, allowedRoot: root, homeDirectory: root.deletingLastPathComponent())
    }
}

@Test("细分清理只删除用户选中的项目")
func storageDeveloperItemCleanupRemovesOnlySelection() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsDeveloperItemCleanup-\(UUID().uuidString)", isDirectory: true)
    let selectedURL = root.appendingPathComponent("Selected-0123456789abcdef", isDirectory: true)
    let keptURL = root.appendingPathComponent("Kept-0123456789abcdef", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: keptURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 4_096).write(to: selectedURL.appendingPathComponent("build.bin"))
    try Data(repeating: 2, count: 4_096).write(to: keptURL.appendingPathComponent("build.bin"))

    let selected = StorageDeveloperItem(
        category: .derivedData,
        title: "Selected",
        relativePath: selectedURL.lastPathComponent,
        directoryURL: selectedURL,
        bytes: StorageAnalysisCalculator.directorySize(at: selectedURL),
        lastModified: nil,
        accessIssue: nil
    )

    try StorageAnalysisCalculator.clean(
        [selected],
        allowedRoot: root,
        homeDirectory: root.deletingLastPathComponent()
    )

    #expect(!FileManager.default.fileExists(atPath: selectedURL.path))
    #expect(FileManager.default.fileExists(atPath: keptURL.path))
}

@Test("CoreSimulator 分析拆分运行时、设备数据、App 数据和缓存")
func storageSimulatorBreakdownSeparatesKinds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MenuToolsSimulator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = root.appendingPathComponent("Profiles/Runtimes/iOS.simruntime", isDirectory: true)
    let app = root.appendingPathComponent("Devices/A/data/Containers/Data/Application/App", isDirectory: true)
    let device = root.appendingPathComponent("Devices/A/data/Library", isDirectory: true)
    let cache = root.appendingPathComponent("Caches/Cache", isDirectory: true)
    for url in [runtime, app, device, cache] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    try Data(repeating: 1, count: 4096).write(to: runtime.appendingPathComponent("runtime.bin"))
    try Data(repeating: 1, count: 8192).write(to: app.appendingPathComponent("app.bin"))
    try Data(repeating: 1, count: 4096).write(to: device.appendingPathComponent("device.bin"))
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("cache.bin"))

    let items = StorageAnalysisCalculator.simulatorBreakdown(at: root)
    #expect(Set(items.map(\.kind)) == [.runtime, .deviceData, .appData, .cache])
    #expect((items.first(where: { $0.kind == .appData })?.bytes ?? 0) > 0)
}

@Test("大文件视图限制二十项，并按修改日期筛选长期未使用文件")
func storageLargeFilesLimitsAndFiltersStaleItems() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MenuToolsLargeFiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = Date.now.addingTimeInterval(-40 * 24 * 60 * 60)
    for index in 0..<22 {
        let file = root.appendingPathComponent("\(index).bin")
        try Data(repeating: UInt8(index), count: (index + 1) * 4096).write(to: file)
        if index < 2 { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path) }
    }
    let largest = StorageAnalysisCalculator.largeFiles(at: root, category: .downloads, mode: .largest)
    let stale = StorageAnalysisCalculator.largeFiles(at: root, category: .downloads, mode: .stale)
    #expect(largest.count == 20)
    #expect(largest.first?.bytes ?? 0 > largest.last?.bytes ?? 0)
    #expect(stale.count == 2)
}

@Test("取消令牌会中止大文件与模拟器补充分析")
func storageSupplementalAnalysisHonorsCancellation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsCancelledStorage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 4_096).write(to: root.appendingPathComponent("file.bin"))

    let token = StorageScanCancellationToken()
    token.cancel()
    #expect(StorageAnalysisCalculator.largeFiles(
        at: root,
        category: .downloads,
        isCancelled: { token.isCancelled }
    ).isEmpty)
    #expect(StorageAnalysisCalculator.simulatorBreakdown(
        at: root,
        isCancelled: { token.isCancelled }
    ).isEmpty)
}
