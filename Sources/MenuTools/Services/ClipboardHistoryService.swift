import AppKit
import ApplicationServices
import Foundation
import Observation
import SQLite3
import CryptoKit
import Security
import ImageIO

struct ClipboardHistoryFile: Codable, Equatable, Sendable, Identifiable {
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
    var isPDF: Bool { url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame }
}

struct ClipboardRichText: Codable, Equatable, Sendable {
    let plainText: String
    let html: Data?
    let rtf: Data?
}

struct ClipboardTextAnalysis: Equatable, Sendable {
    let codeLanguage: String?
    let markdownPreview: String?
    let colorHex: String?
    let structuredLines: [String]

    static func analyze(_ text: String) -> ClipboardTextAnalysis {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = value.split(whereSeparator: \.isNewline).map(String.init)
        let language: String? = {
            if value.contains("func ") || value.contains("import SwiftUI") { return "Swift" }
            if value.contains("const ") || value.contains("function ") { return "JavaScript" }
            if value.contains("def ") || value.contains("import ") && value.contains(":") { return "Python" }
            if value.contains("SELECT ") || value.contains("select ") { return "SQL" }
            return nil
        }()
        let color = value.range(of: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression)
            .map { String(value[$0]).uppercased() }
        let markdown = value.contains("# ") || value.contains("**") || value.contains("```") ? value : nil
        return ClipboardTextAnalysis(codeLanguage: language, markdownPreview: markdown, colorHex: color, structuredLines: lines)
    }
}

enum ClipboardHistoryContentType: String, CaseIterable, Codable, Sendable {
    case text
    case image
    case url
    case files
    case richText
    case pdf
}

/// 剪贴板历史中的内容；图片使用 TIFF 数据保存，避免把 NSImage 带入并发边界。
enum ClipboardHistoryContent: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)
    case url(String)
    case files([ClipboardHistoryFile])
    case richText(ClipboardRichText)
    case pdf(Data)

    private enum CodingKeys: String, CodingKey {
        case text
        case image
        case url
        case files
        case richText
        case pdf
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
        } else if let pdf = try container.decodeIfPresent(Data.self, forKey: .pdf) {
            self = .pdf(pdf)
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
        case let .pdf(pdf):
            try container.encode(pdf, forKey: .pdf)
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
        case let .pdf(data):
            "PDF \(data.count) bytes"
        }
    }

    var contentType: ClipboardHistoryContentType {
        switch self {
        case .text: .text
        case .image: .image
        case .url: .url
        case .files: .files
        case .richText: .richText
        case .pdf: .pdf
        }
    }

    var plainTextRepresentation: String? {
        switch self {
        case let .text(text), let .url(text):
            return text
        case let .richText(richText):
            return richText.plainText
        case let .files(files):
            return files.map(\.path).joined(separator: "\n")
        case .image:
            return nil
        case .pdf:
            return nil
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
        case let .pdf(data):
            return data.count
        }
    }
}

enum ClipboardHistoryEncryption {
    private static let service = "com.qoder.menutools.clipboard-history"
    private static let account = "database-key"
    private static let magic = Data("MTCLIPDB1".utf8)

    static func seal(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key())
        guard let combined = sealed.combined else { throw ClipboardHistoryPersistenceError.encryptionFailed }
        return magic + combined
    }

    static func open(_ data: Data) throws -> Data {
        guard data.starts(with: magic) else { return data }
        let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count)))
        return try AES.GCM.open(box, using: key())
    }

    private static func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { return try fileBackedKey() }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            return try fileBackedKey()
        }
        return SymmetricKey(data: data)
    }

    /// 某些无钥匙串权限的运行环境（例如独立测试进程）使用权限收紧的本地密钥文件，
    /// 确保加密数据仍可跨启动恢复；正常 App 运行优先使用钥匙串。
    private static func fileBackedKey() throws -> SymmetricKey {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuTools", isDirectory: true)
        let url = directory.appendingPathComponent("clipboard-history.key")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: url), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return SymmetricKey(data: data)
    }
}

enum ClipboardHistoryPersistenceError: Error {
    case encryptionKeyUnavailable
    case encryptionFailed
}

