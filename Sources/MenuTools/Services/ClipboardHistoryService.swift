import AppKit
import ApplicationServices
import Foundation
import Observation

struct ClipboardHistoryFile: Codable, Equatable, Sendable, Identifiable {
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }
}

struct ClipboardRichText: Codable, Equatable, Sendable {
    let plainText: String
    let html: Data?
    let rtf: Data?
}

/// 剪贴板历史中的内容；图片使用 TIFF 数据保存，避免把 NSImage 带入并发边界。
enum ClipboardHistoryContent: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)
    case url(String)
    case files([ClipboardHistoryFile])
    case richText(ClipboardRichText)

    private enum CodingKeys: String, CodingKey {
        case text
        case image
        case url
        case files
        case richText
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
        } else if let richText = try container.decodeIfPresent(ClipboardRichText.self, forKey: .richText) {
            self = .richText(richText)
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
        case let .richText(richText):
            try container.encode(richText, forKey: .richText)
        }
    }

    var searchableText: String? {
        switch self {
        case let .text(text), let .url(text):
            text
        case let .files(files):
            files.map { "\($0.displayName) \($0.path)" }.joined(separator: " ")
        case let .richText(richText):
            richText.plainText
        case .image:
            nil
        }
    }

    /// 用于历史空间上限的近似占用；文件只保存路径，因此不计算文件本身大小。
    var storageSize: Int {
        switch self {
        case let .text(value), let .url(value):
            return value.lengthOfBytes(using: .utf8)
        case let .image(data):
            return data.count
        case let .files(files):
            return files.reduce(0) { $0 + $1.path.lengthOfBytes(using: .utf8) }
        case let .richText(richText):
            return richText.plainText.lengthOfBytes(using: .utf8) + (richText.html?.count ?? 0) + (richText.rtf?.count ?? 0)
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
            let html = item.data(forType: .html)
            let rtf = item.data(forType: .rtf)
            if html != nil || rtf != nil {
                return .richText(ClipboardRichText(plainText: text, html: html, rtf: rtf))
            }
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
        case (.all, _), (.text, .text), (.text, .richText), (.image, .image), (.url, .url), (.file, .files):
            return true
        case (.text, .image), (.text, .url), (.text, .files),
             (.image, .text), (.image, .url), (.image, .files),
             (.url, .text), (.url, .image), (.url, .files),
             (.file, .text), (.file, .image), (.file, .url), (.file, .richText),
             (.image, .richText), (.url, .richText):
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

enum ClipboardHistoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case month

    var id: String { rawValue }

    var titleKey: String { "clipboard.dateFilter.\(rawValue)" }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: return true
        case .today: return calendar.isDateInToday(date)
        case .week:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
            return date >= cutoff
        case .month:
            guard let cutoff = calendar.date(byAdding: .month, value: -1, to: now) else { return true }
            return date >= cutoff
        }
    }
}

