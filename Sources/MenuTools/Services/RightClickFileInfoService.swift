import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RightClickFileInfoFormat: String, Sendable { case text, markdown, json }

/// 图片的扩展元数据；解析与采集分离，便于用合成属性字典做单元测试。
struct RightClickImageMetadata: Codable, Equatable, Sendable {
    var colorModel: String?
    var dpiWidth: Double?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var fNumber: Double?
    var exposureSeconds: Double?
    var focalLength: Double?

    var isEmpty: Bool {
        colorModel == nil && dpiWidth == nil && cameraMake == nil && cameraModel == nil
            && lensModel == nil && iso == nil && fNumber == nil && exposureSeconds == nil
            && focalLength == nil
    }

    static func parse(_ properties: [CFString: Any]) -> RightClickImageMetadata {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let isoRatings = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        return .init(
            colorModel: nonEmpty(properties[kCGImagePropertyColorModel] as? String),
            dpiWidth: positive(properties[kCGImagePropertyDPIWidth] as? NSNumber),
            cameraMake: nonEmpty(tiff[kCGImagePropertyTIFFMake] as? String),
            cameraModel: nonEmpty(tiff[kCGImagePropertyTIFFModel] as? String),
            lensModel: nonEmpty(exif[kCGImagePropertyExifLensModel] as? String),
            iso: (isoRatings?.first?.intValue).flatMap { $0 > 0 ? $0 : nil },
            fNumber: positive(exif[kCGImagePropertyExifFNumber] as? NSNumber),
            exposureSeconds: positive(exif[kCGImagePropertyExifExposureTime] as? NSNumber),
            focalLength: positive(exif[kCGImagePropertyExifFocalLength] as? NSNumber)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func positive(_ value: NSNumber?) -> Double? {
        guard let value, value.doubleValue > 0 else { return nil }
        return value.doubleValue
    }
}

/// 音视频扩展元数据；0 与缺省都视为未上报。
struct RightClickAudioMetadata: Codable, Equatable, Sendable {
    var sampleRate: Double?
    var channelCount: Int?
    var bitRate: Double?

    var isEmpty: Bool { sampleRate == nil && channelCount == nil && bitRate == nil }

    static func parse(_ description: AudioStreamBasicDescription?,
                      bitRate: Double?) -> RightClickAudioMetadata {
        let rate = description.map { $0.mSampleRate } ?? 0
        let channels = description.map { Int($0.mChannelsPerFrame) } ?? 0
        return .init(
            sampleRate: rate > 0 ? rate : nil,
            channelCount: channels > 0 ? channels : nil,
            bitRate: (bitRate ?? 0) > 0 ? bitRate : nil
        )
    }
}

struct RightClickFileInfo: Codable, Equatable, Sendable {
    var name: String
    var path: String
    var sizeBytes: Int64
    var typeIdentifier: String
    var mimeType: String?
    var createdAt: Date?
    var modifiedAt: Date?
    var permissions: String
    var imageWidth: Int?
    var imageHeight: Int?
    var durationSeconds: Double?
    var volumeName: String?
    var image: RightClickImageMetadata?
    var audio: RightClickAudioMetadata?
}

enum RightClickFileInfoService {
    static func collect(_ urls: [URL]) async throws -> [RightClickFileInfo] {
        var result: [RightClickFileInfo] = []
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentTypeKey,
                .creationDateKey, .contentModificationDateKey, .volumeNameKey
            ])
            guard values.isRegularFile == true else { throw RightClickFileError.regularFileRequired }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = values.contentType
            let permissionsValue = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            var width: Int?
            var height: Int?
            var imageMetadata: RightClickImageMetadata?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
                let parsed = RightClickImageMetadata.parse(properties)
                imageMetadata = parsed.isEmpty ? nil : parsed
            }
            var duration: Double?
            var audioMetadata: RightClickAudioMetadata?
            if type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true
                || type?.conforms(to: .audiovisualContent) == true {
                let asset = AVURLAsset(url: url)
                if let loaded = try? await asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(loaded)
                    if seconds.isFinite, seconds >= 0 { duration = seconds }
                }
                let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                let videoTracks = audioTracks.isEmpty
                    ? ((try? await asset.loadTracks(withMediaType: .video)) ?? []) : []
                if let track = audioTracks.first ?? videoTracks.first {
                    let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                    let description = descriptions
                        .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                        .first
                    let bitRate = (try? await track.load(.estimatedDataRate)).map(Double.init)
                    let parsed = RightClickAudioMetadata.parse(description, bitRate: bitRate)
                    audioMetadata = parsed.isEmpty ? nil : parsed
                }
            }
            result.append(.init(
                name: url.lastPathComponent,
                path: url.path,
                sizeBytes: Int64(values.fileSize ?? (attributes[.size] as? NSNumber)?.intValue ?? 0),
                typeIdentifier: type?.identifier ?? "public.data",
                mimeType: type?.preferredMIMEType,
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate,
                permissions: String(format: "%03o", permissionsValue & 0o777),
                imageWidth: width,
                imageHeight: height,
                durationSeconds: duration,
                volumeName: values.volumeName,
                image: imageMetadata,
                audio: audioMetadata
            ))
        }
        return result
    }
}