/// 将系统剪贴板项目转换为历史记录内容。
enum ClipboardHistoryPasteboardReader {
    private static let ignoredMarkerTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ]

    static func content(from items: [NSPasteboardItem]) -> ClipboardHistoryContent? {
        guard !items.contains(where: { item in
            !ignoredMarkerTypes.isDisjoint(with: item.types)
        }) else {
            return nil
        }

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
        if let data = item.data(forType: NSPasteboard.PasteboardType("com.adobe.pdf")) {
            return .pdf(data)
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

/// 针对单个来源 App 的剪贴板行为覆盖。未填写的字段继承全局设置。
struct ClipboardApplicationPolicy: Codable, Equatable, Sendable, Identifiable {
    let bundleID: String
    var record: Bool?
    var autoPaste: Bool?
    var retentionDays: Int?
    var sensitiveRules: ClipboardSensitiveRules?

    var id: String { bundleID }

    init(bundleID: String, record: Bool? = nil, autoPaste: Bool? = nil,
         retentionDays: Int? = nil, sensitiveRules: ClipboardSensitiveRules? = nil) {
        self.bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.record = record
        self.autoPaste = autoPaste
        self.retentionDays = retentionDays
        self.sensitiveRules = sensitiveRules
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
        case (.all, _), (.text, .text), (.text, .richText), (.image, .image), (.url, .url), (.file, .files), (.file, .pdf):
            return true
        case (.text, .image), (.text, .url), (.text, .files),
             (.image, .text), (.image, .url), (.image, .files),
             (.url, .text), (.url, .image), (.url, .files),
             (.file, .text), (.file, .image), (.file, .url), (.file, .richText),
             (.image, .richText), (.url, .richText),
             (.text, .pdf), (.image, .pdf), (.url, .pdf):
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
            guard !item.isSensitive else { return false }
            guard let searchableText = item.searchableText else { return false }
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

    static func page(_ items: [ClipboardHistoryItem], offset: Int, pageSize: Int) -> ArraySlice<ClipboardHistoryItem> {
        guard pageSize > 0, offset >= 0, offset < items.count else { return items[0..<0] }
        let end = min(items.count, offset + pageSize)
        return items[offset..<end]
    }
}

/// 增量维护历史搜索文本，避免每次查询都重新拼接标题、正文、标签和备注。
struct ClipboardHistorySearchIndex: Sendable {
    private(set) var values: [UUID: String] = [:]

    mutating func upsert(_ item: ClipboardHistoryItem) {
        values[item.id] = item.searchableText?.localizedLowercase ?? ""
    }

    mutating func remove(_ id: UUID) { values.removeValue(forKey: id) }

    mutating func replace(_ items: [ClipboardHistoryItem]) {
        values.removeAll(keepingCapacity: true)
        for item in items { upsert(item) }
    }

    func matches(_ query: String, id: UUID) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return true }
        return values[id]?.localizedCaseInsensitiveContains(normalized) == true
    }
}

/// 图片缩略图的有界内存缓存，避免历史列表滚动时反复解码原图。
actor ClipboardImageThumbnailCache {
    static let shared = ClipboardImageThumbnailCache()
    private let capacity: Int
    private var values: [UUID: Data] = [:]
    private var order: [UUID] = []

    init(capacity: Int = 120) { self.capacity = max(1, capacity) }

    func thumbnail(for id: UUID, source: Data, maxPixel: Int = 256) -> Data? {
        if let cached = values[id] {
            touch(id)
            return cached
        }
        guard let thumbnail = Self.makeThumbnail(source, maxPixel: maxPixel) else { return nil }
        values[id] = thumbnail
        touch(id)
        while order.count > capacity, let evicted = order.first {
            order.removeFirst()
            values.removeValue(forKey: evicted)
        }
        return thumbnail
    }

    func removeAll() { values.removeAll(); order.removeAll() }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    private static func makeThumbnail(_ source: Data, maxPixel: Int) -> Data? {
        guard let sourceRef = CGImageSourceCreateWithData(source as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel), kCGImageSourceCreateThumbnailFromImageAlways: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(sourceRef, 0, options as CFDictionary) else { return nil }
        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destinationData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
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
enum ClipboardPasteboardWriteMode: Sendable, Equatable {
    case original
    case plainText
}

enum ClipboardHistoryPasteboardWriter {
    static func write(
        _ content: ClipboardHistoryContent,
        to pasteboard: NSPasteboard,
        mode: ClipboardPasteboardWriteMode = .original
    ) -> Bool {
        if mode == .plainText {
            guard let plainText = content.plainTextRepresentation else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(plainText, forType: .string)
        }

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
        case let .pdf(data):
            pasteboard.clearContents()
            return pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
        }
    }
}

/// 一条剪贴板历史记录。
struct ClipboardHistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let content: ClipboardHistoryContent
    let capturedAt: Date
    var expiresAt: Date?
    var isPinned: Bool
    var sourceBundleID: String?
    var title: String?
    var tags: [String]
    var note: String?
    var isSensitive: Bool
    var recognizedText: String?

    init(
        id: UUID,
        content: ClipboardHistoryContent,
        capturedAt: Date,
        expiresAt: Date?,
        isPinned: Bool,
        sourceBundleID: String? = nil,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        isSensitive: Bool = false,
        recognizedText: String? = nil
    ) {
        self.id = id
        self.content = content
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.isPinned = isPinned
        self.sourceBundleID = sourceBundleID
        self.title = title
        self.tags = tags
        self.note = note
        self.isSensitive = isSensitive
        self.recognizedText = recognizedText
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, capturedAt, expiresAt, isPinned, sourceBundleID, title, tags, note, isSensitive, recognizedText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(ClipboardHistoryContent.self, forKey: .content)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText)
    }

    var searchableText: String? {
        let components = [title, content.searchableText, recognizedText, tags.joined(separator: " "), note]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: " ")
    }

    var recognizedURLs: [URL] {
        guard let recognizedText else { return [] }
        return recognizedText
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
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
    var applicationBundleIDs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case passwordManagersEnabled
        case verificationCodesEnabled
        case bankCardsEnabled
        case keywords
        case applicationBundleIDs
    }

    init() {}

    init(passwordManagersEnabled: Bool, verificationCodesEnabled: Bool, bankCardsEnabled: Bool) {
        self.passwordManagersEnabled = passwordManagersEnabled
        self.verificationCodesEnabled = verificationCodesEnabled
        self.bankCardsEnabled = bankCardsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passwordManagersEnabled = try container.decodeIfPresent(Bool.self, forKey: .passwordManagersEnabled) ?? true
        verificationCodesEnabled = try container.decodeIfPresent(Bool.self, forKey: .verificationCodesEnabled) ?? true
        bankCardsEnabled = try container.decodeIfPresent(Bool.self, forKey: .bankCardsEnabled) ?? true
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? ["password", "passwd", "secret", "token", "密码"]
        applicationBundleIDs = Array(Set(
            (try container.decodeIfPresent([String].self, forKey: .applicationBundleIDs) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )).sorted()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(passwordManagersEnabled, forKey: .passwordManagersEnabled)
        try container.encode(verificationCodesEnabled, forKey: .verificationCodesEnabled)
        try container.encode(bankCardsEnabled, forKey: .bankCardsEnabled)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(applicationBundleIDs, forKey: .applicationBundleIDs)
    }

    func shouldExclude(_ content: ClipboardHistoryContent, sourceBundleID: String?) -> Bool {
        if passwordManagersEnabled, Self.isPasswordManager(sourceBundleID) { return true }
        if let sourceBundleID,
           applicationBundleIDs.contains(sourceBundleID) {
            return true
        }
        let text: String
        switch content {
        case let .text(value):
            text = value
        case let .richText(richText):
            text = richText.plainText
        case .image, .url, .files, .pdf:
            return false
        }
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
            let adjusted = pair.offset.isMultiple(of: 2) ? value : value * 2
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

    @discardableResult
    static func copyRecognizedText(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

enum ClipboardAutoPasteResult: Sendable, Equatable {
    case pasted
    case accessibilityPermissionDenied
    case noEditableTarget
    case failed
}

enum ClipboardAccessibilityPermission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func openSettings() -> Bool {
        NSWorkspace.shared.open(settingsURL)
    }
}

enum ClipboardHistoryAction: String, Sendable, Equatable {
    case copy
    case paste
    case pastePlainText

    var requiresPaste: Bool { self != .copy }
    var writeMode: ClipboardPasteboardWriteMode { self == .pastePlainText ? .plainText : .original }
}

struct ClipboardCleanupSummary: Equatable, Sendable {
    let removedCount: Int
    let reclaimedBytes: Int
    let preservedPinnedCount: Int
}

enum ClipboardPrimaryAction: String, CaseIterable, Identifiable, Sendable {
    case copy
    case paste

    var id: String { rawValue }
    var localizationKey: String { "clipboard.primaryAction.\(rawValue)" }
    var historyAction: ClipboardHistoryAction { self == .paste ? .paste : .copy }
}

enum ClipboardSequentialPasteMode: String, CaseIterable, Identifiable, Sendable {
    case once
    case loop

    var id: String { rawValue }
    var localizationKey: String { "clipboard.sequential.mode.\(rawValue)" }
}

struct ClipboardSequentialPasteQueue: Sendable {
    let items: [ClipboardHistoryItem]
    let mode: ClipboardSequentialPasteMode
    private(set) var currentIndex = 0

    var isActive: Bool {
        !items.isEmpty && (mode == .loop || currentIndex < items.count)
    }

    var currentPosition: Int {
        guard !items.isEmpty else { return 0 }
        return currentIndex % items.count
    }

    mutating func next() -> ClipboardHistoryItem? {
        guard isActive else { return nil }
        let item = items[currentPosition]
        currentIndex += 1
        return item
    }
}

enum ClipboardTextTransform: String, CaseIterable, Identifiable, Sendable {
    case trim
    case uppercase
    case lowercase
    case joinLines
    case urlEncode
    case urlDecode
    case formatJSON

    var id: String { rawValue }
    var localizationKey: String { "clipboard.transform.\(rawValue)" }

    func apply(to text: String) -> String? {
        switch self {
        case .trim:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .joinLines:
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .urlEncode:
            var unreserved = CharacterSet.alphanumerics
            unreserved.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: unreserved)
        case .urlDecode:
            return text.removingPercentEncoding
        case .formatJSON:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(object),
                  let formatted = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  ) else { return nil }
            return String(data: formatted, encoding: .utf8)
        }
    }
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

/// 记录快捷面板弹出前的前台 App，自动粘贴时只消费一次，避免把内容发回 MenuTools。
@MainActor
final class ClipboardAutoPasteTargetTracker {
    static let shared = ClipboardAutoPasteTargetTracker()

    private var processIdentifier: pid_t?

    func rememberFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication else { return }
        remember(
            processIdentifier: application.processIdentifier,
            currentProcessIdentifier: pid_t(ProcessInfo.processInfo.processIdentifier)
        )
    }

    func remember(processIdentifier: pid_t, currentProcessIdentifier: pid_t) {
        guard processIdentifier > 0, processIdentifier != currentProcessIdentifier else {
            self.processIdentifier = nil
            return
        }
        self.processIdentifier = processIdentifier
    }

    func takeProcessIdentifier() -> pid_t? {
        defer { processIdentifier = nil }
        return processIdentifier
    }
}

