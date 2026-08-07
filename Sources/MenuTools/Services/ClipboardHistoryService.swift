import AppKit
import Foundation
import Observation

/// 剪贴板历史中的内容；图片使用 TIFF 数据保存，避免把 NSImage 带入并发边界。
enum ClipboardHistoryContent: Equatable, Sendable {
    case text(String)
    case image(Data)
}

/// 一条剪贴板历史记录。
struct ClipboardHistoryItem: Identifiable, Equatable, Sendable {
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

    init(limit: Int = 50, sensitiveLifetime: TimeInterval = 60) {
        self.limit = max(1, limit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
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

/// 负责监听系统剪贴板并向界面提供可操作的历史记录。
@MainActor
@Observable
final class ClipboardHistoryService {
    static let shared = ClipboardHistoryService()

    private var buffer: ClipboardHistoryBuffer
    private var lastChangeCount: Int = -1
    private var monitoringTask: Task<Void, Never>?

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var currentItemCount = 0

    init(limit: Int = 50, sensitiveLifetime: TimeInterval = 60) {
        buffer = ClipboardHistoryBuffer(
            limit: limit,
            sensitiveLifetime: sensitiveLifetime
        )
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
        buffer.pruneExpired(now: now)

        guard pasteboard.changeCount != lastChangeCount else {
            synchronizeItems()
            return
        }
        lastChangeCount = pasteboard.changeCount

        if let content = readContent(from: pasteboard) {
            _ = buffer.insert(content, now: now)
        }
        synchronizeItems()
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
    }

    func remove(id: UUID) {
        buffer.remove(id: id)
        synchronizeItems()
    }

    func clearHistory() {
        buffer.clearAll()
        synchronizeItems()
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardHistoryContent? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        if let text = item.string(forType: .string) {
            return .text(text)
        }
        if let data = item.data(forType: .tiff) {
            return .image(data)
        }
        return nil
    }

    private func synchronizeItems() {
        items = buffer.items
    }
}