/// 设置页和快捷面板共用的历史筛选与排序规则。
enum ClipboardHistoryList {
    static func items(
        from items: [ClipboardHistoryItem],
        query: String,
        category: ClipboardHistoryCategory,
        sortOrder: ClipboardHistorySortOrder,
        sourceBundleID: String? = nil,
        dateFilter: ClipboardHistoryDateFilter = .all
    ) -> [ClipboardHistoryItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            guard category.contains(item.content) else { return false }
            guard sourceBundleID == nil || item.sourceBundleID == sourceBundleID else { return false }
            guard dateFilter.contains(item.capturedAt) else { return false }
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

    /// 回车优先复制方向键当前选中的记录；首次打开面板时复制首项。
    static func itemToCopy(
        in items: [ClipboardHistoryItem],
        selectedID: UUID?
    ) -> ClipboardHistoryItem? {
        guard let selectedID else { return items.first }
        return items.first(where: { $0.id == selectedID }) ?? items.first
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
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
            return pasteboard.writeObjects([item])
        case let .files(files):
            let urls = files.map(\.url)
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls as [NSURL])
        case let .richText(richText):
            let item = NSPasteboardItem()
            item.setString(richText.plainText, forType: .string)
            if let html = richText.html { item.setData(html, forType: .html) }
            if let rtf = richText.rtf { item.setData(rtf, forType: .rtf) }
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
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
    var sourceBundleID: String?
    var tags: [String]
    var note: String?
    var isSensitive: Bool

    init(
        id: UUID,
        content: ClipboardHistoryContent,
        capturedAt: Date,
        expiresAt: Date?,
        isPinned: Bool,
        sourceBundleID: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.content = content
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.isPinned = isPinned
        self.sourceBundleID = sourceBundleID
        self.tags = tags
        self.note = note
        self.isSensitive = isSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, capturedAt, expiresAt, isPinned, sourceBundleID, tags, note, isSensitive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(ClipboardHistoryContent.self, forKey: .content)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
    }
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

/// 控制哪些敏感内容完全不进入剪贴板历史。旧版的短时过期机制仍保留给已存在的历史文件。
struct ClipboardSensitiveRules: Codable, Equatable, Sendable {
    var passwordManagersEnabled = true
    var verificationCodesEnabled = true
    var bankCardsEnabled = true
    var keywords = ["password", "passwd", "secret", "token", "密码"]

    func shouldExclude(_ content: ClipboardHistoryContent, sourceBundleID: String?) -> Bool {
        guard case let .text(text) = content else { return false }
        if passwordManagersEnabled, Self.isPasswordManager(sourceBundleID) { return true }
        if verificationCodesEnabled, Self.isVerificationCode(text) { return true }
        if bankCardsEnabled, Self.isBankCard(text) { return true }
        let normalized = text.lowercased()
        return keywords.contains { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !trimmed.isEmpty && normalized.contains(trimmed)
        }
    }

    private static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return ["1password", "lastpass", "bitwarden", "dashlane", "keepass", "enpass"].contains {
            bundleID.contains($0)
        }
    }

    private static func isVerificationCode(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.allSatisfy(\.isNumber) && (4...8).contains(value.count)
    }

    private static func isBankCard(_ text: String) -> Bool {
        // 占位标记也由部分密码管理器用于卡号复制，方便规则测试和后续接入。
        if text.range(of: "CREDIT_CARD", options: .caseInsensitive) != nil { return true }
        let digits = text.filter(\.isNumber)
        guard (13...19).contains(digits.count),
              text.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        let checksum = digits.reversed().enumerated().reduce(0) { result, pair in
            let value = Int(String(pair.element)) ?? 0
            let adjusted = pair.offset.isMultiple(of: 2) ? value * 2 : value
            return result + (adjusted > 9 ? adjusted - 9 : adjusted)
        }
        return checksum.isMultiple(of: 10)
    }
}

enum ClipboardHistoryDateSectionKind: Equatable, Hashable, Sendable {
    case pinned
    case today
    case yesterday
    case date(Date)
}

struct ClipboardHistoryDateSection: Identifiable, Equatable, Sendable {
    let kind: ClipboardHistoryDateSectionKind
    let items: [ClipboardHistoryItem]

    var id: ClipboardHistoryDateSectionKind { kind }
}

enum ClipboardHistoryDateSections {
    static func sections(from items: [ClipboardHistoryItem], now: Date = Date(), calendar: Calendar = .current) -> [ClipboardHistoryDateSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        var grouped: [(ClipboardHistoryDateSectionKind, [ClipboardHistoryItem])] = []
        for item in items {
            let kind: ClipboardHistoryDateSectionKind
            if item.isPinned {
                kind = .pinned
            } else {
                let day = calendar.startOfDay(for: item.capturedAt)
                kind = day == today ? .today : (day == yesterday ? .yesterday : .date(day))
            }
            if let index = grouped.firstIndex(where: { $0.0 == kind }) {
                grouped[index].1.append(item)
            } else {
                grouped.append((kind, [item]))
            }
        }
        return grouped.map { ClipboardHistoryDateSection(kind: $0.0, items: $0.1) }
    }
}

/// 剪贴板卡片所需的系统快捷操作。
enum ClipboardHistoryQuickAction {
    static func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    static func revealFiles(_ files: [ClipboardHistoryFile]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url))
    }

    @discardableResult
    static func copyPaths(_ files: [ClipboardHistoryFile], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !files.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
    }
}

enum ClipboardAutoPasteResult: Sendable, Equatable {
    case pasted
    case accessibilityPermissionDenied
    case noEditableTarget
    case failed
}

enum ClipboardCopyFeedback: Sendable, Equatable {
    case copied
    case pasted
    case accessibilityPermissionDenied
    case noEditableTarget
    case pasteFailed

    init(autoPasteResult: ClipboardAutoPasteResult) {
        switch autoPasteResult {
        case .pasted: self = .pasted
        case .accessibilityPermissionDenied: self = .accessibilityPermissionDenied
        case .noEditableTarget: self = .noEditableTarget
        case .failed: self = .pasteFailed
        }
    }