enum ClipboardHistoryAutoPaste {
    /// 仅在辅助功能权限允许且前台焦点为可编辑控件时发送 Command-V。
    @MainActor
    static func pasteIntoPreviousApplication() -> ClipboardAutoPasteResult {
        let rememberedPID = ClipboardAutoPasteTargetTracker.shared.takeProcessIdentifier()
        guard AXIsProcessTrusted() else { return .accessibilityPermissionDenied }
        let targetApplication: NSRunningApplication?
        if let rememberedPID {
            guard let application = NSRunningApplication(processIdentifier: rememberedPID) else {
                return .noEditableTarget
            }
            targetApplication = application
        } else {
            targetApplication = nil
        }
        let targetPID = targetApplication?.processIdentifier
        if let targetApplication {
            // 先把快捷键前的应用恢复到前台，再读取 AX 焦点。
            // 菜单栏 Popover 关闭期间，目标应用的焦点树可能暂时为空。
            _ = targetApplication.activate(options: [])
        }
        let accessibilityRoot = targetPID.map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        let hasEditableTarget = focusedElementIsEditable(in: accessibilityRoot)
        let targetIsFrontmost = targetPID != nil
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        // 某些 Electron/WebView 输入框不完整暴露 AXEditable/AXRole，但已知目标应用
        // 已被恢复到前台时，发送 Command-V 仍能正确交给当前输入框。
        guard hasEditableTarget || targetIsFrontmost else { return .noEditableTarget }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .failed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // 目标 App 已在前台时必须通过系统事件 tap 投递。部分 App（TextEdit、WebView）
        // 对 postToPid 投递的 flags 处理不完整，会把 Command-V 解释成控制字符。
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return .pasted
    }