enum RightClickFileInfoFormatter {
    static func format(_ items: [RightClickFileInfo], as format: RightClickFileInfoFormat,
                       timeZone: TimeZone = .current) -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        case .markdown:
            let header = "| \(L("rc.info.name")) | \(L("rc.info.path")) | \(L("rc.info.size")) | \(L("rc.info.type")) | \(L("rc.info.created")) | \(L("rc.info.modified")) | \(L("rc.info.permissions")) | \(L("rc.info.dimensions")) | \(L("rc.info.duration")) |"
            let separator = "| --- | --- | ---: | --- | --- | --- | --- | --- | ---: |"
            let rows = items.map { item in
                "| \(escapeMarkdown(item.name)) | \(escapeMarkdown(item.path)) | \(size(item.sizeBytes)) | \(escapeMarkdown(type(item))) | \(date(item.createdAt, timeZone: timeZone)) | \(date(item.modifiedAt, timeZone: timeZone)) | \(item.permissions) | \(dimensions(item)) | \(duration(item.durationSeconds)) |"
            }
            let details = items.compactMap { item -> String? in
                let values = extras(item)
                guard !values.isEmpty else { return nil }
                return ([escapeMarkdown(item.name)]
                    + values.map { "- **\($0.0)**: \(escapeMarkdown($0.1))" })
                    .joined(separator: "\n")
            }
            return ([header, separator] + rows + details).joined(separator: "\n")
        case .text:
            return items.map { item in
                (baseLines(item, timeZone: timeZone) + extras(item).map { "\($0.0): \($0.1)" })
                    .joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
    }

    /// 扩展元数据只在实际存在时输出，避免普通文件被空字段淹没。
    private static func extras(_ item: RightClickFileInfo) -> [(String, String)] {
        var values: [(String, String)] = []
        if let volume = item.volumeName { values.append((L("rc.info.volume"), volume)) }
        if let image = item.image {
            if let color = image.colorModel { values.append((L("rc.info.colorModel"), color)) }
            if let dpi = image.dpiWidth { values.append((L("rc.info.dpi"), String(format: "%.0f", dpi))) }
            if let camera = [image.cameraMake, image.cameraModel].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                values.append((L("rc.info.camera"), camera))
            }
            if let lens = image.lensModel { values.append((L("rc.info.lens"), lens)) }
            if let iso = image.iso { values.append((L("rc.info.iso"), "\(iso)")) }
            if let fNumber = image.fNumber { values.append((L("rc.info.fNumber"), String(format: "f/%.1f", fNumber))) }
            if let exposure = image.exposureSeconds {
                values.append((L("rc.info.exposure"), exposureText(exposure)))
            }
            if let focal = image.focalLength {
                values.append((L("rc.info.focalLength"), String(format: "%.0f mm", focal)))
            }
        }
        if let audio = item.audio {
            if let rate = audio.sampleRate {
                values.append((L("rc.info.sampleRate"), String(format: "%.0f Hz", rate)))
            }
            if let channels = audio.channelCount { values.append((L("rc.info.channels"), "\(channels)")) }
            if let bitRate = audio.bitRate {
                values.append((L("rc.info.bitRate"), String(format: "%.0f kbps", bitRate / 1_000)))
            }
        }
        return values
    }

    private static func baseLines(_ item: RightClickFileInfo, timeZone: TimeZone) -> [String] {
        [
            item.name,
            "\(L("rc.info.path")): \(item.path)",
            "\(L("rc.info.size")): \(size(item.sizeBytes))",
            "\(L("rc.info.type")): \(type(item))",
            "\(L("rc.info.created")): \(date(item.createdAt, timeZone: timeZone))",
            "\(L("rc.info.modified")): \(date(item.modifiedAt, timeZone: timeZone))",
            "\(L("rc.info.permissions")): \(item.permissions)",
            "\(L("rc.info.dimensions")): \(dimensions(item))",
            "\(L("rc.info.duration")): \(duration(item.durationSeconds))"
        ]
    }

    private static func exposureText(_ seconds: Double) -> String {
        if seconds > 0, seconds < 1 { return "1/\(max(1, Int((1 / seconds).rounded()))) s" }
        return String(format: "%.1f s", seconds)
    }

    private static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private static func type(_ item: RightClickFileInfo) -> String {
        if let mimeType = item.mimeType { return "\(mimeType) (\(item.typeIdentifier))" }
        return item.typeIdentifier
    }

    private static func date(_ value: Date?, timeZone: TimeZone) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: value)
    }

    private static func dimensions(_ item: RightClickFileInfo) -> String {
        guard let width = item.imageWidth, let height = item.imageHeight else { return "—" }
        return "\(width) × \(height)"
    }

    private static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let rounded = max(0, Int(seconds.rounded()))
        if rounded >= 3_600 {
            return String(format: "%d:%02d:%02d", rounded / 3_600, (rounded / 60) % 60, rounded % 60)
        }
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private static func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
