import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// 截图写入格式。WebP 在 macOS 26 的 ImageIO 中由系统原生支持。
enum ScreenshotOutputFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case png
    case jpeg
    case webp

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        }
    }

    var typeIdentifier: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .webp: return UTType.webP.identifier
        }
    }

    var titleKey: String { "screenshot.format.\(rawValue)" }
}

/// 截图输出配置。路径使用普通字符串持久化，避免 UserDefaults 直接编码 URL 的兼容问题。
struct ScreenshotOutputConfiguration: Equatable, Sendable {
    var saveToDisk: Bool
    var directoryURL: URL
    var format: ScreenshotOutputFormat
    var namingTemplate: String

    static func load(from defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> Self {
        let directory: URL
        if let path = defaults.string(forKey: SettingsKey.screenshotDirectory), !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        }
        let format = defaults.string(forKey: SettingsKey.screenshotFormat)
            .flatMap(ScreenshotOutputFormat.init(rawValue:)) ?? .png
        let template = defaults.string(forKey: SettingsKey.screenshotNamingTemplate)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "MenuTools_{datetime}_{mode}"
        let saveToDisk = defaults.object(forKey: SettingsKey.screenshotSaveToDisk) == nil
            ? true
            : defaults.bool(forKey: SettingsKey.screenshotSaveToDisk)
        return Self(saveToDisk: saveToDisk, directoryURL: directory, format: format, namingTemplate: template)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(saveToDisk, forKey: SettingsKey.screenshotSaveToDisk)
        defaults.set(directoryURL.path, forKey: SettingsKey.screenshotDirectory)
        defaults.set(format.rawValue, forKey: SettingsKey.screenshotFormat)
        defaults.set(namingTemplate, forKey: SettingsKey.screenshotNamingTemplate)
    }
}

/// 命名模板解析只负责纯字符串工作，文件去重在 `uniqueURL` 中完成。
enum ScreenshotFileNaming {
    static func makeBaseName(
        template: String,
        mode: ScreenshotCaptureMode,
        date: Date = Date(),
        width: Int? = nil,
        height: Int? = nil,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar

        formatter.dateFormat = "yyyy-MM-dd"
        let dateValue = formatter.string(from: date)
        formatter.dateFormat = "HH-mm-ss"
        let timeValue = formatter.string(from: date)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateTimeValue = formatter.string(from: date)
        let timestampValue = String(Int(date.timeIntervalSince1970))

        var value = template
            .replacingOccurrences(of: "{date}", with: dateValue)
            .replacingOccurrences(of: "{time}", with: timeValue)
            .replacingOccurrences(of: "{datetime}", with: dateTimeValue)
            .replacingOccurrences(of: "{timestamp}", with: timestampValue)
            .replacingOccurrences(of: "{mode}", with: mode.rawValue)
            .replacingOccurrences(of: "{width}", with: width.map(String.init) ?? "")
            .replacingOccurrences(of: "{height}", with: height.map(String.init) ?? "")

        // 模板允许用户写子目录，但禁止绝对路径、`.`、`..` 和系统文件名字符。
        value = value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "_")
        return value.isEmpty ? "MenuTools_Screenshot" : value
    }

    static func uniqueURL(
        directory: URL,
        baseName: String,
        format: ScreenshotOutputFormat,
        fileManager: FileManager = .default
    ) -> URL {
        let ext = format.fileExtension
        let first = directory.appendingPathComponent("\(baseName).\(ext)")
        guard fileManager.fileExists(atPath: first.path) else { return first }
        for index in 2...999 {
            let candidate = directory.appendingPathComponent("\(baseName)-\(index).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(baseName)-\(UUID().uuidString).\(ext)")
    }

    private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: ":*?\"<>|\\\n\r\t")
        return value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 截图历史条目。历史只保存文件元数据，不把大图编码进 UserDefaults。