    private static func focusedElementIsEditable(in accessibilityRoot: AXUIElement) -> Bool {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            accessibilityRoot,
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
    private var retentionByContentType: [ClipboardHistoryContentType: TimeInterval]

    init(
        limit: Int = 50,
        sensitiveLifetime: TimeInterval = 60,
        retentionDuration: TimeInterval? = nil,
        storageLimitBytes: Int = .max,
        retentionByContentType: [ClipboardHistoryContentType: TimeInterval] = [:],
        items: [ClipboardHistoryItem] = []
    ) {
        self.items = items
        self.limit = max(1, limit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        self.retentionDuration = retentionDuration.map { max(0, $0) }
        self.storageLimitBytes = max(0, storageLimitBytes)
        self.retentionByContentType = retentionByContentType.mapValues { max(0, $0) }
        applyAutomaticCleanup(now: Date())
    }

    @discardableResult
    mutating func insert(
        _ content: ClipboardHistoryContent,
        now: Date,
        sourceBundleID: String? = nil,
        retentionOverride: TimeInterval? = nil,
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
        if existing?.isSensitive == true {
            expiresAt = now.addingTimeInterval(sensitiveLifetime)
        } else if case let .text(text) = content,
           ClipboardSensitivity.isSensitiveText(text) {
            expiresAt = now.addingTimeInterval(sensitiveLifetime)
        } else if let retentionOverride, retentionOverride > 0 {
            expiresAt = now.addingTimeInterval(retentionOverride)
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
            title: existing?.title,
            tags: existing?.tags ?? [],
            note: existing?.note,
            isSensitive: existing?.isSensitive ?? false,
            recognizedText: existing?.recognizedText
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
        title: String?? = nil,
        tags: [String]? = nil,
        note: String?? = nil,
        isSensitive: Bool? = nil,
        recognizedText: String?? = nil
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[index].title = title }
        if let tags { items[index].tags = tags }
        if let note { items[index].note = note }
        if let isSensitive { items[index].isSensitive = isSensitive }
        if let recognizedText { items[index].recognizedText = recognizedText }
    }

    mutating func setSensitive(id: UUID, isSensitive: Bool, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSensitive = isSensitive
        items[index].expiresAt = isSensitive ? now.addingTimeInterval(sensitiveLifetime) : nil
    }

    mutating func setRecognizedText(_ recognizedText: String?, for id: UUID) {
        updateMetadata(id: id, recognizedText: recognizedText)
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

    mutating func setRetentionDuration(_ duration: TimeInterval?, for type: ClipboardHistoryContentType, now: Date = Date()) {
        if let duration {
            retentionByContentType[type] = max(0, duration)
        } else {
            retentionByContentType.removeValue(forKey: type)
        }
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
        items.removeAll { item in
            guard !item.isPinned, let duration = retentionByContentType[item.content.contentType] else { return false }
            return item.capturedAt < now.addingTimeInterval(-duration)
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
    private static let fileName = "ClipboardHistory.sqlite3"
    private static let sqliteHeader = Data("SQLite format 3\0".utf8)

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

    static func blobsURL(for databaseURL: URL) -> URL {
        databaseURL.deletingPathExtension().appendingPathExtension("blobs")
    }

    static func backupURL(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("backup")
    }

    static func load(from url: URL) -> [ClipboardHistoryItem] {
        if FileManager.default.fileExists(atPath: url.path) {
            if isSQLiteDatabase(at: url) {
                if let items = try? loadDatabase(from: url) {
                    return items
                }
                // 当前数据库损坏时回退到最近一次成功写入的备份，避免把历史误显示为空。
                let backupURL = backupURL(for: url)
                if isSQLiteDatabase(at: backupURL), let items = try? loadDatabase(from: backupURL) {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.copyItem(at: backupURL, to: url)
                    return items
                }
                return []
            }
            let backupURL = backupURL(for: url)
            if isSQLiteDatabase(at: backupURL), let items = try? loadDatabase(from: backupURL) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.copyItem(at: backupURL, to: url)
                return items
            }
            guard let legacyItems = loadLegacyJSON(from: url) else { return [] }
            do {
                try save(legacyItems, to: url)
            } catch {
                // 迁移失败不应阻止本次恢复，仍把已解码的旧历史交给服务层。
            }
            return legacyItems
        }

        let legacyURL = url.deletingLastPathComponent().appendingPathComponent("ClipboardHistory.json")
        guard legacyURL != url,
              let legacyItems = loadLegacyJSON(from: legacyURL) else { return [] }
        do {
            try save(legacyItems, to: url)
            let backupURL = legacyURL.appendingPathExtension("migrated")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: legacyURL, to: backupURL)
        } catch {
            // 保留旧 JSON，下一次启动仍可重试迁移。
        }
        return legacyItems
    }

    static func save(_ items: [ClipboardHistoryItem], to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path), !isSQLiteDatabase(at: url) {
            try fileManager.removeItem(at: url)
        }

        // 在覆盖前保留最近一次可读取的数据库；下次启动发现损坏时可回退。
        if isSQLiteDatabase(at: url) {
            let backupURL = backupURL(for: url)
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: url, to: backupURL)
        }

        let persistableItems = items.filter { !$0.isSensitive }
        let blobsDirectory = blobsURL(for: url)
        try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        var desiredBlobNames = Set<String>()
        let records = try persistableItems.enumerated().map { position, item in
            let metadata = try metadataRecord(for: item, blobsDirectory: blobsDirectory, desiredBlobNames: &desiredBlobNames)
            return (position, item.id.uuidString, metadata)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw persistenceError("无法打开剪贴板历史数据库")
        }
        defer { sqlite3_close(database) }
        try configure(database)
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute(database, "DELETE FROM clipboard_items")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO clipboard_items(position, id, metadata) VALUES (?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw persistenceError("无法准备剪贴板历史写入")
            }
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, Int64(record.0))
                bind(record.1, to: statement, column: 2)
                bind(record.2, to: statement, column: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw persistenceError("无法写入剪贴板历史")
                }
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }

