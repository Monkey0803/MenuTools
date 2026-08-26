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

    private let limit: Int
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
    private var lastChangeCount: Int = -1
    private var monitoringTask: Task<Void, Never>?

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var currentItemCount = 0

    init(
        limit: Int = 50,
        sensitiveLifetime: TimeInterval = 60,
        persistenceURL: URL? = ClipboardHistoryPersistence.defaultURL()
    ) {
        self.persistenceURL = persistenceURL
        buffer = ClipboardHistoryBuffer(
            limit: limit,
            sensitiveLifetime: sensitiveLifetime,
            items: persistenceURL.map(ClipboardHistoryPersistence.load(from:)) ?? []
        )
        buffer.pruneExpired(now: Date())
        items = buffer.items
    }

    /// 在 App 生命周期内持续监听剪贴板，不依赖菜单栏面板是否打开。
    func startMonitoring(interval: Duration = .seconds(1)) {
        guard monitoringTask == nil else { return }
        refresh()
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    /// 检查剪贴板变化；调用方负责按合适的间隔轮询。
    func refresh() {
        let pasteboard = NSPasteboard.general
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

    func copy(_ item: ClipboardHistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .image(data):
            pasteboard.setData(data, forType: .tiff)
        }
        lastChangeCount = pasteboard.changeCount
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
    }

    func togglePinned(id: UUID) {
        buffer.togglePinned(id: id)
        synchronizeItems()
        persist()
    }

    func remove(id: UUID) {
        buffer.remove(id: id)
        synchronizeItems()
        persist()
    }

    func clearHistory() {
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
