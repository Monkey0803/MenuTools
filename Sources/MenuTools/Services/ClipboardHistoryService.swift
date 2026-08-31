import AppKit
import Foundation
import Observation

struct ClipboardHistoryFile: Codable, Equatable, Sendable, Identifiable {
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }
}

/// 剪贴板历史中的内容；图片使用 TIFF 数据保存，避免把 NSImage 带入并发边界。
enum ClipboardHistoryContent: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)
    case url(String)
    case files([ClipboardHistoryFile])

    private enum CodingKeys: String, CodingKey {
        case text
        case image
        case url
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let image = try container.decodeIfPresent(Data.self, forKey: .image) {
            self = .image(image)
        } else if let url = try container.decodeIfPresent(String.self, forKey: .url) {
            self = .url(url)
        } else if let files = try container.decodeIfPresent([ClipboardHistoryFile].self, forKey: .files) {
            self = .files(files)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "剪贴板历史内容缺少有效的文本或图片数据"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(text, forKey: .text)
        case let .image(image):
            try container.encode(image, forKey: .image)
        case let .url(url):
            try container.encode(url, forKey: .url)
        case let .files(files):
            try container.encode(files, forKey: .files)
        }
    }

    var searchableText: String? {
        switch self {
        case let .text(text), let .url(text):
            text
        case let .files(files):
            files.map { "\($0.displayName) \($0.path)" }.joined(separator: " ")
        case .image:
            nil
        }
    }
}

/// 将系统剪贴板项目转换为历史记录内容。
enum ClipboardHistoryPasteboardReader {
    static func content(from items: [NSPasteboardItem]) -> ClipboardHistoryContent? {
        let files = items.compactMap { item -> ClipboardHistoryFile? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else {
                return nil
            }
            return ClipboardHistoryFile(path: url.path)
        }
        if !files.isEmpty {
            return .files(files)
        }

        guard let item = items.first else { return nil }
        if let urlValue = item.string(forType: .URL),
           let url = URL(string: urlValue),
           !url.isFileURL {
            return .url(url.absoluteString)
        }
        if let text = item.string(forType: .string) {
            if let url = URL(string: text),
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                return .url(url.absoluteString)
            }
            return .text(text)
        }
        // screencapture -c 在不同 macOS 版本可能写入 PNG 或 TIFF。
        if let data = item.data(forType: .png) {
            return .image(data)
        }
        if let data = item.data(forType: .tiff) {
            return .image(data)
        }
        return nil
    }

    static func content(from item: NSPasteboardItem) -> ClipboardHistoryContent? {
        content(from: [item])
    }
}

/// 图片历史记录统一以 TIFF 写回系统剪贴板，避免内容字节与声明类型不一致。
enum ClipboardHistoryImageData {
    static func tiffData(from data: Data) -> Data? {
        NSImage(data: data)?.tiffRepresentation
    }
}

enum ClipboardHistoryRecordingPolicy {
    static func shouldRecord(
        isPaused: Bool,
        sourceBundleID: String?,
        excludedBundleIDs: [String]
    ) -> Bool {
        guard !isPaused else { return false }
        guard let sourceBundleID else { return true }
        return !excludedBundleIDs.contains(sourceBundleID)
    }
}

/// 可在设置中选择的剪贴板历史容量。
enum ClipboardHistoryLimit: Int, CaseIterable, Identifiable {
    case twenty = 20
    case fifty = 50
    case hundred = 100
    case twoHundred = 200

    static let defaultValue = ClipboardHistoryLimit.fifty.rawValue

    var id: Int { rawValue }

    static var storedValue: Int {
        let stored = UserDefaults.standard.object(forKey: SettingsKey.clipboardHistoryLimit) as? Int
        return ClipboardHistoryLimit(rawValue: stored ?? defaultValue)?.rawValue ?? defaultValue
    }
}

/// 剪贴板历史内容分类。
enum ClipboardHistoryCategory: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case url
    case file

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "clipboard.category.all"
        case .text: return "clipboard.category.text"
        case .image: return "clipboard.category.image"
        case .url: return "clipboard.category.url"
        case .file: return "clipboard.category.file"
        }
    }

    fileprivate func contains(_ content: ClipboardHistoryContent) -> Bool {
        switch (self, content) {
        case (.all, _), (.text, .text), (.image, .image), (.url, .url), (.file, .files):
            return true
        case (.text, .image), (.text, .url), (.text, .files),
             (.image, .text), (.image, .url), (.image, .files),
             (.url, .text), (.url, .image), (.url, .files),
             (.file, .text), (.file, .image), (.file, .url):
            return false
        }
    }
}

/// 剪贴板历史列表的展示排序。
enum ClipboardHistorySortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .newestFirst: return "clipboard.sort.newest"
        case .oldestFirst: return "clipboard.sort.oldest"
        }
    }
}

