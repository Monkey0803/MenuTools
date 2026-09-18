import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import MenuTools

@Test("图片元数据解析色彩空间、DPI 与 EXIF 字段")
func rightClickImageMetadataParsesProperties() throws {
    let properties: [CFString: Any] = [
        kCGImagePropertyColorModel: "RGB" as CFString,
        kCGImagePropertyDPIWidth: NSNumber(value: 72.0),
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 15 Pro"
        ] as [CFString: Any],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifLensModel: "iPhone 15 Pro back camera 6.86mm f/1.78",
            kCGImagePropertyExifISOSpeedRatings: [NSNumber(value: 64)],
            kCGImagePropertyExifFNumber: NSNumber(value: 1.78),
            kCGImagePropertyExifExposureTime: NSNumber(value: 0.008),
            kCGImagePropertyExifFocalLength: NSNumber(value: 6.86)
        ] as [CFString: Any]
    ]

    let metadata = RightClickImageMetadata.parse(properties)

    #expect(metadata.colorModel == "RGB")
    #expect(metadata.dpiWidth == 72)
    #expect(metadata.cameraMake == "Apple")
    #expect(metadata.cameraModel == "iPhone 15 Pro")
    #expect(metadata.lensModel?.contains("6.86mm") == true)
    #expect(metadata.iso == 64)
    #expect(metadata.fNumber == 1.78)
    #expect(metadata.exposureSeconds == 0.008)
    #expect(metadata.focalLength == 6.86)
    #expect(!metadata.isEmpty)
}

@Test("图片元数据忽略空值、零值和缺失字典")
func rightClickImageMetadataIgnoresEmptyValues() {
    let metadata = RightClickImageMetadata.parse([
        kCGImagePropertyColorModel: "" as CFString,
        kCGImagePropertyDPIWidth: NSNumber(value: 0),
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifISOSpeedRatings: [NSNumber(value: 0)],
            kCGImagePropertyExifFNumber: NSNumber(value: 0)
        ] as [CFString: Any]
    ])
    #expect(metadata.isEmpty)
    #expect(metadata.colorModel == nil)
    #expect(metadata.dpiWidth == nil)
    #expect(metadata.iso == nil)
    #expect(metadata.fNumber == nil)
}

@Test("音频元数据解析采样率、声道与码率")
func rightClickAudioMetadataParsesStreamDescription() {
    var description = AudioStreamBasicDescription()
    description.mSampleRate = 44_100
    description.mChannelsPerFrame = 2

    let metadata = RightClickAudioMetadata.parse(description, bitRate: 256_000)

    #expect(metadata.sampleRate == 44_100)
    #expect(metadata.channelCount == 2)
    #expect(metadata.bitRate == 256_000)
    #expect(!metadata.isEmpty)

    let empty = RightClickAudioMetadata.parse(nil, bitRate: 0)
    #expect(empty.isEmpty)
    #expect(empty.bitRate == nil)
}

@Test("文件信息从真实音频读取采样率与声道")
func rightClickFileInfoCollectsAudioMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-FileInfo-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let wave = directory.appendingPathComponent("tone.wav")
    try oneSecondWave().write(to: wave)
    let info = try #require(try await RightClickFileInfoService.collect([wave]).first)

    #expect(info.audio?.sampleRate == 8_000)
    #expect(info.audio?.channelCount == 1)
    #expect(info.volumeName?.isEmpty == false)
}

@Test("文件信息格式输出扩展元数据且普通文件不追加空字段")
func rightClickFileInfoFormatterEmitsExtras() {
    let zone = TimeZone(secondsFromGMT: 0)!
    var info = RightClickFileInfo(
        name: "photo.jpg", path: "/tmp/photo.jpg", sizeBytes: 2_048,
        typeIdentifier: "public.jpeg", mimeType: "image/jpeg",
        createdAt: nil, modifiedAt: nil, permissions: "644",
        imageWidth: 4_032, imageHeight: 3_024, durationSeconds: nil)
    info.volumeName = "Macintosh HD"
    info.image = .init(
        colorModel: "RGB", dpiWidth: 72,
        cameraMake: "Apple", cameraModel: "iPhone 15 Pro",
        lensModel: "back camera", iso: 64, fNumber: 1.78,
        exposureSeconds: 0.008, focalLength: 6.86)

    let text = RightClickFileInfoFormatter.format([info], as: .text, timeZone: zone)
    #expect(text.contains("Macintosh HD"))
    #expect(text.contains("RGB"))
    #expect(text.contains("f/1.8"))
    #expect(text.contains("1/125 s"))
    #expect(text.contains("7 mm"))

    let markdown = RightClickFileInfoFormatter.format([info], as: .markdown, timeZone: zone)
    #expect(markdown.contains("| photo.jpg |"))
    #expect(markdown.contains("- **"))

    let plain = RightClickFileInfo(
        name: "note.txt", path: "/tmp/note.txt", sizeBytes: 3,
        typeIdentifier: "public.plain-text", mimeType: "text/plain",
        createdAt: nil, modifiedAt: nil, permissions: "644",
        imageWidth: nil, imageHeight: nil, durationSeconds: nil)
    let plainText = RightClickFileInfoFormatter.format([plain], as: .text, timeZone: zone)
    #expect(!plainText.contains("RGB"))
    #expect(!plainText.contains("Macintosh"))

    let json = RightClickFileInfoFormatter.format([info], as: .json, timeZone: zone)
    let decoded = try? JSONDecoder().decode([RightClickFileInfo].self, from: Data(json.utf8))
    #expect(decoded == [info])
}

private func oneSecondWave() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount: UInt32 = 8_000
    var data = Data("RIFF".utf8)
    appendLittleEndian(UInt32(36) + sampleCount, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(8), to: &data)
    data.append(Data("data".utf8))
    appendLittleEndian(sampleCount, to: &data)
    data.append(Data(repeating: 128, count: Int(sampleCount)))
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