    var localizationKey: String {
        switch self {
        case .copied: return "clipboard.feedback.copied"
        case .pasted: return "clipboard.feedback.pasted"
        case .accessibilityPermissionDenied: return "clipboard.feedback.permissionDenied"
        case .noEditableTarget: return "clipboard.feedback.noEditableTarget"
        case .pasteFailed: return "clipboard.feedback.pasteFailed"
        }
    }
}

enum ClipboardHistoryAutoPaste {
    /// 仅在辅助功能权限允许且前台焦点为可编辑控件时发送 Command-V。
    static func pasteIntoPreviousApplication() -> ClipboardAutoPasteResult {
        guard AXIsProcessTrusted() else { return .accessibilityPermissionDenied }
        guard focusedElementIsEditable() else { return .noEditableTarget }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .failed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return .pasted
    }

    private static func focusedElementIsEditable() -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue else {
            return false
        }
        let focusedElement = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)

        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            "AXEditable" as CFString,
            &editableValue
        ) == .success,
           let isEditable = editableValue as? Bool {
            return isEditable
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
              let role = roleValue as? String else {
            return false
        }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
    }
}

/// 不依赖系统剪贴板的历史缓冲区，负责容量和状态转换。
struct ClipboardHistoryBuffer {
    private(set) var items: [ClipboardHistoryItem] = []

    private var limit: Int
    private let sensitiveLifetime: TimeInterval
    private var retentionDuration: TimeInterval?
    private var storageLimitBytes: Int

    init(
        limit: Int = 50,
        sensitiveLifetime: TimeInterval = 60,
        retentionDuration: TimeInterval? = nil,
        storageLimitBytes: Int = .max,
        items: [ClipboardHistoryItem] = []
    ) {
        self.items = items
        self.limit = max(1, limit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        self.retentionDuration = retentionDuration.map { max(0, $0) }
        self.storageLimitBytes = max(0, storageLimitBytes)
        applyAutomaticCleanup(now: Date())
    }

    @discardableResult
    mutating func insert(
        _ content: ClipboardHistoryContent,
        now: Date,
        sourceBundleID: String? = nil,
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

        applyAutomaticCleanup(now: now)
        let existing = items.first(where: { $0.content == content })
        let wasPinned = existing?.isPinned ?? false
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
            isPinned: wasPinned,
            sourceBundleID: sourceBundleID ?? existing?.sourceBundleID,
            tags: existing?.tags ?? [],
            note: existing?.note,
            isSensitive: existing?.isSensitive ?? false
        )
        items.insert(item, at: 0)
        applyAutomaticCleanup(now: now)
        return items.first(where: { $0.id == id })
    }

    mutating func togglePinned(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
    }