/// 设置页和快捷面板共用的历史筛选与排序规则。
enum ClipboardHistoryList {
    static func items(
        from items: [ClipboardHistoryItem],
        query: String,
        category: ClipboardHistoryCategory,
        sortOrder: ClipboardHistorySortOrder
    ) -> [ClipboardHistoryItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            guard category.contains(item.content) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            guard let searchableText = item.content.searchableText else { return false }
            return searchableText.localizedCaseInsensitiveContains(normalizedQuery)
        }

        return filtered.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }

            switch sortOrder {
            case .newestFirst:
                return lhs.capturedAt > rhs.capturedAt
            case .oldestFirst:
                return lhs.capturedAt < rhs.capturedAt
            }
        }
    }
}

/// 剪贴板面板键盘选择规则，避免 UI 层直接处理索引边界。
enum ClipboardHistoryKeyboardNavigation {
    enum Direction {
        case up
        case down
    }

    static func selection(
        in items: [ClipboardHistoryItem],
        from selectedID: UUID?,
        moving direction: Direction
    ) -> UUID? {
        guard !items.isEmpty else { return nil }
        guard let selectedID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedID }) else {
            return direction == .down ? items.first?.id : items.last?.id
        }

        switch direction {
        case .up:
            return items[max(0, currentIndex - 1)].id
        case .down:
            return items[min(items.count - 1, currentIndex + 1)].id
        }
    }
}

/// 将历史内容写入指定剪贴板，并返回系统是否接受写入。
enum ClipboardHistoryPasteboardWriter {
    static func write(_ content: ClipboardHistoryContent, to pasteboard: NSPasteboard) -> Bool {
        switch content {
        case let .text(text):
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case let .image(data):
            guard let tiffData = ClipboardHistoryImageData.tiffData(from: data) else {
                return false
            }
            pasteboard.clearContents()
            return pasteboard.setData(tiffData, forType: .tiff)
        case let .url(value):
            guard let url = URL(string: value), !url.isFileURL else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([url as NSURL])
        case let .files(files):
            let urls = files.map(\.url)
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }
}

/// 一条剪贴板历史记录。
struct ClipboardHistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let content: ClipboardHistoryContent
    let capturedAt: Date
    let expiresAt: Date?
    var isPinned: Bool
}

/// 识别不应长期保留的剪贴板文本。
enum ClipboardSensitivity {
    static func isSensitiveText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lowered = normalized.lowercased()
        let keywords = ["password", "passwd", "secret", "token", "密码", "验证码"]
        if keywords.contains(where: lowered.contains) {
            return true
        }

        let digits = normalized.filter(\.isNumber)
        return digits.count == normalized.count && (4...8).contains(digits.count)
    }
}

/// 不依赖系统剪贴板的历史缓冲区，负责容量和状态转换。
struct ClipboardHistoryBuffer {
    private(set) var items: [ClipboardHistoryItem] = []

    private var limit: Int
    private let sensitiveLifetime: TimeInterval

    init(
        limit: Int = 50,
        sensitiveLifetime: TimeInterval = 60,
        items: [ClipboardHistoryItem] = []
    ) {
        self.items = items
        self.limit = max(1, limit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        trimToLimit()
    }

    @discardableResult
    mutating func insert(
        _ content: ClipboardHistoryContent,
        now: Date,
        id: UUID = UUID()
    ) -> ClipboardHistoryItem? {
        if case let .text(text) = content,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        switch content {
        case let .image(data) where data.isEmpty:
            return nil
        case let .url(value) where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return nil
        case let .files(files) where files.isEmpty || files.contains(where: { $0.path.isEmpty }):
            return nil
        default:
            break
        }

        pruneExpired(now: now)
        let wasPinned = items.first(where: { $0.content == content })?.isPinned ?? false
        items.removeAll { $0.content == content }

        let expiresAt: Date?
        if case let .text(text) = content,
           ClipboardSensitivity.isSensitiveText(text) {
            expiresAt = now.addingTimeInterval(sensitiveLifetime)
        } else {
            expiresAt = nil
        }

        let item = ClipboardHistoryItem(
            id: id,
            content: content,
            capturedAt: now,
            expiresAt: expiresAt,
            isPinned: wasPinned
        )
        items.insert(item, at: 0)
        trimToLimit()
        return items.first(where: { $0.id == id })
    }

    mutating func togglePinned(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
    }

    mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func clearUnpinned() {
        items.removeAll { !$0.isPinned }
    }

    mutating func clearAll() {
        items.removeAll()
    }

    mutating func setLimit(_ limit: Int) {
        self.limit = max(1, limit)
        trimToLimit()
    }

    mutating func pruneExpired(now: Date) {
        items.removeAll { item in
            guard let expiresAt = item.expiresAt else { return false }
            return expiresAt <= now
        }
    }

    private mutating func trimToLimit() {
        while items.count > limit {
            guard let index = items.lastIndex(where: { !$0.isPinned }) else {
                items.removeFirst()
                continue
            }
            items.remove(at: index)
        }
    }
}

/// 将剪贴板历史写入 Application Support，避免重启或重新编译后丢失。
enum ClipboardHistoryPersistence {
    private static let directoryName = "MenuTools"
    private static let fileName = "ClipboardHistory.json"

    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(fileName)
    }

