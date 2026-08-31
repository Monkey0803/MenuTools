import AppKit
import Foundation
import Observation

/// 剪贴板历史中的内容；图片使用 TIFF 数据保存，避免把 NSImage 带入并发边界。
enum ClipboardHistoryContent: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)

    private enum CodingKeys: String, CodingKey {
        case text
        case image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let image = try container.decodeIfPresent(Data.self, forKey: .image) {
            self = .image(image)
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
        }
    }
}

/// 将系统剪贴板项目转换为历史记录内容。
enum ClipboardHistoryPasteboardReader {
    static func content(from item: NSPasteboardItem) -> ClipboardHistoryContent? {
        if let text = item.string(forType: .string) {
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
}

/// 图片历史记录统一以 TIFF 写回系统剪贴板，避免内容字节与声明类型不一致。
enum ClipboardHistoryImageData {
    static func tiffData(from data: Data) -> Data? {
        NSImage(data: data)?.tiffRepresentation
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

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "clipboard.category.all"
        case .text: return "clipboard.category.text"
        case .image: return "clipboard.category.image"
        }
    }

    fileprivate func contains(_ content: ClipboardHistoryContent) -> Bool {
        switch (self, content) {
        case (.all, _), (.text, .text), (.image, .image): return true
        case (.text, .image), (.image, .text): return false
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
            guard case let .text(text) = item.content else { return false }
            return text.localizedCaseInsensitiveContains(normalizedQuery)
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
        if case let .image(data) = content, data.isEmpty {
            return nil
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
    private(set) var limit: Int
    private let sensitiveLifetime: TimeInterval
    private var lastChangeCount: Int = -1
    private var historyMutationGeneration = 0
    private var loadingTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var currentItemCount = 0
    private(set) var hasLoadedPersistedHistory: Bool

    init(
        limit: Int? = nil,
        sensitiveLifetime: TimeInterval = 60,
        persistenceURL: URL? = ClipboardHistoryPersistence.defaultURL(),
        pasteboard: NSPasteboard = .general,
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
        self.limit = max(1, configuredLimit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        self.hasLoadedPersistedHistory = persistenceURL == nil
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

    private func refreshLoadedHistory() {
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
        if let content = readContent(from: pasteboard),
           buffer.insert(content, now: now) != nil {
            historyChanged = true
        }
        synchronizeItems()
        if historyChanged { persist() }
    }

    @discardableResult
    func copy(_ item: ClipboardHistoryItem) -> Bool {
        let pasteboard = self.pasteboard
        guard ClipboardHistoryPasteboardWriter.write(item.content, to: pasteboard) else { return false }
        historyMutationGeneration &+= 1
        buffer.insert(item.content, now: Date())
        synchronizeItems()
        persist()
        lastChangeCount = pasteboard.changeCount
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
        return true
    }

    func setLimit(_ limit: ClipboardHistoryLimit) {
        let updatedLimit = limit.rawValue
        guard self.limit != updatedLimit else { return }

        self.limit = updatedLimit
        buffer.setLimit(updatedLimit)
        synchronizeItems()
        UserDefaults.standard.set(updatedLimit, forKey: SettingsKey.clipboardHistoryLimit)
        if hasLoadedPersistedHistory {
            persist()
        }
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
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        return ClipboardHistoryPasteboardReader.content(from: item)
    }

    private func synchronizeItems() {
        items = buffer.items
    }

    private func persist() {
        guard let persistenceURL else { return }
        try? ClipboardHistoryPersistence.save(buffer.items, to: persistenceURL)
    }
}