        for name in (try? fileManager.contentsOfDirectory(atPath: blobsDirectory.path)) ?? []
        where !desiredBlobNames.contains(name) {
            try? fileManager.removeItem(at: blobsDirectory.appendingPathComponent(name))
        }
    }

    private static func loadLegacyJSON(from url: URL) -> [ClipboardHistoryItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode([ClipboardHistoryItem].self, from: data)
    }

    private static func isSQLiteDatabase(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: sqliteHeader.count)) == sqliteHeader
    }

    private static func loadDatabase(from url: URL) throws -> [ClipboardHistoryItem] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw persistenceError("无法读取剪贴板历史数据库")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT metadata FROM clipboard_items ORDER BY position ASC",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw persistenceError("剪贴板历史数据库结构无效")
        }
        defer { sqlite3_finalize(statement) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let blobsDirectory = blobsURL(for: url)
        var items: [ClipboardHistoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let metadata = data(statement, column: 0),
                  let decryptedMetadata = try? ClipboardHistoryEncryption.open(metadata),
                  let item = try? decoder.decode(ClipboardHistoryItem.self, from: decryptedMetadata),
                  let hydrated = hydrate(item, blobsDirectory: blobsDirectory) else { continue }
            items.append(hydrated)
        }
        return items
    }

    private static func metadataRecord(
        for item: ClipboardHistoryItem,
        blobsDirectory: URL,
        desiredBlobNames: inout Set<String>
    ) throws -> Data {
        let content: ClipboardHistoryContent
        switch item.content {
        case let .image(image):
            try writeBlob(image, suffix: "image", itemID: item.id, directory: blobsDirectory, desired: &desiredBlobNames)
            content = .image(Data())
        case let .richText(richText):
            if let html = richText.html {
                try writeBlob(html, suffix: "html", itemID: item.id, directory: blobsDirectory, desired: &desiredBlobNames)
            }
            if let rtf = richText.rtf {
                try writeBlob(rtf, suffix: "rtf", itemID: item.id, directory: blobsDirectory, desired: &desiredBlobNames)
            }
            content = .richText(ClipboardRichText(plainText: richText.plainText, html: nil, rtf: nil))
        case .text, .url, .files:
            content = item.content
        case let .pdf(data):
            try writeBlob(data, suffix: "pdf", itemID: item.id, directory: blobsDirectory, desired: &desiredBlobNames)
            content = .pdf(Data())
        }
        let metadataItem = ClipboardHistoryItem(
            id: item.id,
            content: content,
            capturedAt: item.capturedAt,
            expiresAt: item.expiresAt,
            isPinned: item.isPinned,
            sourceBundleID: item.sourceBundleID,
            title: item.title,
            tags: item.tags,
            note: item.note,
            isSensitive: false,
            recognizedText: item.recognizedText
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try ClipboardHistoryEncryption.seal(encoder.encode(metadataItem))
    }

    private static func hydrate(_ item: ClipboardHistoryItem, blobsDirectory: URL) -> ClipboardHistoryItem? {
        let content: ClipboardHistoryContent
        switch item.content {
        case .image:
            guard let image = readBlob(item.id, "image", blobsDirectory) else { return nil }
            content = .image(image)
        case let .richText(richText):
            content = .richText(ClipboardRichText(
                plainText: richText.plainText,
                html: readBlob(item.id, "html", blobsDirectory),
                rtf: readBlob(item.id, "rtf", blobsDirectory)
            ))
        case .text, .url, .files:
            content = item.content
        case .pdf:
            guard let data = readBlob(item.id, "pdf", blobsDirectory) else { return nil }
            content = .pdf(data)
        }
        return ClipboardHistoryItem(
            id: item.id,
            content: content,
            capturedAt: item.capturedAt,
            expiresAt: item.expiresAt,
            isPinned: item.isPinned,
            sourceBundleID: item.sourceBundleID,
            title: item.title,
            tags: item.tags,
            note: item.note,
            isSensitive: false,
            recognizedText: item.recognizedText
        )
    }

    private static func writeBlob(
        _ data: Data,
        suffix: String,
        itemID: UUID,
        directory: URL,
        desired: inout Set<String>
    ) throws {
        let name = "\(itemID.uuidString).\(suffix)"
        desired.insert(name)
        let url = directory.appendingPathComponent(name)
        let encrypted = try ClipboardHistoryEncryption.seal(data)
        if (try? Data(contentsOf: url)) != encrypted {
            try encrypted.write(to: url, options: .atomic)
        }
    }

    private static func readBlob(_ itemID: UUID, _ suffix: String, _ directory: URL) -> Data? {
        guard let data = try? Data(contentsOf: blobURL(itemID, suffix, directory)) else { return nil }
        return try? ClipboardHistoryEncryption.open(data)
    }

    private static func blobURL(_ itemID: UUID, _ suffix: String, _ directory: URL) -> URL {
        directory.appendingPathComponent("\(itemID.uuidString).\(suffix)")
    }

    private static func configure(_ database: OpaquePointer) throws {
        try execute(database, "PRAGMA journal_mode=DELETE")
        try execute(database, "PRAGMA synchronous=NORMAL")
        try execute(database, """
            CREATE TABLE IF NOT EXISTS clipboard_items (
                position INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                metadata BLOB NOT NULL
            )
            """)
        try execute(database, "PRAGMA user_version=1")
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw persistenceError("剪贴板历史数据库操作失败")
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, column: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, column, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private static func bind(_ value: Data, to statement: OpaquePointer, column: Int32) {
        value.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(
                statement,
                column,
                bytes.baseAddress,
                Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    private static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func persistenceError(_ message: String) -> NSError {
        NSError(domain: "MenuTools.ClipboardHistoryPersistence", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

}

/// 图片识别结果。必须区分“图上确实没有内容”和“识别链路失败”：
/// 前者重试没有意义，后者（Vision 在系统负载高时整批返回空结果）值得重试。
enum ClipboardImageRecognitionOutcome: Sendable, Equatable {
    case recognized(String)
    case noContent
    case failed
}

enum ClipboardImageRecognitionPolicy {
    /// 单条记录的识别尝试次数上限。
    static let attemptLimit = 3
    /// 两次尝试之间的退避间隔。
    static let retryDelay: Duration = .milliseconds(200)
    /// 用户重新打开面板刷新时，最多补试多少条失败记录，避免集中重试压满识别链路。
    static let refreshRetryLimit = 4
}

enum ClipboardImageTextRecognition {
    static func outcome(for data: Data) -> ClipboardImageRecognitionOutcome {
        guard let image = NSImage(data: data) else { return .failed }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return .failed
        }
        do {
            return .recognized(try ScreenshotOCRService.recognize(cgImage))
        } catch ScreenshotOCRError.noText {
            return .noContent
        } catch {
            return .failed
        }
    }
}

/// 识别失败时按策略重试；每次尝试单独占用闸门，退避等待期间让出给截图 OCR 等其他入口。
private func clipboardRecognizeWithRetries(
    _ data: Data,
    recognizer: @Sendable (Data) async -> ClipboardImageRecognitionOutcome,
    gate: VisionRecognitionGate
) async -> ClipboardImageRecognitionOutcome {
    var outcome = ClipboardImageRecognitionOutcome.failed
    for attempt in 1 ... ClipboardImageRecognitionPolicy.attemptLimit {
        await gate.acquire()
        guard !Task.isCancelled else {
            await gate.release()
            return .failed
        }
        outcome = await recognizer(data)
        await gate.release()
        guard case .failed = outcome else { return outcome }
        guard attempt < ClipboardImageRecognitionPolicy.attemptLimit else { break }
        try? await Task.sleep(for: ClipboardImageRecognitionPolicy.retryDelay)
        if Task.isCancelled { return .failed }
    }
    return outcome
}

/// 负责监听系统剪贴板并向界面提供可操作的历史记录。
@MainActor
@Observable
final class ClipboardHistoryService {
    static let shared = ClipboardHistoryService(feedbackPresenter: {
        ClipboardFeedbackHUDController.shared.show($0)
    })

    private var buffer: ClipboardHistoryBuffer
    private let persistenceURL: URL?
    private let persistenceLoader: @Sendable (URL) async -> [ClipboardHistoryItem]
    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults
    private let frontmostApplicationBundleIdentifierProvider: @MainActor () -> String?
    private let autoPasteAction: @MainActor () -> ClipboardAutoPasteResult
    private let feedbackPresenter: @MainActor (ClipboardCopyFeedback) -> Void
    private let imageTextRecognizer: @Sendable (Data) async -> ClipboardImageRecognitionOutcome
    private(set) var limit: Int
    private let sensitiveLifetime: TimeInterval
    private var lastChangeCount: Int = -1
    private var historyMutationGeneration = 0
    private var loadingTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var undoExpirationTask: Task<Void, Never>?
    private var feedbackExpirationTask: Task<Void, Never>?
    private var imageRecognitionTasks: [UUID: Task<Void, Never>] = [:]
    private let imageRecognitionGate = VisionRecognitionGate.shared
    private var failedImageRecognitionIDs: Set<UUID> = []
    private var sequentialPasteQueue: ClipboardSequentialPasteQueue?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var lastRemovedItems: [ClipboardHistoryItem] = []

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var searchIndex = ClipboardHistorySearchIndex()
    private(set) var currentItemCount = 0
    private(set) var hasLoadedPersistedHistory: Bool
    private(set) var isRecordingPaused: Bool
    private(set) var excludedBundleIDs: [String]
    private(set) var sensitiveRules: ClipboardSensitiveRules
    private(set) var applicationPolicies: [ClipboardApplicationPolicy]
    private(set) var retentionDays: Int
    private(set) var storageLimitBytes: Int
    private(set) var retentionByContentType: [ClipboardHistoryContentType: TimeInterval]
    private(set) var autoPasteAfterCopy: Bool
    private(set) var primaryAction: ClipboardPrimaryAction
    private(set) var sequentialPasteMode: ClipboardSequentialPasteMode
    private(set) var copyFeedback: ClipboardCopyFeedback?
    private(set) var persistenceErrorMessage: String?
    /// 识别失败、等待补试的图片条数；失败不再静默。
    var failedImageRecognitionCount: Int { failedImageRecognitionIDs.count }
    private(set) var lastCleanupSummary: ClipboardCleanupSummary?
    var canUndoLastRemoval: Bool { !lastRemovedItems.isEmpty }

    init(
        limit: Int? = nil,
        sensitiveLifetime: TimeInterval = 60,
        persistenceURL: URL? = ClipboardHistoryPersistence.defaultURL(),
        pasteboard: NSPasteboard = .general,
        userDefaults: UserDefaults = .standard,
        autoPasteAction: @escaping @MainActor () -> ClipboardAutoPasteResult = ClipboardHistoryAutoPaste.pasteIntoPreviousApplication,
        feedbackPresenter: @escaping @MainActor (ClipboardCopyFeedback) -> Void = { _ in },
        imageTextRecognizer: @escaping @Sendable (Data) async -> ClipboardImageRecognitionOutcome = { data in
            await Task.detached(priority: .utility) {
                ClipboardImageTextRecognition.outcome(for: data)
            }.value
        },
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
        let configuredRetentionByContentType = Self.loadRetentionByContentType(from: userDefaults)
        self.persistenceURL = persistenceURL
        self.persistenceLoader = persistenceLoader
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.frontmostApplicationBundleIdentifierProvider = frontmostApplicationBundleIdentifierProvider
        self.autoPasteAction = autoPasteAction
        self.feedbackPresenter = feedbackPresenter
        self.imageTextRecognizer = imageTextRecognizer
        self.limit = max(1, configuredLimit)
        self.sensitiveLifetime = max(0, sensitiveLifetime)
        self.hasLoadedPersistedHistory = persistenceURL == nil
        self.isRecordingPaused = userDefaults.bool(forKey: StorageKey.isRecordingPaused)
        self.excludedBundleIDs = Array(
            Set(userDefaults.stringArray(forKey: StorageKey.excludedBundleIDs) ?? [])
        ).sorted()
        self.sensitiveRules = Self.loadSensitiveRules(from: userDefaults)
        self.applicationPolicies = Self.loadApplicationPolicies(from: userDefaults)
        self.retentionDays = max(0, userDefaults.object(forKey: StorageKey.retentionDays) as? Int ?? 0)
        self.storageLimitBytes = max(0, userDefaults.object(forKey: StorageKey.storageLimitBytes) as? Int ?? .max)
        self.retentionByContentType = configuredRetentionByContentType
        let legacyAutoPaste = userDefaults.bool(forKey: StorageKey.autoPasteAfterCopy)
        let configuredPrimaryAction = userDefaults.string(forKey: StorageKey.primaryAction)
            .flatMap(ClipboardPrimaryAction.init(rawValue:)) ?? (legacyAutoPaste ? .paste : .copy)
        self.primaryAction = configuredPrimaryAction
        self.sequentialPasteMode = userDefaults.string(forKey: StorageKey.sequentialPasteMode)
            .flatMap(ClipboardSequentialPasteMode.init(rawValue:)) ?? .once
        self.autoPasteAfterCopy = configuredPrimaryAction == .paste
        self.copyFeedback = nil
        self.persistenceErrorMessage = nil
        self.lastCleanupSummary = nil
        buffer = ClipboardHistoryBuffer(
            limit: configuredLimit,
            sensitiveLifetime: sensitiveLifetime,
            retentionDuration: Self.retentionDuration(for: max(0, userDefaults.object(forKey: StorageKey.retentionDays) as? Int ?? 0)),
            storageLimitBytes: max(0, userDefaults.object(forKey: StorageKey.storageLimitBytes) as? Int ?? .max),
            retentionByContentType: configuredRetentionByContentType
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
                retentionByContentType: retentionByContentType,
                items: restored
            )
            restoredBuffer.applyAutomaticCleanup(now: Date())
            buffer = restoredBuffer
            items = restoredBuffer.items
            persist()
            items.forEach(scheduleImageTextRecognitionIfNeeded)
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
    /// 面板打开等用户动作也会走到这里，顺带补试此前识别失败的图片。
    func refresh() {
        guard hasLoadedPersistedHistory else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadPersistedHistory()
                self.refreshLoadedHistory()
                self.retryFailedImageRecognitions()
            }
            return
        }
        refreshLoadedHistory()
        retryFailedImageRecognitions()
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
        let policy = applicationPolicy(for: sourceBundleID)
        if ClipboardHistoryRecordingPolicy.shouldRecord(
            isPaused: isRecordingPaused,
            sourceBundleID: sourceBundleID,
            excludedBundleIDs: excludedBundleIDs
        ), policy?.record != false,
           let content = readContent(from: pasteboard),
           !(policy?.sensitiveRules ?? sensitiveRules).shouldExclude(content, sourceBundleID: sourceBundleID) {
            let retention = policy?.retentionDays.flatMap(Self.retentionDuration)
            if let inserted = buffer.insert(content, now: now, sourceBundleID: sourceBundleID, retentionOverride: retention) {
                historyChanged = true
                scheduleImageTextRecognitionIfNeeded(inserted)
            }
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
        let action: ClipboardHistoryAction = effectiveAutoPaste(for: frontmostApplicationBundleIdentifierProvider()) ? .paste : .copy
        return perform(item.content, action: action)
    }

    @discardableResult
    func copy(_ content: ClipboardHistoryContent) -> Bool {
        let action: ClipboardHistoryAction = effectiveAutoPaste(for: frontmostApplicationBundleIdentifierProvider()) ? .paste : .copy
        return perform(content, action: action)
    }

    @discardableResult
    func perform(_ item: ClipboardHistoryItem, action: ClipboardHistoryAction) -> Bool {
        perform(item.content, action: action)
    }

    @discardableResult
    func perform(_ content: ClipboardHistoryContent, action: ClipboardHistoryAction) -> Bool {
        let pasteboard = self.pasteboard
        let targetBundleID = frontmostApplicationBundleIdentifierProvider()
        guard ClipboardHistoryPasteboardWriter.write(content, to: pasteboard, mode: action.writeMode) else {
            return false
        }
        if !isRecordingPaused,
           !sensitiveRules.shouldExclude(content, sourceBundleID: nil) {
            historyMutationGeneration &+= 1
            let retention = applicationPolicy(for: targetBundleID)?.retentionDays
                .flatMap(Self.retentionDuration)
            let inserted = buffer.insert(content, now: Date(), retentionOverride: retention)
            synchronizeItems()
            persist()
            if let inserted { scheduleImageTextRecognitionIfNeeded(inserted) }
        }
        lastChangeCount = pasteboard.changeCount
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
        if action.requiresPaste, effectiveAutoPaste(for: targetBundleID) || action == .paste || action == .pastePlainText {
            copyFeedback = nil
            feedbackExpirationTask?.cancel()
            // 让调用方先关闭菜单栏弹窗，再将 Command-V 发回此前的前台应用。
            // 否则按键会被仍在关闭过程中的 Popover 接收。
            let autoPasteAction = self.autoPasteAction
            Task { @MainActor [weak self] in
                self?.publishFeedback(ClipboardCopyFeedback(autoPasteResult: autoPasteAction()))
            }
        } else {
            publishFeedback(.copied)
        }
        return true
    }

    /// 仅清空当前系统剪贴板；历史记录是独立数据，不能被这个动作连带删除。
    func clearSystemClipboard() {
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
        currentItemCount = pasteboard.pasteboardItems?.count ?? 0
        copyFeedback = nil
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

    func setRetentionDays(_ days: Int, for type: ClipboardHistoryContentType) {
        let normalized = max(0, days)
        let duration = normalized == 0 ? nil : TimeInterval(normalized * 86_400)
        if normalized == 0 {
            retentionByContentType.removeValue(forKey: type)
        } else {
            retentionByContentType[type] = duration
        }
        let persisted = Dictionary(uniqueKeysWithValues: retentionByContentType.map { ($0.key.rawValue, Int($0.value / 86_400)) })
        userDefaults.set(persisted, forKey: StorageKey.retentionByContentType)
        buffer.setRetentionDuration(duration, for: type)
        synchronizeItems()
        applyAutomaticCleanup()
    }

    func setAutoPasteAfterCopy(_ enabled: Bool) {
        setPrimaryAction(enabled ? .paste : .copy)
    }

    func setPrimaryAction(_ action: ClipboardPrimaryAction) {
        guard primaryAction != action else { return }
        primaryAction = action
        autoPasteAfterCopy = action == .paste
        userDefaults.set(action.rawValue, forKey: StorageKey.primaryAction)
        userDefaults.set(autoPasteAfterCopy, forKey: StorageKey.autoPasteAfterCopy)
    }

    func setSequentialPasteMode(_ mode: ClipboardSequentialPasteMode) {
        sequentialPasteMode = mode
        userDefaults.set(mode.rawValue, forKey: StorageKey.sequentialPasteMode)
    }

    var hasActiveSequentialPaste: Bool {
        sequentialPasteQueue?.isActive == true
    }

    var sequentialPasteProgress: (current: Int, total: Int)? {
        guard let queue = sequentialPasteQueue, queue.isActive else { return nil }
        return (queue.currentPosition + 1, queue.items.count)
    }

    func beginSequentialPaste(itemIDs: [UUID]) {
        let selected = itemIDs.compactMap { id in buffer.items.first(where: { $0.id == id }) }
        sequentialPasteQueue = ClipboardSequentialPasteQueue(items: selected, mode: sequentialPasteMode)
    }

    func cancelSequentialPaste() {
        sequentialPasteQueue = nil
    }

    @discardableResult
    func pasteNextSequentialItem() -> Bool {
        guard var queue = sequentialPasteQueue,
              let item = queue.next() else {
            sequentialPasteQueue = nil
            return false
        }
        guard perform(item, action: .paste) else { return false }
        sequentialPasteQueue = queue.isActive ? queue : nil
        return true
    }

    @discardableResult
    func copyTransformed(_ item: ClipboardHistoryItem, transform: ClipboardTextTransform) -> Bool {
        guard !item.isSensitive,
              let text = item.content.plainTextRepresentation,
              let transformed = transform.apply(to: text) else { return false }
        return copy(.text(transformed))
    }

    func setSensitiveRules(_ rules: ClipboardSensitiveRules) {
        guard sensitiveRules != rules else { return }
        sensitiveRules = rules
        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: StorageKey.sensitiveRules)
        }
    }

    func setApplicationPolicy(_ policy: ClipboardApplicationPolicy) {
        guard !policy.bundleID.isEmpty else { return }
        applicationPolicies.removeAll { $0.bundleID == policy.bundleID }
        applicationPolicies.append(policy)
        applicationPolicies.sort { $0.bundleID < $1.bundleID }
        persistApplicationPolicies()
    }

    func removeApplicationPolicy(for bundleID: String) {
        applicationPolicies.removeAll { $0.bundleID == bundleID }
        persistApplicationPolicies()
    }

    func applicationPolicy(for bundleID: String?) -> ClipboardApplicationPolicy? {
        guard let bundleID else { return nil }
        return applicationPolicies.first { $0.bundleID == bundleID }
    }

    func effectiveAutoPaste(for bundleID: String?) -> Bool {
        applicationPolicy(for: bundleID)?.autoPaste ?? autoPasteAfterCopy
    }

    func addSensitiveBundleID(_ bundleID: String) {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var rules = sensitiveRules
        rules.applicationBundleIDs = Array(Set(rules.applicationBundleIDs + [normalized])).sorted()
        setSensitiveRules(rules)
    }

    func removeSensitiveBundleID(_ bundleID: String) {
        var rules = sensitiveRules
        rules.applicationBundleIDs.removeAll { $0 == bundleID }
        setSensitiveRules(rules)
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

    func setPinned(_ isPinned: Bool, for ids: Set<UUID>) {
        let existingIDs = Set(buffer.items.map(\.id)).intersection(ids)
        guard !existingIDs.isEmpty else { return }
        historyMutationGeneration &+= 1
        for id in existingIDs where buffer.items.contains(where: { $0.id == id && $0.isPinned != isPinned }) {
            buffer.togglePinned(id: id)
        }
        synchronizeItems()
        persist()
    }

    func setTags(_ tags: [String], for id: UUID) {
        guard buffer.items.contains(where: { $0.id == id }) else { return }
        let normalized = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        historyMutationGeneration &+= 1
        buffer.updateMetadata(id: id, tags: normalized)
        synchronizeItems()
        persist()
    }

    func setNote(_ note: String?, for id: UUID) {
        guard buffer.items.contains(where: { $0.id == id }) else { return }
        let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        historyMutationGeneration &+= 1
        buffer.updateMetadata(id: id, note: normalized?.isEmpty == true ? nil : normalized)
        synchronizeItems()
        persist()
    }

    func setTitle(_ title: String?, for id: UUID) {
        guard buffer.items.contains(where: { $0.id == id }) else { return }
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        historyMutationGeneration &+= 1
        buffer.updateMetadata(id: id, title: normalized?.isEmpty == true ? nil : normalized)
        synchronizeItems()
        persist()
    }

    func setSensitive(_ isSensitive: Bool, for id: UUID) {
        guard buffer.items.contains(where: { $0.id == id }) else { return }
        historyMutationGeneration &+= 1
        buffer.setSensitive(id: id, isSensitive: isSensitive)
        synchronizeItems()
        persist()
    }

    func setSensitive(_ isSensitive: Bool, for ids: Set<UUID>) {
        let existingIDs = Set(buffer.items.map(\.id)).intersection(ids)
        guard !existingIDs.isEmpty else { return }
        historyMutationGeneration &+= 1
        for id in existingIDs {
            buffer.setSensitive(id: id, isSensitive: isSensitive)
        }
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
        let ids = Set(buffer.items.map(\.id))
        guard !ids.isEmpty else {
            // 即使异步历史尚未载入，清空动作也必须使正在读取的旧快照失效。
            historyMutationGeneration &+= 1
            buffer.clearAll()
            synchronizeItems()
            persist()
            return
        }
        remove(ids: ids)
    }

    func clearUnpinnedHistory() {
        remove(ids: Set(buffer.items.lazy.filter { !$0.isPinned }.map(\.id)))
    }

    /// 归档导入采用合并语义：按记录 ID 去重，并继续受容量和保留期限约束。
    func importItems(_ importedItems: [ClipboardHistoryItem]) {
        let safeItems = importedItems.filter { !$0.isSensitive }
        guard !safeItems.isEmpty else { return }
        historyMutationGeneration &+= 1
        buffer.restore(safeItems)
        synchronizeItems()
        persist()
        safeItems.forEach(scheduleImageTextRecognitionIfNeeded)
    }

    private func applyAutomaticCleanup(now: Date = Date()) {
        let before = buffer.items
        buffer.setAutomaticCleanup(
            retentionDuration: Self.retentionDuration(for: retentionDays),
            storageLimitBytes: storageLimitBytes,
            now: now
        )
        guard buffer.items != before else {
            lastCleanupSummary = nil
            return
        }
        let beforeBytes = before.reduce(0) { $0 + $1.content.storageSize }
        let afterBytes = buffer.items.reduce(0) { $0 + $1.content.storageSize }
        lastCleanupSummary = ClipboardCleanupSummary(
            removedCount: max(0, before.count - buffer.items.count),
            reclaimedBytes: max(0, beforeBytes - afterBytes),
            preservedPinnedCount: buffer.items.count(where: \.isPinned)
        )
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

    private func publishFeedback(_ feedback: ClipboardCopyFeedback) {
        copyFeedback = feedback
        feedbackPresenter(feedback)
        feedbackExpirationTask?.cancel()
        feedbackExpirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, self?.copyFeedback == feedback else { return }
            self?.copyFeedback = nil
            self?.feedbackExpirationTask = nil
        }
    }

    private func scheduleImageTextRecognitionIfNeeded(_ item: ClipboardHistoryItem) {
        guard item.recognizedText == nil,
              case let .image(data) = item.content,
              imageRecognitionTasks[item.id] == nil else {
            return
        }
        let itemID = item.id
        let recognizer = imageTextRecognizer
        let recognitionGate = imageRecognitionGate
        imageRecognitionTasks[itemID] = Task { @MainActor [weak self] in
            let outcome = await clipboardRecognizeWithRetries(
                data,
                recognizer: recognizer,
                gate: recognitionGate
            )
            guard let self else { return }
            defer { imageRecognitionTasks[itemID] = nil }
            guard buffer.items.contains(where: { $0.id == itemID && $0.content == item.content }) else {
                failedImageRecognitionIDs.remove(itemID)
                return
            }
            switch outcome {
            case let .recognized(text):
                let recognizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !recognizedText.isEmpty else {
                    failedImageRecognitionIDs.remove(itemID)
                    return
                }
                failedImageRecognitionIDs.remove(itemID)
                historyMutationGeneration &+= 1
                buffer.setRecognizedText(recognizedText, for: itemID)
                synchronizeItems()
                persist()
            case .noContent:
                failedImageRecognitionIDs.remove(itemID)
            case .failed:
                // 记录失败，等用户下次打开面板刷新时再补试，避免静默丢失 OCR/二维码结果。
                failedImageRecognitionIDs.insert(itemID)
            }
        }
    }

    /// 识别一直失败的图片在用户重新打开面板时补试，最多补试固定条数。
    private func retryFailedImageRecognitions() {
        guard !failedImageRecognitionIDs.isEmpty else { return }
        let candidates = failedImageRecognitionIDs
            .compactMap { id in buffer.items.first { $0.id == id && $0.recognizedText == nil } }
            .prefix(ClipboardImageRecognitionPolicy.refreshRetryLimit)
        candidates.forEach(scheduleImageTextRecognitionIfNeeded)
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardHistoryContent? {
        ClipboardHistoryPasteboardReader.content(from: pasteboard.pasteboardItems ?? [])
    }

    private func synchronizeItems() {
        let nextItems = buffer.items
        let nextIDs = Set(nextItems.map(\.id))
        failedImageRecognitionIDs.formIntersection(nextIDs)
        for removedID in Array(searchIndex.values.keys) where !nextIDs.contains(removedID) {
            searchIndex.remove(removedID)
        }
        nextItems.forEach { item in
            if items.first(where: { $0.id == item.id }) != item {
                searchIndex.upsert(item)
            }
        }
        items = nextItems
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            try ClipboardHistoryPersistence.save(buffer.items, to: persistenceURL)
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
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

    private static func loadApplicationPolicies(from defaults: UserDefaults) -> [ClipboardApplicationPolicy] {
        guard let data = defaults.data(forKey: StorageKey.applicationPolicies),
              let policies = try? JSONDecoder().decode([ClipboardApplicationPolicy].self, from: data) else { return [] }
        return policies.filter { !$0.bundleID.isEmpty }
    }

    private func persistApplicationPolicies() {
        if let data = try? JSONEncoder().encode(applicationPolicies) {
            userDefaults.set(data, forKey: StorageKey.applicationPolicies)
        }
    }

    private static func loadRetentionByContentType(from defaults: UserDefaults) -> [ClipboardHistoryContentType: TimeInterval] {
        guard let values = defaults.dictionary(forKey: StorageKey.retentionByContentType) as? [String: Int] else { return [:] }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, days in
            guard let type = ClipboardHistoryContentType(rawValue: key), days > 0 else { return nil }
            return (type, TimeInterval(days * 86_400))
        })
    }

    private enum StorageKey {
        static let isRecordingPaused = "clipboard.isRecordingPaused"
        static let excludedBundleIDs = "clipboard.excludedBundleIDs"
        static let sensitiveRules = "clipboard.sensitiveRules"
        static let retentionDays = "clipboard.retentionDays"
        static let storageLimitBytes = "clipboard.storageLimitBytes"
        static let retentionByContentType = "clipboard.retentionByContentType"
        static let autoPasteAfterCopy = "clipboard.autoPasteAfterCopy"
        static let primaryAction = "clipboard.primaryAction"
        static let sequentialPasteMode = "clipboard.sequentialPasteMode"
        static let applicationPolicies = "clipboard.applicationPolicies"
    }
}