    static func load(from url: URL) -> [ClipboardHistoryItem] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([ClipboardHistoryItem].self, from: data)) ?? []
    }

    static func save(_ items: [ClipboardHistoryItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(items)
        try data.write(to: url, options: .atomic)
    }

}

/// 负责监听系统剪贴板并向界面提供可操作的历史记录。
@MainActor
@Observable
final class ClipboardHistoryService {
    static let shared = ClipboardHistoryService()

    private var buffer: ClipboardHistoryBuffer
    private let persistenceURL: URL?
    private let persistenceLoader: @Sendable (URL) async -> [ClipboardHistoryItem]
    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults
    private let frontmostApplicationBundleIdentifierProvider: @MainActor () -> String?
    private(set) var limit: Int
    private let sensitiveLifetime: TimeInterval
    private var lastChangeCount: Int = -1
    private var historyMutationGeneration = 0
    private var loadingTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var currentItemCount = 0
    private(set) var hasLoadedPersistedHistory: Bool
    private(set) var isRecordingPaused: Bool
    private(set) var excludedBundleIDs: [String]

    init(
        limit: Int? = nil,
        sensitiveLifetime: TimeInterval = 60,
        persistenceURL: URL? = ClipboardHistoryPersistence.defaultURL(),
        pasteboard: NSPasteboard = .general,
        userDefaults: UserDefaults = .standard,
        frontmostApplicationBundleIdentifierProvider: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        persistenceLoader: @escaping @Sendable (URL) async -> [ClipboardHistoryItem] = { url in
            await Task.detached(priority: .utility) {
                ClipboardHistoryPersistence.load(from: url)
            }.value
        }
    ) {
        let configuredLimit = limit ?? ClipboardHistoryLimit.storedValue
        self.persistenceURL = persistenceURL
        self.persistenceLoader = persistenceLoader
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.frontmostApplicationBundleIdentifierProvider = frontmostApplicationBundleIdentifierProvider
        self.limit = max(1, configuredLimit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        self.hasLoadedPersistedHistory = persistenceURL == nil
        self.isRecordingPaused = userDefaults.bool(forKey: StorageKey.isRecordingPaused)
        self.excludedBundleIDs = Array(
            Set(userDefaults.stringArray(forKey: StorageKey.excludedBundleIDs) ?? [])
        ).sorted()
        buffer = ClipboardHistoryBuffer(
            limit: configuredLimit,
            sensitiveLifetime: sensitiveLifetime
        )
    }

    /// 历史文件可能包含体积很大的图片，必须在后台读取和解码，不能阻塞菜单栏首帧。
    func loadPersistedHistory() async {
        guard !hasLoadedPersistedHistory else { return }
        if let loadingTask {
            await loadingTask.value
            return
        }
        guard let persistenceURL else {
            hasLoadedPersistedHistory = true
            return
        }

        let mutationGeneration = historyMutationGeneration
        let persistenceLoader = self.persistenceLoader
        let task = Task { @MainActor [weak self] in
            let restored = await persistenceLoader(persistenceURL)
            guard let self else { return }
            defer {
                hasLoadedPersistedHistory = true
                loadingTask = nil
            }
            guard historyMutationGeneration == mutationGeneration else { return }

            var restoredBuffer = ClipboardHistoryBuffer(
                limit: limit,
                sensitiveLifetime: sensitiveLifetime,
                items: restored
            )
            restoredBuffer.pruneExpired(now: Date())
            buffer = restoredBuffer
            items = restoredBuffer.items
            persist()
        }
        loadingTask = task
        await task.value
    }

    /// 在 App 生命周期内持续监听剪贴板，不依赖菜单栏面板是否打开。
    func startMonitoring(interval: Duration = .seconds(1)) {
        guard monitoringTask == nil else { return }
        startObservingExcludedApplicationDeactivation()
        monitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPersistedHistory()
            guard !Task.isCancelled else { return }
            self.refreshLoadedHistory()

            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.refreshLoadedHistory()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        stopObservingExcludedApplicationDeactivation()
    }

    /// 检查剪贴板变化；调用方负责按合适的间隔轮询。
    func refresh() {
        guard hasLoadedPersistedHistory else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadPersistedHistory()
                self.refreshLoadedHistory()
            }
            return
        }
        refreshLoadedHistory()
    }

    private func refreshLoadedHistory(frontmostApplicationBundleIdentifier: String? = nil) {
        let pasteboard = self.pasteboard
        let now = Date()
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
        let itemsBeforeRefresh = buffer.items
        buffer.pruneExpired(now: now)

        guard pasteboard.changeCount != lastChangeCount else {
            synchronizeItems()
            return
        }
        lastChangeCount = pasteboard.changeCount

        var historyChanged = buffer.items != itemsBeforeRefresh
        if ClipboardHistoryRecordingPolicy.shouldRecord(
            isPaused: isRecordingPaused,
            sourceBundleID: frontmostApplicationBundleIdentifier
                ?? frontmostApplicationBundleIdentifierProvider(),
            excludedBundleIDs: excludedBundleIDs
        ), let content = readContent(from: pasteboard),
           buffer.insert(content, now: now) != nil {
            historyChanged = true
        }
        synchronizeItems()
        if historyChanged { persist() }
    }

    /// macOS 剪贴板不会携带复制来源；App 失焦时按离开前的前台 App 立即处理
    /// 尚未被轮询到的变更，避免切换后使用新 App 的状态误判。
    func handleApplicationDeactivation(bundleIdentifier: String?) {
        guard pasteboard.changeCount != lastChangeCount else { return }
        refreshLoadedHistory(frontmostApplicationBundleIdentifier: bundleIdentifier)
    }

    @discardableResult
    func copy(_ item: ClipboardHistoryItem) -> Bool {
        copy(item.content)
    }

    @discardableResult
    func copy(_ content: ClipboardHistoryContent) -> Bool {
        let pasteboard = self.pasteboard
        guard ClipboardHistoryPasteboardWriter.write(content, to: pasteboard) else { return false }
        if !isRecordingPaused {
            historyMutationGeneration &+= 1
            buffer.insert(content, now: Date())
            synchronizeItems()
            persist()
        }
        lastChangeCount = pasteboard.changeCount
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
        return true
    }

    private func startObservingExcludedApplicationDeactivation() {
        guard workspaceNotificationObservers.isEmpty else { return }
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            MainActor.assumeIsolated { [weak self] in
                self?.handleApplicationDeactivation(bundleIdentifier: bundleIdentifier)
            }
        }
        workspaceNotificationObservers = [observer]
    }

    private func stopObservingExcludedApplicationDeactivation() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.forEach(notificationCenter.removeObserver)
        workspaceNotificationObservers.removeAll()
    }

    func setLimit(_ limit: ClipboardHistoryLimit) {
        let updatedLimit = limit.rawValue
        guard self.limit != updatedLimit else { return }

        self.limit = updatedLimit
        buffer.setLimit(updatedLimit)
        synchronizeItems()
        userDefaults.set(updatedLimit, forKey: SettingsKey.clipboardHistoryLimit)
        if hasLoadedPersistedHistory {
            persist()
        }
    }

    func setRecordingPaused(_ paused: Bool) {
        guard isRecordingPaused != paused else { return }
        isRecordingPaused = paused
        userDefaults.set(paused, forKey: StorageKey.isRecordingPaused)
    }

    func addExcludedBundleID(_ bundleID: String) {
        let normalizedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBundleID.isEmpty,
              !excludedBundleIDs.contains(normalizedBundleID) else {
            return
        }
        excludedBundleIDs.append(normalizedBundleID)
        excludedBundleIDs.sort()
        userDefaults.set(excludedBundleIDs, forKey: StorageKey.excludedBundleIDs)
    }

    func removeExcludedBundleID(_ bundleID: String) {
        guard excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.removeAll { $0 == bundleID }
        userDefaults.set(excludedBundleIDs, forKey: StorageKey.excludedBundleIDs)
    }

    func togglePinned(id: UUID) {
        guard buffer.items.contains(where: { $0.id == id }) else { return }
        historyMutationGeneration &+= 1
        buffer.togglePinned(id: id)
        synchronizeItems()
        persist()
    }

    func remove(id: UUID) {
        guard buffer.items.contains(where: { $0.id == id }) else { return }
        historyMutationGeneration &+= 1
        buffer.remove(id: id)
        synchronizeItems()
        persist()
    }

    func clearHistory() {
        historyMutationGeneration &+= 1
        buffer.clearAll()
        synchronizeItems()
        persist()
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardHistoryContent? {
        ClipboardHistoryPasteboardReader.content(from: pasteboard.pasteboardItems ?? [])
    }

    private func synchronizeItems() {
        items = buffer.items
    }

    private func persist() {
        guard let persistenceURL else { return }
        try? ClipboardHistoryPersistence.save(buffer.items, to: persistenceURL)
    }

    private enum StorageKey {
        static let isRecordingPaused = "clipboard.isRecordingPaused"
        static let excludedBundleIDs = "clipboard.excludedBundleIDs"
    }
}