struct ScreenshotHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let filePath: String
    let createdAt: Date
    let width: Int
    let height: Int
    let format: ScreenshotOutputFormat
    let mode: ScreenshotCaptureMode
    let fileSize: Int64

    init(
        id: UUID = UUID(),
        fileURL: URL,
        createdAt: Date = Date(),
        width: Int,
        height: Int,
        format: ScreenshotOutputFormat,
        mode: ScreenshotCaptureMode,
        fileSize: Int64 = 0
    ) {
        self.id = id
        self.filePath = fileURL.path
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.format = format
        self.mode = mode
        self.fileSize = fileSize
    }

    var fileURL: URL { URL(fileURLWithPath: filePath) }
}

/// 最近截图存储，默认保留 50 条；删除历史不会删除用户保存的截图文件。
@MainActor
@Observable
final class ScreenshotHistoryStore {
    static let shared = ScreenshotHistoryStore()

    private let defaults: UserDefaults
    private let key: String
    private let maximumEntries: Int
    private(set) var entries: [ScreenshotHistoryEntry]

    init(
        defaults: UserDefaults = .standard,
        key: String = SettingsKey.screenshotHistory,
        maximumEntries: Int = 50
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumEntries = max(1, maximumEntries)
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ScreenshotHistoryEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
        self.entries = Array(self.entries.prefix(self.maximumEntries))
    }

    func add(_ entry: ScreenshotHistoryEntry) {
        entries.removeAll { $0.filePath == entry.filePath || $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(maximumEntries))
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func remove(fileURL: URL) {
        entries.removeAll { $0.filePath == fileURL.path }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    func pruneMissingFiles(fileManager: FileManager = .default) {
        entries.removeAll { !fileManager.fileExists(atPath: $0.filePath) }
        persist()
    }

    func update(fileURL: URL, replacingPath oldPath: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.filePath == (oldPath ?? fileURL.path) }) else { return }
        let old = entries[index]
        entries[index] = ScreenshotHistoryEntry(
            id: old.id,
            fileURL: fileURL,
            createdAt: old.createdAt,
            width: old.width,
            height: old.height,
            format: old.format,
            mode: old.mode,
            fileSize: old.fileSize
        )
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 为截图写入 ImageIO 数据，统一处理 PNG/JPEG/WebP 的 UTI 和压缩质量。
enum ScreenshotImageWriter {
    static func write(
        _ image: CGImage,
        to url: URL,
        format: ScreenshotOutputFormat
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else { throw ScreenshotError.stitchFailed }

        let properties: [CFString: Any]
        switch format {
        case .png:
            properties = [:]
        case .jpeg, .webp:
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.stitchFailed }
    }
}

/// 编辑器使用的图片变换。归一化坐标原点位于屏幕左上角，统一在这里转换为 CGImage 像素坐标。
enum ScreenshotImageTransform {
    static func pixelCropRect(normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let normalized = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGRect(
            x: (normalized.minX * imageSize.width).rounded(),
            y: ((1 - normalized.maxY) * imageSize.height).rounded(),
            width: (normalized.width * imageSize.width).rounded(),
            height: (normalized.height * imageSize.height).rounded()
        ).integral
    }

    static func crop(_ data: Data, normalizedRect: CGRect) -> Data? {
        guard let image = image(from: data) else { return nil }
        let rect = pixelCropRect(
            normalizedRect: normalizedRect,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        guard rect.width > 0, rect.height > 0, let cropped = image.cropping(to: rect) else { return nil }
        return encodePNG(cropped)
    }

    static func rotate(_ data: Data, clockwise: Bool) -> Data? {
        guard let image = image(from: data),
              let context = CGContext(
                  data: nil,
                  width: image.height,
                  height: image.width,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        if clockwise {
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
        } else {
            context.translateBy(x: 0, y: CGFloat(image.width))
            context.rotate(by: -.pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = context.makeImage() else { return nil }
        return encodePNG(rotated)
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