    mutating func updateMetadata(
        id: UUID,
        tags: [String]? = nil,
        note: String?? = nil,
        isSensitive: Bool? = nil
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let tags { items[index].tags = tags }
        if let note { items[index].note = note }
        if let isSensitive { items[index].isSensitive = isSensitive }
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

    mutating func setAutomaticCleanup(retentionDuration: TimeInterval?, storageLimitBytes: Int, now: Date = Date()) {
        self.retentionDuration = retentionDuration.map { max(0, $0) }
        self.storageLimitBytes = max(0, storageLimitBytes)
        applyAutomaticCleanup(now: now)
    }

    mutating func restore(_ restoredItems: [ClipboardHistoryItem], now: Date = Date()) {
        items.append(contentsOf: restoredItems.filter { restored in !items.contains(where: { $0.id == restored.id }) })
        items.sort { $0.capturedAt > $1.capturedAt }
        applyAutomaticCleanup(now: now)
    }

    mutating func applyAutomaticCleanup(now: Date) {
        pruneExpired(now: now)
        if let retentionDuration {
            let cutoff = now.addingTimeInterval(-retentionDuration)
            items.removeAll { !$0.isPinned && $0.capturedAt < cutoff }
        }
        trimToLimit()
        trimToStorageLimit()
    }

    mutating func pruneExpired(now: Date) {
        items.removeAll { item in
            guard let expiresAt = item.expiresAt else { return false }
            return expiresAt <= now
        }
    }

    private mutating func trimToLimit() {
        while items.count > limit {
            guard let index = items.lastIndex(where: { !$0.isPinned }) else { return }
            items.remove(at: index)
        }
    }

    private mutating func trimToStorageLimit() {
        while items.reduce(0, { $0 + $1.content.storageSize }) > storageLimitBytes {
            // 单条内容本身可能大于上限；保留它以避免一次复制后历史完全为空。
            guard items.count > 1 else { return }
            guard let index = items.lastIndex(where: { !$0.isPinned }) else { return }
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
    private let autoPasteAction: @MainActor () -> ClipboardAutoPasteResult
    private(set) var limit: Int
    private let sensitiveLifetime: TimeInterval
    private var lastChangeCount: Int = -1
    private var historyMutationGeneration = 0
    private var loadingTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var undoExpirationTask: Task<Void, Never>?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var lastRemovedItems: [ClipboardHistoryItem] = []

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var currentItemCount = 0
    private(set) var hasLoadedPersistedHistory: Bool
    private(set) var isRecordingPaused: Bool
    private(set) var excludedBundleIDs: [String]
    private(set) var sensitiveRules: ClipboardSensitiveRules
    private(set) var retentionDays: Int
    private(set) var storageLimitBytes: Int
    private(set) var autoPasteAfterCopy: Bool
    private(set) var copyFeedback: ClipboardCopyFeedback?
    var canUndoLastRemoval: Bool { !lastRemovedItems.isEmpty }

    init(
        limit: Int? = nil,
        sensitiveLifetime: TimeInterval = 60,
        persistenceURL: URL? = ClipboardHistoryPersistence.defaultURL(),
        pasteboard: NSPasteboard = .general,
        userDefaults: UserDefaults = .standard,
        autoPasteAction: @escaping @MainActor () -> ClipboardAutoPasteResult = ClipboardHistoryAutoPaste.pasteIntoPreviousApplication,
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
        self.autoPasteAction = autoPasteAction
        self.limit = max(1, configuredLimit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        self.hasLoadedPersistedHistory = persistenceURL == nil
        self.isRecordingPaused = userDefaults.bool(forKey: StorageKey.isRecordingPaused)
        self.excludedBundleIDs = Array(
            Set(userDefaults.stringArray(forKey: StorageKey.excludedBundleIDs) ?? [])
        ).sorted()
        self.sensitiveRules = Self.loadSensitiveRules(from: userDefaults)
        self.retentionDays = max(0, userDefaults.object(forKey: StorageKey.retentionDays) as? Int ?? 0)
        self.storageLimitBytes = max(0, userDefaults.object(forKey: StorageKey.storageLimitBytes) as? Int ?? .max)
        self.autoPasteAfterCopy = userDefaults.bool(forKey: StorageKey.autoPasteAfterCopy)
        self.copyFeedback = nil
        buffer = ClipboardHistoryBuffer(
            limit: configuredLimit,
            sensitiveLifetime: sensitiveLifetime,
            retentionDuration: Self.retentionDuration(for: max(0, userDefaults.object(forKey: StorageKey.retentionDays) as? Int ?? 0)),
            storageLimitBytes: max(0, userDefaults.object(forKey: StorageKey.storageLimitBytes) as? Int ?? .max)
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
                retentionDuration: Self.retentionDuration(for: retentionDays),
                storageLimitBytes: storageLimitBytes,
                items: restored
            )
            restoredBuffer.applyAutomaticCleanup(now: Date())
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
        buffer.applyAutomaticCleanup(now: now)

        guard pasteboard.changeCount != lastChangeCount else {
            synchronizeItems()
            return
        }
        lastChangeCount = pasteboard.changeCount

        var historyChanged = buffer.items != itemsBeforeRefresh
        let sourceBundleID = frontmostApplicationBundleIdentifier
            ?? frontmostApplicationBundleIdentifierProvider()
        if ClipboardHistoryRecordingPolicy.shouldRecord(
            isPaused: isRecordingPaused,
            sourceBundleID: sourceBundleID,
            excludedBundleIDs: excludedBundleIDs
        ), let content = readContent(from: pasteboard),
           !sensitiveRules.shouldExclude(content, sourceBundleID: sourceBundleID),
           buffer.insert(content, now: now, sourceBundleID: sourceBundleID) != nil {
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
        if !isRecordingPaused,
           !sensitiveRules.shouldExclude(content, sourceBundleID: nil) {
            historyMutationGeneration &+= 1
            buffer.insert(content, now: Date())
            synchronizeItems()
            persist()
        }
        lastChangeCount = pasteboard.changeCount
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
        copyFeedback = .copied
        if autoPasteAfterCopy {
            // 让调用方先关闭菜单栏弹窗，再将 Command-V 发回此前的前台应用。
            // 否则按键会被仍在关闭过程中的 Popover 接收。
            let autoPasteAction = self.autoPasteAction
            Task { @MainActor [weak self] in
                self?.copyFeedback = ClipboardCopyFeedback(autoPasteResult: autoPasteAction())
            }
        }
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

    func setRetentionDays(_ days: Int) {
        let days = max(0, days)
        guard retentionDays != days else { return }
        retentionDays = days
        userDefaults.set(days, forKey: StorageKey.retentionDays)
        applyAutomaticCleanup()
    }

    func setStorageLimitMegabytes(_ megabytes: Int) {
        let bytes = megabytes <= 0 ? Int.max : megabytes * 1_024 * 1_024
        guard storageLimitBytes != bytes else { return }
        storageLimitBytes = bytes
        userDefaults.set(bytes, forKey: StorageKey.storageLimitBytes)
        applyAutomaticCleanup()
    }

    func setAutoPasteAfterCopy(_ enabled: Bool) {
        guard autoPasteAfterCopy != enabled else { return }
        autoPasteAfterCopy = enabled
        userDefaults.set(enabled, forKey: StorageKey.autoPasteAfterCopy)
    }

    func setSensitiveRules(_ rules: ClipboardSensitiveRules) {
        guard sensitiveRules != rules else { return }
        sensitiveRules = rules
        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: StorageKey.sensitiveRules)
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

    func setTags(_ tags: [String], for id: UUID) {
        let normalized = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        buffer.updateMetadata(id: id, tags: normalized)
        synchronizeItems()
        persist()
    }

    func setNote(_ note: String?, for id: UUID) {
        buffer.updateMetadata(id: id, note: note?.trimmingCharacters(in: .whitespacesAndNewlines))
        synchronizeItems()
        persist()
    }

    func setSensitive(_ isSensitive: Bool, for id: UUID) {
        buffer.updateMetadata(id: id, isSensitive: isSensitive)
        synchronizeItems()
        persist()
    }

    func remove(id: UUID) {
        remove(ids: [id])
    }

    func removeRecent(since cutoff: Date) {
        let ids = Set(buffer.items.filter { !$0.isPinned && $0.capturedAt >= cutoff }.map(\.id))
        remove(ids: ids)
    }

    func remove(ids: Set<UUID>) {
        let removed = buffer.items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        historyMutationGeneration &+= 1
        removed.forEach { buffer.remove(id: $0.id) }
        lastRemovedItems = removed
        scheduleUndoExpiration()
        synchronizeItems()
        persist()
    }

    @discardableResult
    func undoLastRemoval() -> Bool {
        guard !lastRemovedItems.isEmpty else { return false }
        historyMutationGeneration &+= 1
        buffer.restore(lastRemovedItems)
        lastRemovedItems.removeAll()
        undoExpirationTask?.cancel()
        undoExpirationTask = nil
        synchronizeItems()
        persist()
        return true
    }

    func clearHistory() {
        historyMutationGeneration &+= 1
        buffer.clearAll()
        synchronizeItems()
        persist()
    }

    func clearUnpinnedHistory() {
        remove(ids: Set(buffer.items.lazy.filter { !$0.isPinned }.map(\.id)))
    }

    private func applyAutomaticCleanup(now: Date = Date()) {
        let before = buffer.items
        buffer.setAutomaticCleanup(
            retentionDuration: Self.retentionDuration(for: retentionDays),
            storageLimitBytes: storageLimitBytes,
            now: now
        )
        guard buffer.items != before else { return }
        historyMutationGeneration &+= 1
        synchronizeItems()
        persist()
    }

    private func scheduleUndoExpiration() {
        undoExpirationTask?.cancel()
        undoExpirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.lastRemovedItems.removeAll()
            self?.undoExpirationTask = nil
        }
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

    private static func retentionDuration(for days: Int) -> TimeInterval? {
        guard days > 0 else { return nil }
        return TimeInterval(days * 86_400)
    }

    private static func loadSensitiveRules(from defaults: UserDefaults) -> ClipboardSensitiveRules {
        guard let data = defaults.data(forKey: StorageKey.sensitiveRules),
              let rules = try? JSONDecoder().decode(ClipboardSensitiveRules.self, from: data) else {
            return ClipboardSensitiveRules()
        }
        return rules
    }

    private enum StorageKey {
        static let isRecordingPaused = "clipboard.isRecordingPaused"
        static let excludedBundleIDs = "clipboard.excludedBundleIDs"
        static let sensitiveRules = "clipboard.sensitiveRules"
        static let retentionDays = "clipboard.retentionDays"
        static let storageLimitBytes = "clipboard.storageLimitBytes"
        static let autoPasteAfterCopy = "clipboard.autoPasteAfterCopy"
    }
}
