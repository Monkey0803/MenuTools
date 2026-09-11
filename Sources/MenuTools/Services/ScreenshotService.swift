import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// 截图方式。
enum ScreenshotCaptureMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case fullScreen
    case custom
    case window
    case `long`

    var id: String { rawValue }

    var titleKey: String {
        "screenshot.mode.\(rawValue)"
    }

    var symbol: String {
        switch self {
        case .fullScreen: return "rectangle.inset.filled"
        case .custom: return "selection.pin.in.out"
        case .window: return "macwindow"
        case .long: return "arrow.down.to.line"
        }
    }
}

/// 长截图在用户滚动、确认和写入过程中的可观察状态。
enum ScreenshotLongCapturePhase: String, CaseIterable, Equatable, Sendable {
    case ready
    case streaming
    case previewing
    case paused
    case finalizing
    case saving

    var titleKey: String { "screenshot.long.phase.\(rawValue)" }
}

/// 长截图采集内容的边界。区域模式只读取显示器画面，窗口模式固定到用户开始时选中的窗口。
enum ScreenshotLongCaptureTargetMode: Equatable, Sendable {
    case display
    case window(CGWindowID)

    static func forCapture(
        selectRegion: Bool,
        selectedWindowID: CGWindowID?
    ) -> Self {
        guard !selectRegion, let selectedWindowID else { return .display }
        return .window(selectedWindowID)
    }
}

/// 截图任务的统一忙状态边界，编辑器打开时也不能启动新的截图或覆盖当前会话。
enum ScreenshotCaptureLifecycle {
    static func isBusy(isCapturing: Bool, hasEditorSession: Bool) -> Bool {
        isCapturing || hasEditorSession
    }
}

/// 采集主体失败后，如果停止 ScreenCaptureKit 会话也失败，保留两部分错误信息。
enum ScreenshotCaptureCleanupError: LocalizedError {
    case combined(primary: Error, cleanup: Error)

    var errorDescription: String? {
        switch self {
        case let .combined(primary, cleanup):
            return Self.combinedDescription(
                primary: primary.localizedDescription,
                cleanup: cleanup.localizedDescription
            )
        }
    }

    /// 文案模板可注入：测试进程取不到 lproj 时 `L()` 只会返回 key，
    /// 显式传入模板才能验证两个内部错误都被带进最终文案。
    static func combinedDescription(
        primary: String,
        cleanup: String,
        template: String = L("screenshot.error.cleanupFailed")
    ) -> String {
        String(format: template, primary, cleanup)
    }
}

/// 保存最近一次手动选区，支持类似 Snapzy 的“重复上次区域”截图。
struct ScreenshotRegionStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = SettingsKey.screenshotLastRegion
    ) {
        self.defaults = defaults
        self.key = key
    }

    func save(_ rect: CGRect) {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        defaults.set(values, forKey: key)
    }

    func load() -> CGRect? {
        guard let values = defaults.array(forKey: key) as? [Double], values.count == 4 else {
            return nil
        }
        let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
}

/// 正在编辑的截图会话。编辑器关闭前保留原始图片数据，避免依赖系统编辑器或临时文件状态。
struct ScreenshotEditorSession: Identifiable {
    let id = UUID()
    let imageData: Data
    let sourceURL: URL
    let mode: ScreenshotCaptureMode
    let copyToClipboard: Bool
}

/// screencapture 命令参数生成边界。
enum ScreenshotCommandBuilder {
    static func arguments(
        for mode: ScreenshotCaptureMode,
        outputURL: URL,
        windowID: CGWindowID? = nil
    ) -> [String] {
        switch mode {
        case .fullScreen:
            return ["-x", outputURL.path]
        case .custom:
            return ["-x", "-i", outputURL.path]
        case .window:
            guard let windowID else { return [] }
            return windowArguments(windowID: windowID, outputURL: outputURL)
        case .long:
            return ["-x", outputURL.path]
        }
    }

    static func windowArguments(windowID: CGWindowID, outputURL: URL) -> [String] {
        ["-x", "-l", String(windowID), outputURL.path]
    }

    static func windowSelectionArguments(outputURL: URL) -> [String] {
        ["-x", "-i", "-w", outputURL.path]
    }

    static func regionArguments(rect: CGRect, outputURL: URL) -> [String] {
        let value = [rect.origin.x, rect.origin.y, rect.width, rect.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
        return ["-x", "-R", value, outputURL.path]
    }
}

/// 计算长截图滚动事件应落在屏幕上的位置。
enum ScreenshotScrollLocation {
    static func forSelectedRegion(
        _ region: CGRect,
        in screenFrame: CGRect,
        displayBounds: CGRect
    ) -> CGPoint {
        ScreenshotScreenCoordinateConverter.quartzPoint(
            from: region.midPoint,
            screenFrame: screenFrame,
            displayBounds: displayBounds
        )
    }
}

/// 将 AppKit 全局坐标转换为 Quartz 全局坐标，处理副屏的原点和上下方向差异。
enum ScreenshotScreenCoordinateConverter {
    static func quartzPoint(
        from appKitPoint: CGPoint,
        screenFrame: CGRect,
        displayBounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + appKitPoint.x - screenFrame.minX,
            y: displayBounds.minY + screenFrame.maxY - appKitPoint.y
        )
    }
}

/// 长截图的内存保护。CGImage 通常以 4 字节每像素保存，限制总帧内存比单纯限制帧数可靠。
enum ScreenshotLongCaptureLimits {
    static let maximumBytes: Int64 = 768 * 1024 * 1024

    static func canAppend(width: Int, height: Int, currentBytes: Int64) -> Bool {
        guard width > 0, height > 0, currentBytes >= 0 else { return false }
        let frameBytes = Int64(width)
            .multipliedReportingOverflow(by: Int64(height))
        guard !frameBytes.overflow else { return false }
        let rgbaBytes = frameBytes.partialValue.multipliedReportingOverflow(by: 4)
        guard !rgbaBytes.overflow else { return false }
        let total = currentBytes.addingReportingOverflow(rgbaBytes.partialValue)
        return !total.overflow && total.partialValue <= maximumBytes
    }
}

/// 在 Core Graphics 窗口坐标、AppKit 屏幕坐标和 ScreenCaptureKit 显示器局部坐标之间转换。
enum ScreenshotWindowCoordinateConverter {
    static func appKitRect(
        from quartzRect: CGRect,
        displayBounds: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        let localY = quartzRect.minY - displayBounds.minY
        return CGRect(
            x: screenFrame.minX + quartzRect.minX - displayBounds.minX,
            y: screenFrame.minY + screenFrame.height - localY - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    static func localSourceRect(from quartzRect: CGRect, displayBounds: CGRect) -> CGRect {
        CGRect(
            x: quartzRect.minX - displayBounds.minX,
            y: quartzRect.minY - displayBounds.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }
}

/// 图片拼接的纯逻辑边界，长截图按竖直方向合并并保留少量重叠区域。
enum ScreenshotImageStitcher {
    static func outputHeight(for heights: [Int], overlap: Int) -> Int {
        guard !heights.isEmpty else { return 0 }
        let safeOverlap = max(0, overlap)
        return max(1, heights.reduce(0, +) - safeOverlap * (heights.count - 1))
    }

    static func verticallyStitch(_ images: [CGImage], overlap: Int) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let width = images.map(\.width).min() ?? 0
        guard width > 0 else { return nil }

        let safeOverlap = min(max(0, overlap), images.map(\.height).min() ?? 0)
        let height = outputHeight(for: images.map(\.height), overlap: safeOverlap)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var top = height
        for image in images {
            let drawHeight = min(image.height, height)
            top -= drawHeight
            context.draw(
                image,
                in: CGRect(x: 0, y: top, width: width, height: drawHeight)
            )
            top += safeOverlap
        }
        return context.makeImage()
    }

    /// 使用 ScrollSnap 的滚动位移模型拼接截图。
    ///
    /// Vision 返回的是当前帧相对上一帧的位移。向下滚动时，当前帧底部
    /// 的 `offset` 行是新露出的内容；旧结果整体向上移动同样的高度，
    /// 不能把当前帧的末尾行直接接到结果末尾，否则会重复上一屏内容。
    static func verticallyStitchByScrollOffsets(
        _ images: [CGImage],
        offsets: [Int]
    ) -> CGImage? {
        guard !images.isEmpty,
              images.count == offsets.count + 1 else { return nil }
        let normalizedImages = images.compactMap(normalizedImage)
        guard normalizedImages.count == images.count else { return nil }

        let width = normalizedImages.map(\.width).min() ?? 0
        guard width > 0,
              normalizedImages.allSatisfy({ $0.width == width }) else { return nil }

        let bytesPerRow = width * 4
        var stitchedData = normalizedImages[0].data
        var stitchedHeight = normalizedImages[0].height

        for (image, offset) in zip(normalizedImages.dropFirst(), offsets) {
            let newRows = min(max(0, offset), image.height)
            guard newRows > 0 else { continue }

            let nextHeight = stitchedHeight + newRows
            var nextData = Data(repeating: 0, count: bytesPerRow * nextHeight)
            nextData.withUnsafeMutableBytes { outputBuffer in
                guard let outputBase = outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                stitchedData.withUnsafeBytes { stitchedBuffer in
                    guard let stitchedBase = stitchedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    // CGImage 的位图行 0 对应底部：把旧结果整体上移。
                    memcpy(
                        outputBase.advanced(by: newRows * bytesPerRow),
                        stitchedBase,
                        stitchedHeight * bytesPerRow
                    )
                }

                image.data.withUnsafeBytes { imageBuffer in
                    guard let imageBase = imageBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    // 向下滚动后当前帧底部是新露出的条带，只复制这一段。
                    memcpy(outputBase, imageBase, newRows * bytesPerRow)
                }
            }
            stitchedData = nextData
            stitchedHeight = nextHeight
        }

        return makeImage(
            width: width,
            height: stitchedHeight,
            bytesPerRow: bytesPerRow,
            data: stitchedData
        )
    }

    /// 兼容旧调用方；`newRows` 现在按滚动位移处理，而不是复制当前帧末尾。
    static func verticallyStitchByNewRows(
        _ images: [CGImage],
        newRows: [Int]
    ) -> CGImage? {
        verticallyStitchByScrollOffsets(images, offsets: newRows)
    }

    private static func makeImage(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        data: Data
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// 根据相邻截图的像素内容自动估算重叠区域，再进行纵向拼接。
    ///
    /// 滚轮滚动的实际距离会因应用、滚动设置和内容类型不同而变化，不能使用固定
    /// overlap。这里寻找上一帧底部与下一帧顶部最相似的行区间，避免页面重复。
    static func verticallyStitchAutomatically(
        _ images: [CGImage],
        fallbackOverlap: Int
    ) -> CGImage? {
        guard images.count > 1 else { return images.first }
        let normalizedImages = images.compactMap(normalizedImage)
        guard normalizedImages.count == images.count else { return nil }

        var overlaps: [Int] = []
        for index in 1..<normalizedImages.count {
            overlaps.append(
                estimatedOverlap(
                    between: normalizedImages[index - 1],
                    and: normalizedImages[index],
                    fallback: fallbackOverlap
                )
            )
        }

        let width = images.map(\.width).min() ?? 0
        guard width > 0 else { return nil }
        let height = images[0].height + zip(images.dropFirst(), overlaps)
            .reduce(0) { total, pair in
                total + pair.0.height - min(max(0, pair.1), pair.0.height - 1)
            }
        guard height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var top = height
        for (index, image) in images.enumerated() {
            top -= image.height
            context.draw(
                image,
                in: CGRect(x: 0, y: top, width: width, height: image.height)
            )
            if index < overlaps.count {
                top += min(max(0, overlaps[index]), image.height - 1)
            }
        }
        return context.makeImage()
    }

    private struct NormalizedImage {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: Data
    }

    private static func normalizedImage(_ image: CGImage) -> NormalizedImage? {
        let bytesPerRow = image.width * 4
        var data = Data(repeating: 0, count: bytesPerRow * image.height)
        let rendered = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            // 保持 CGImage 原始的 top-to-bottom 位图行序。ScrollSnap 和
            // Snapzy 的滚动拼接器直接按这个行序比较重叠并追加新行，不能额外翻转。
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else { return nil }
        return NormalizedImage(
            width: image.width,
            height: image.height,
            bytesPerRow: bytesPerRow,
            data: data
        )
    }

    private static func estimatedOverlap(
        between previous: NormalizedImage,
        and current: NormalizedImage,
        fallback: Int
    ) -> Int {
        guard previous.width == current.width,
              previous.height > 32,
              current.height > 32 else {
            return min(max(0, fallback), max(0, min(previous.height, current.height) - 1))
        }

        let maximum = min(previous.height, current.height) - 16
        let minimum = max(8, min(previous.height, current.height) / 8)
        guard maximum >= minimum else { return fallback }

        var bestOverlap = min(max(fallback, minimum), maximum)
        var bestScore = Double.greatestFiniteMagnitude
        for overlap in stride(from: maximum, through: minimum, by: -1) {
            let sampleStep = max(1, overlap / 36)
            var score = 0.0
            var sampleCount = 0
            for offset in stride(from: 0, through: overlap - 1, by: sampleStep) {
                let previousRow = previous.height - overlap + offset
                let currentRow = offset
                let forward = rowDifference(
                    previous,
                    row: previousRow,
                    current,
                    row: currentRow
                )
                // 不同图像来源可能使用相反的 bitmap 行序；同时检查反向行序，
                // 但始终优先采用正常的“上一帧底部 -> 下一帧顶部”方向。
                let reverse = rowDifference(
                    previous,
                    row: offset,
                    current,
                    row: current.height - overlap + offset
                )
                let result = forward.difference <= reverse.difference ? forward : reverse
                // 近乎纯色行会让很多错误位置看起来相同，优先使用有纹理的行。
                if result.contrast >= 10 {
                    score += result.difference
                    sampleCount += 1
                }
            }
            guard sampleCount >= 4 else { continue }
            let average = score / Double(sampleCount)
            if average < bestScore {
                bestScore = average
                bestOverlap = overlap
            }
        }
        return bestOverlap
    }

    private static func rowDifference(
        _ lhs: NormalizedImage,
        row lhsRow: Int,
        _ rhs: NormalizedImage,
        row rhsRow: Int
    ) -> (difference: Double, contrast: Double) {
        let sampleStep = max(1, lhs.width / 32)
        var difference = 0.0
        var contrast = 0.0
        var sampleCount = 0

        lhs.data.withUnsafeBytes { lhsBytes in
            rhs.data.withUnsafeBytes { rhsBytes in
                guard let lhsBase = lhsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let rhsBase = rhsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for x in stride(from: 0, to: lhs.width, by: sampleStep) {
                    let lhsIndex = lhsRow * lhs.bytesPerRow + x * 4
                    let rhsIndex = rhsRow * rhs.bytesPerRow + x * 4
                    let lhsPixel = lhsBase.advanced(by: lhsIndex)
                    let rhsPixel = rhsBase.advanced(by: rhsIndex)
                    let lhsRed = Double(lhsPixel[0])
                    let lhsGreen = Double(lhsPixel[1])
                    let lhsBlue = Double(lhsPixel[2])
                    let rhsRed = Double(rhsPixel[0])
                    let rhsGreen = Double(rhsPixel[1])
                    let rhsBlue = Double(rhsPixel[2])
                    difference += abs(lhsRed - rhsRed)
                        + abs(lhsGreen - rhsGreen)
                        + abs(lhsBlue - rhsBlue)
                    let lhsRange = max(lhsRed, lhsGreen, lhsBlue) - min(lhsRed, lhsGreen, lhsBlue)
                    let rhsRange = max(rhsRed, rhsGreen, rhsBlue) - min(rhsRed, rhsGreen, rhsBlue)
                    contrast += max(lhsRange, rhsRange)
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return (Double.greatestFiniteMagnitude, 0) }
        return (
            difference / Double(sampleCount * 3 * 255),
            contrast / Double(sampleCount)
        )
    }
}

/// ScrollSnap 使用的 Vision 位移估计器。
///
/// 多个比较带可以排除固定标题栏、滚动条和动态区域的干扰；只有足够多的
/// 比较带得出相近位移时才接受结果，否则再尝试整帧高置信度结果。
struct ScreenshotVisionOffsetEstimator {
    private let comparisonBandCount = 5
    private let minimumComparisonBandHeight = 80
    private let agreementTolerance: CGFloat = 3
    private let maximumHorizontalMovement: CGFloat = 3
    private let minimumOverlapFraction: CGFloat = 0.15
    private let validatedBandConfidence: Float = 0.8
    private let fullFrameConfidence: Float = 0.9

    func estimate(from currentImage: CGImage, to previousImage: CGImage) -> CGFloat? {
        guard currentImage.width == previousImage.width,
              currentImage.height == previousImage.height else { return nil }

        let frameHeight = CGFloat(currentImage.height)
        let translations: [Translation] = comparisonBands(for: currentImage).compactMap { (band: CGRect) -> Translation? in
            guard let currentBand = currentImage.cropping(to: band),
                  let previousBand = previousImage.cropping(to: band),
                  let translation = findTranslation(from: currentBand, to: previousBand),
                  isValid(translation, frameHeight: frameHeight) else {
                return nil
            }
            return translation
        }

        if let consensus = bestGroup(in: translations, minimumCount: 4) {
            return average(consensus)
        }

        guard let fullFrame = findTranslation(from: currentImage, to: previousImage),
              isValid(fullFrame, frameHeight: frameHeight) else {
            return nil
        }

        if fullFrame.confidence >= validatedBandConfidence,
           let partialConsensus = bestGroup(in: translations, minimumCount: 3),
           let bandOffset = average(partialConsensus),
           abs(bandOffset - fullFrame.translationY) <= agreementTolerance {
            return bandOffset
        }
        return fullFrame.confidence >= fullFrameConfidence ? fullFrame.translationY : nil
    }

    private struct Translation {
        let x: CGFloat
        let translationY: CGFloat
        let confidence: Float
    }

    private func comparisonBands(for image: CGImage) -> [CGRect] {
        let imageHeight = image.height
        guard image.width > 0, imageHeight > 0 else { return [] }
        let bandHeight = min(imageHeight, max(minimumComparisonBandHeight, imageHeight / 3))
        let maxOriginY = max(0, imageHeight - bandHeight)
        let origins: [Int]
        if maxOriginY == 0 {
            origins = [0]
        } else {
            origins = (0..<comparisonBandCount).map { index in
                let denominator = max(1, comparisonBandCount - 1)
                return Int((CGFloat(maxOriginY) * CGFloat(index) / CGFloat(denominator)).rounded())
            }
        }
        return Array(Set(origins)).sorted().map {
            CGRect(x: 0, y: $0, width: image.width, height: bandHeight)
        }
    }

    private func bestGroup(in translations: [Translation], minimumCount: Int) -> [Translation]? {
        var best: [Translation] = []
        for translation in translations {
            let group = translations.filter {
                abs($0.translationY - translation.translationY) <= agreementTolerance
            }
            if group.count > best.count { best = group }
        }
        return best.count >= minimumCount ? best : nil
    }

    private func average(_ translations: [Translation]) -> CGFloat? {
        guard !translations.isEmpty else { return nil }
        return translations.reduce(0) { $0 + $1.translationY } / CGFloat(translations.count)
    }

    private func isValid(_ translation: Translation, frameHeight: CGFloat) -> Bool {
        abs(translation.x) <= maximumHorizontalMovement
            && abs(translation.translationY) <= frameHeight * (1 - minimumOverlapFraction)
    }

    private func findTranslation(from image: CGImage, to target: CGImage) -> Translation? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return Translation(
            x: observation.alignmentTransform.tx,
            translationY: observation.alignmentTransform.ty,
            confidence: observation.confidence
        )
    }
}

enum ScreenshotError: LocalizedError, Equatable {
    case alreadyCapturing
    case cancelled
    case captureFailed(String)
    case noFrontmostWindow
    case noSavedRegion
    case imageUnavailable
    case clipboardFailed
    case editorFailed
    case stitchFailed

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: return L("screenshot.error.busy")
        case .cancelled: return L("screenshot.error.cancelled")
        case let .captureFailed(reason): return L("screenshot.error.capture", reason)
        case .noFrontmostWindow: return L("screenshot.error.noWindow")
        case .noSavedRegion: return L("screenshot.error.noSavedRegion")
        case .imageUnavailable: return L("screenshot.error.noImage")
        case .clipboardFailed: return L("screenshot.error.clipboard")
        case .editorFailed: return L("screenshot.error.editor")
        case .stitchFailed: return L("screenshot.error.stitch")
        }
    }
}

@MainActor
protocol ScreenshotProcessRunning {
    func run(executable: String, arguments: [String]) async throws
}

@MainActor
protocol ScreenshotWorkspaceOpening {
    func open(_ url: URL) -> Bool
}

@MainActor
protocol ScreenshotRegionSelecting {
    func select() async throws -> CGRect
    func selectArea() async throws -> ScreenshotAreaSelectionResult
}

extension ScreenshotRegionSelector: ScreenshotRegionSelecting {}

@MainActor
protocol ScreenshotWindowSelecting {
    func select() async throws -> CGWindowID
}

extension ScreenshotWindowSelector: ScreenshotWindowSelecting {}

@MainActor
private final class DefaultScreenshotProcessRunner: ScreenshotProcessRunning {
    func run(executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ScreenshotError.captureFailed(error.localizedDescription)
        }

        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }
        guard status == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScreenshotError.captureFailed(detail ?? "status \(status)")
        }
    }
}

@MainActor
private final class DefaultScreenshotWorkspace: ScreenshotWorkspaceOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class ScreenshotEditorWindow: NSWindow {
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
    }
}

/// 截图服务：负责调用系统截图、复制到剪贴板、滚动拼接和打开编辑器。
@MainActor
@Observable
final class ScreenshotService {
    static let shared = ScreenshotService()

    private static let executable = "/usr/sbin/screencapture"
    // 这是内存保护上限，不是完成条件。达到上限后仍保持采集状态，只有用户
    // 明确按结束快捷键或点击完成按钮才会生成最终长图。
    private static let maxLongFrames = 240

    private let processRunner: any ScreenshotProcessRunning
    private let regionSelector: any ScreenshotRegionSelecting
    private let windowSelector: any ScreenshotWindowSelecting
    private let imageCapturer: any ScreenshotImageCapturing
    private let regionStore: ScreenshotRegionStore
    private let fileManager: FileManager

    private(set) var isCapturing = false
    private(set) var capturingMode: ScreenshotCaptureMode?
    private(set) var longCapturePhase: ScreenshotLongCapturePhase?
    private(set) var lastCaptureURL: URL?
    private(set) var lastError: String?
    private var editorWindow: ScreenshotEditorWindow?
    private var longCaptureStopRequested = false
    private var longCaptureCancelRequested = false

    init(
        processRunner: any ScreenshotProcessRunning = DefaultScreenshotProcessRunner(),
        regionSelector: any ScreenshotRegionSelecting = ScreenshotRegionSelector.shared,
        windowSelector: any ScreenshotWindowSelecting = ScreenshotWindowSelector.shared,
        imageCapturer: any ScreenshotImageCapturing = DefaultScreenshotImageCapturer(),
        regionStore: ScreenshotRegionStore = ScreenshotRegionStore(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.regionSelector = regionSelector
        self.windowSelector = windowSelector
        self.imageCapturer = imageCapturer
        self.regionStore = regionStore
        self.fileManager = fileManager
    }

    var configuredMode: ScreenshotCaptureMode {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: SettingsKey.screenshotMode),
                  let mode = ScreenshotCaptureMode(rawValue: rawValue) else {
                return .fullScreen
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.screenshotMode) }
    }

    var copyToClipboard: Bool {
        get {
            guard UserDefaults.standard.object(forKey: SettingsKey.screenshotCopy) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.screenshotCopy)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.screenshotCopy) }
    }

    var openEditorAfterCapture: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKey.screenshotEdit) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.screenshotEdit) }
    }

    var longSelectRegion: Bool {
        get {
            guard UserDefaults.standard.object(forKey: SettingsKey.screenshotLongSelectRegion) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.screenshotLongSelectRegion)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.screenshotLongSelectRegion) }
    }

    var hasSavedRegion: Bool { regionStore.load() != nil }

    private(set) var editorSession: ScreenshotEditorSession?

    var outputConfiguration: ScreenshotOutputConfiguration {
        get { ScreenshotOutputConfiguration.load(fileManager: fileManager) }
        set { newValue.save() }
    }

    var screenshotHistory: [ScreenshotHistoryEntry] {
        ScreenshotHistoryStore.shared.entries
    }

    /// 长截图进入手动滚动阶段后，由同一个长截图快捷键调用以结束采集。
    func requestStopLongCapture() {
        guard isCapturing else { return }
        longCaptureStopRequested = true
    }

    func cancelLongCapture() {
        guard isCapturing else { return }
        longCaptureCancelRequested = true
    }

    func captureConfigured() async throws -> URL {
        try await capture(
            mode: configuredMode,
            copyToClipboard: copyToClipboard,
            editAfterCapture: openEditorAfterCapture,
            longSelectRegion: longSelectRegion
        )
    }

    /// 重复截取最近一次手动选择的区域，不再显示选区层。
    @discardableResult
    func captureLastSelectedRegion(
        copyToClipboard: Bool,
        editAfterCapture: Bool
    ) async throws -> URL {
        guard let region = regionStore.load() else {
            throw ScreenshotError.noSavedRegion
        }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(region) }) else {
            throw ScreenshotError.noSavedRegion
        }
        return try await capture(
            mode: .custom,
            copyToClipboard: copyToClipboard,
            editAfterCapture: editAfterCapture,
            longSelectRegion: true,
            selectedRegion: region,
            selectedWindowID: nil
        )
    }

    /// 显示窗口悬停选择层，点击后捕获被选中的应用窗口。
    @discardableResult
    func captureSelectedWindow(
        copyToClipboard: Bool,
        editAfterCapture: Bool
    ) async throws -> URL {
        let windowID = try await windowSelector.select()
        return try await capture(
            mode: .window,
            copyToClipboard: copyToClipboard,
            editAfterCapture: editAfterCapture,
            longSelectRegion: true,
            selectedRegion: nil,
            selectedWindowID: windowID
        )
    }

    @discardableResult
    func capture(
        mode: ScreenshotCaptureMode,
        copyToClipboard: Bool,
        editAfterCapture: Bool,
        longSelectRegion: Bool = true
    ) async throws -> URL {
        try await capture(
            mode: mode,
            copyToClipboard: copyToClipboard,
            editAfterCapture: editAfterCapture,
            longSelectRegion: longSelectRegion,
            selectedRegion: nil,
            selectedWindowID: nil
        )
    }

    private func capture(
        mode: ScreenshotCaptureMode,
        copyToClipboard: Bool,
        editAfterCapture: Bool,
        longSelectRegion: Bool,
        selectedRegion: CGRect?,
        selectedWindowID: CGWindowID?
    ) async throws -> URL {
        guard !ScreenshotCaptureLifecycle.isBusy(
            isCapturing: isCapturing,
            hasEditorSession: editorSession != nil
        ) else {
            throw ScreenshotError.alreadyCapturing
        }
        isCapturing = true
        capturingMode = mode
        lastError = nil
        longCaptureStopRequested = false
        longCaptureCancelRequested = false
        defer {
            isCapturing = false
            capturingMode = nil
            longCapturePhase = nil
        }

        do {
            let outputURL = try makeOutputURL(mode: mode)
            let imageURL: URL
            switch mode {
            case .fullScreen:
                if let screen = activeScreen(),
                   let image = try? await imageCapturer.captureDisplay(screen.screenshotDisplayID) {
                    try writeImage(image, to: outputURL)
                } else {
                    let processURL = try makeProcessCaptureURL(for: outputURL)
                    try await processRunner.run(
                        executable: Self.executable,
                        arguments: ScreenshotCommandBuilder.arguments(for: mode, outputURL: processURL)
                    )
                    try transcodeIfNeeded(from: processURL, to: outputURL)
                }
                imageURL = try validatedImageURL(outputURL)
            case .custom:
                imageURL = try await captureCustomScreenshot(to: outputURL, selectedRegion: selectedRegion)
            case .window:
                let target = try frontmostWindow(windowID: selectedWindowID)
                if let image = try? await imageCapturer.captureWindow(target.id) {
                    try writeImage(image, to: outputURL)
                } else {
                    let processURL = try makeProcessCaptureURL(for: outputURL)
                    try await processRunner.run(
                        executable: Self.executable,
                        arguments: ScreenshotCommandBuilder.windowArguments(
                            windowID: target.id,
                            outputURL: processURL
                        )
                    )
                    try transcodeIfNeeded(from: processURL, to: outputURL)
                }
                imageURL = try validatedImageURL(outputURL)
            case .long:
                imageURL = try await captureLongScreenshot(
                    to: outputURL,
                    selectRegion: longSelectRegion
                )
            }

            if editAfterCapture {
                try beginEditing(at: imageURL, mode: mode, copyToClipboard: copyToClipboard)
            } else if copyToClipboard {
                try copyImageToClipboard(at: imageURL)
            }
            lastCaptureURL = imageURL
            recordHistory(for: imageURL, mode: mode)
            ScreenshotQuickAccessManager.shared.show(imageURL: imageURL)
            return imageURL
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func captureCustomScreenshot(
        to outputURL: URL,
        selectedRegion: CGRect?
    ) async throws -> URL {
        // 先冻结所有显示器，再显示选区层。这样选区层只负责交互，最终裁剪
        // 使用的是同一时刻的桌面帧，避免菜单、悬浮窗和鼠标移动造成的竞态。
        var frozenSnapshots: [(displayFrame: CGRect, image: CGImage)] = []
        for screen in NSScreen.screens {
            if let image = try? await imageCapturer.captureDisplay(screen.screenshotDisplayID) {
                frozenSnapshots.append((screen.frame, image))
            }
        }

        let selectionResult: ScreenshotAreaSelectionResult
        if let selectedRegion {
            selectionResult = .region(selectedRegion)
        } else {
            selectionResult = try await regionSelector.selectArea()
        }

        if case let .window(windowID) = selectionResult {
            if let image = try? await imageCapturer.captureWindow(windowID) {
                try writeImage(image, to: outputURL)
            } else {
                let processURL = try makeProcessCaptureURL(for: outputURL)
                try await processRunner.run(
                    executable: Self.executable,
                    arguments: ScreenshotCommandBuilder.windowArguments(
                        windowID: windowID,
                        outputURL: processURL
                    )
                )
                try transcodeIfNeeded(from: processURL, to: outputURL)
            }
            return try validatedImageURL(outputURL)
        }

        guard case let .region(appKitRect) = selectionResult else {
            throw ScreenshotRegionSelectionError.cancelled
        }
        if selectedRegion == nil {
            regionStore.save(appKitRect)
        }
        if let croppedImage = ScreenshotDisplayImageCropper.cropComposite(
            frozenSnapshots,
            selection: appKitRect
        ) {
            try writeImage(croppedImage, to: outputURL)
            return try validatedImageURL(outputURL)
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitRect.midPoint) }) else {
            throw ScreenshotRegionSelectionError.unavailable
        }
        let captureRect = ScreenshotRegionCoordinateConverter.screencaptureRect(
            from: appKitRect,
            in: screen.frame
        )
        ScreenshotRangeHighlight.shared.show(
            rect: appKitRect,
            message: L("screenshot.region.highlight")
        )
        defer { ScreenshotRangeHighlight.shared.hide() }
        // 给用户一个明确的确认反馈，再隐藏高亮并开始实际采集。
        try await Task.sleep(for: .milliseconds(600))
        ScreenshotRangeHighlight.shared.hide()
        // orderOut 会在下一次 AppKit 合成周期才从屏幕移除；给 screencapture
        // 留出刷新时间，避免提示徽标残留在截图第一帧。
        try await Task.sleep(for: .milliseconds(160))
        let processURL = try makeProcessCaptureURL(for: outputURL)
        try await processRunner.run(
            executable: Self.executable,
            arguments: ScreenshotCommandBuilder.regionArguments(rect: captureRect, outputURL: processURL)
        )
        try transcodeIfNeeded(from: processURL, to: outputURL)
        return try validatedImageURL(outputURL)
    }

    private func captureLongScreenshot(to outputURL: URL, selectRegion: Bool) async throws -> URL {
        longCapturePhase = .ready
        // 窗口模式必须在显示提示层之前锁定目标窗口。区域模式读取用户最终
        // 选择的显示器内容，不应因为启动时的前台应用没有可用窗口而失败。
        let selectedTarget: (id: CGWindowID, bounds: CGRect, processIdentifier: pid_t)? =
            selectRegion ? nil : try frontmostWindow()
        let screen: NSScreen
        let sourceRect: CGRect
        let highlightRect: CGRect
        let displayBounds: CGRect
        if selectRegion {
            let appKitRect = try await regionSelector.select()
            guard let selectedScreen = NSScreen.screens.first(where: { $0.frame.contains(appKitRect.midPoint) }) else {
                throw ScreenshotRegionSelectionError.unavailable
            }
            guard let selectedDisplayBounds = quartzDisplayBounds(for: selectedScreen) else {
                throw ScreenshotRegionSelectionError.unavailable
            }
            screen = selectedScreen
            displayBounds = selectedDisplayBounds
            sourceRect = ScreenshotScreenCaptureSession.localSourceRect(appKitRect, on: selectedScreen)
            highlightRect = appKitRect
        } else {
            guard let selectedTarget else {
                throw ScreenshotError.noFrontmostWindow
            }
            guard let (selectedScreen, selectedDisplayBounds) = screenAndQuartzBounds(
                intersecting: selectedTarget.bounds
            ) else {
                throw ScreenshotRegionSelectionError.unavailable
            }
            screen = selectedScreen
            displayBounds = selectedDisplayBounds
            sourceRect = ScreenshotWindowCoordinateConverter.localSourceRect(
                from: selectedTarget.bounds,
                displayBounds: selectedDisplayBounds
            )
            highlightRect = ScreenshotWindowCoordinateConverter.appKitRect(
                from: selectedTarget.bounds,
                displayBounds: selectedDisplayBounds,
                screenFrame: selectedScreen.frame
            )
        }
        guard !longCaptureCancelRequested else {
            throw ScreenshotError.cancelled
        }
        if let selectedTarget {
            NSRunningApplication(processIdentifier: selectedTarget.processIdentifier)?.activate(options: [])
        }
        ScreenshotRangeHighlight.shared.show(
            rect: highlightRect,
            message: L("screenshot.long.highlight"),
            finishAction: { [weak self] in
                self?.requestStopLongCapture()
            }
        )
        defer { ScreenshotRangeHighlight.shared.hide() }

        // 用户先阅读操作提示；真正开始采集前只保留选区边框。这样即使某些
        // macOS 版本的 ScreenCaptureKit 过滤器延迟生效，蓝色提示徽标也不会
        // 被当作长截图内容采入首帧。
        try await Task.sleep(for: .milliseconds(900))
        ScreenshotRangeHighlight.shared.clearMessage()
        try await Task.sleep(for: .milliseconds(100))

        // 把鼠标放到选区中心，方便用户直接滚动目标内容；后续滚动完全由用户
        // 控制，不再由截图服务自动发送滚轮事件。结束时恢复用户原来的鼠标位置。
        let originalMouseLocation = NSEvent.mouseLocation
        let originalQuartzMouseLocation: CGPoint? = NSScreen.screens.first(where: {
            $0.frame.contains(originalMouseLocation)
        }).flatMap { originalScreen in
            quartzDisplayBounds(for: originalScreen).map {
                ScreenshotScreenCoordinateConverter.quartzPoint(
                    from: originalMouseLocation,
                    screenFrame: originalScreen.frame,
                    displayBounds: $0
                )
            }
        }
        let scrollLocation = ScreenshotScrollLocation.forSelectedRegion(
            highlightRect,
            in: screen.frame,
            displayBounds: displayBounds
        )
        _ = CGWarpMouseCursorPosition(scrollLocation)
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        defer {
            if let originalQuartzMouseLocation {
                _ = CGWarpMouseCursorPosition(originalQuartzMouseLocation)
                _ = CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        let session = ScreenshotScreenCaptureSession(
            screen: screen,
            sourceRect: sourceRect,
            targetMode: ScreenshotLongCaptureTargetMode.forCapture(
                selectRegion: selectRegion,
                selectedWindowID: selectedTarget?.id
            )
        )
        var sessionStarted = false

        do {
            try await session.start()
            sessionStarted = true
            longCapturePhase = .streaming

            guard let first = try await session.waitForSettledImage(previousFingerprint: nil) else {
                throw ScreenshotError.imageUnavailable
            }
            guard ScreenshotLongCaptureLimits.canAppend(
                width: first.width,
                height: first.height,
                currentBytes: 0
            ) else {
                throw ScreenshotError.captureFailed(L("screenshot.error.memoryLimit"))
            }
            var frames = [first]
            var capturedBytes = Int64(first.width) * Int64(first.height) * 4
            var memoryLimitReached = false
            longCapturePhase = .previewing
            ScreenshotRangeHighlight.shared.updateLongPreview(first, frameCount: frames.count)
            var previousFingerprint = ScreenshotFrameStitcher.fingerprint(first)
            let offsetEstimator = ScreenshotVisionOffsetEstimator()

            // 首帧显示当前选区内容。用户自行滚动，连续帧采集器只在画面稳定且
            // 发生变化后取样；再次按长截图快捷键时结束本次采集。
            while true {
                if longCaptureCancelRequested {
                    throw ScreenshotError.cancelled
                }
                if longCaptureStopRequested {
                    break
                }

                if memoryLimitReached {
                    longCapturePhase = .paused
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }

                // 达到保护上限后暂停追加新帧，但继续等待用户明确结束，避免
                // 长截图在用户尚未完成操作时自动保存并退出。
                if frames.count >= Self.maxLongFrames {
                    longCapturePhase = .paused
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }

                if longCapturePhase == .paused {
                    longCapturePhase = .previewing
                }

                guard let next = try await session.waitForSettledImage(
                    previousFingerprint: previousFingerprint
                ) else {
                    continue
                }

                let fingerprint = ScreenshotFrameStitcher.fingerprint(next)
                // 用户尚未滚动，继续等待；不能把同一屏重复加入结果。
                guard fingerprint != previousFingerprint else { continue }

                // 每一帧先通过真实像素重叠验证。滚动中的过渡帧可能暂时无法
                // 对齐，忽略它并继续等待下一张稳定帧，不能因此结束整个会话。
                let candidate = frames + [next]
                let expectedOffset = offsetEstimator.estimate(
                    from: next,
                    to: frames[frames.count - 1]
                ).map { max(1, Int(abs($0).rounded())) }
                guard ScreenshotFrameStitcher.stitch(
                    candidate,
                    expectedOffset: expectedOffset
                ) != nil else { continue }
                guard ScreenshotLongCaptureLimits.canAppend(
                    width: next.width,
                    height: next.height,
                    currentBytes: capturedBytes
                ) else {
                    memoryLimitReached = true
                    longCapturePhase = .paused
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                frames.append(next)
                capturedBytes += Int64(next.width) * Int64(next.height) * 4
                ScreenshotRangeHighlight.shared.updateLongPreview(next, frameCount: frames.count)
                previousFingerprint = fingerprint
            }

            if longCaptureCancelRequested {
                throw ScreenshotError.cancelled
            }

            longCapturePhase = .finalizing
            guard let stitched = ScreenshotFrameStitcher.stitch(
                frames,
                expectedOffset: nil
            ) else {
                throw ScreenshotError.stitchFailed
            }
            longCapturePhase = .saving
            try writeImage(stitched, to: outputURL)
            sessionStarted = false
            try await session.stop()
            return try validatedImageURL(outputURL)
        } catch {
            if sessionStarted {
                sessionStarted = false
                do {
                    try await session.stop()
                } catch let cleanupError {
                    throw ScreenshotCaptureCleanupError.combined(
                        primary: error,
                        cleanup: cleanupError
                    )
                }
            }
            throw error
        }
    }

    private func frontmostWindow(windowID: CGWindowID? = nil) throws -> (id: CGWindowID, bounds: CGRect, processIdentifier: pid_t) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw ScreenshotError.noFrontmostWindow
        }

        if let windowID {
            guard let info = windowInfo.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
            }),
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            ownerPID != selfPID,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            rect.width > 80,
            rect.height > 80 else {
                throw ScreenshotError.noFrontmostWindow
            }
            return (windowID, rect, ownerPID)
        }

        guard frontmostPID != selfPID else {
            throw ScreenshotError.noFrontmostWindow
        }

        let candidates = windowInfo.filter { info in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != selfPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
                return false
            }
            return frontmostPID == nil || ownerPID == frontmostPID
        }
        for info in candidates {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != selfPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 80,
                  rect.height > 80 else {
                continue
            }
            return (CGWindowID(windowID), rect, ownerPID)
        }
        // 当前前台应用没有可用的 layer-0 窗口时，再使用系统窗口列表回退。
        for info in windowInfo {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != selfPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 80,
                  rect.height > 80 else { continue }
            return (CGWindowID(windowID), rect, ownerPID)
        }
        throw ScreenshotError.noFrontmostWindow
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screenAndQuartzBounds(intersecting rect: CGRect) -> (NSScreen, CGRect)? {
        let candidates: [(screen: NSScreen, bounds: CGRect, area: CGFloat)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let intersection = displayBounds.intersection(rect)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                return nil
            }
            return (screen: screen, bounds: displayBounds, area: intersection.width * intersection.height)
        }
        return candidates.max { $0.area < $1.area }.map { ($0.screen, $0.bounds) }
    }

    private func quartzDisplayBounds(for screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    private func copyImageToClipboard(at url: URL) throws {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ScreenshotError.imageUnavailable
        }
        let format = ScreenshotHistoryStore.shared.entries.first(where: { $0.fileURL == url })?.format
            ?? outputConfiguration.format
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(
            data,
            forType: NSPasteboard.PasteboardType(format.typeIdentifier)
        ) else {
            throw ScreenshotError.clipboardFailed
        }
        // TIFF 作为通用像素回退，保证支持图片粘贴但不理解 JPEG/WebP UTI 的应用仍可接收。
        if let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
            _ = pasteboard.setData(tiff, forType: .tiff)
        }
        ClipboardHistoryService.shared.refresh()
    }

    func saveEditedImage(_ data: Data) throws {
        guard !data.isEmpty, let session = editorSession else {
            throw ScreenshotError.editorFailed
        }
        let outputURL = session.sourceURL
        try writeEditedData(data, to: outputURL)
        let imageURL = try validatedImageURL(outputURL)
        if session.copyToClipboard {
            try copyImageToClipboard(at: imageURL)
        }
        recordHistory(for: imageURL, mode: session.mode)
        ScreenshotQuickAccessManager.shared.show(imageURL: imageURL)
        lastCaptureURL = imageURL
        editorSession = nil
        closeEditorWindow()
    }

    func cancelEditing() {
        editorSession = nil
        closeEditorWindow()
    }

    func editCapture(at url: URL) throws {
        let mode = ScreenshotHistoryStore.shared.entries.first(where: { $0.fileURL == url })?.mode ?? .custom
        try beginEditing(at: url, mode: mode, copyToClipboard: self.copyToClipboard)
    }

    private func beginEditing(
        at url: URL,
        mode: ScreenshotCaptureMode,
        copyToClipboard: Bool
    ) throws {
        guard !ScreenshotCaptureLifecycle.isBusy(
            isCapturing: isCapturing,
            hasEditorSession: editorSession != nil
        ), editorWindow == nil else {
            throw ScreenshotError.alreadyCapturing
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ScreenshotError.imageUnavailable
        }
        editorSession = ScreenshotEditorSession(
            imageData: data,
            sourceURL: url,
            mode: mode,
            copyToClipboard: copyToClipboard
        )
        presentEditorWindow()
    }

    private func presentEditorWindow() {
        guard let session = editorSession, editorWindow == nil else { return }
        let window = ScreenshotEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("screenshot.editor.title")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ScreenshotEditorView(session: session) { [weak self] data in
                guard let self else { throw ScreenshotError.editorFailed }
                try self.saveEditedImage(data)
            } onCancel: { [weak self] in
                self?.cancelEditing()
            }
        )
        window.onClose = { [weak self] in
            self?.editorWindowDidClose()
        }
        editorWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func editorWindowDidClose() {
        editorWindow?.onClose = nil
        editorWindow = nil
        editorSession = nil
    }

    private func closeEditorWindow() {
        let window = editorWindow
        editorWindow = nil
        window?.onClose = nil
        window?.close()
    }

    private func makeOutputURL(mode: ScreenshotCaptureMode) throws -> URL {
        let configuration = outputConfiguration
        let directory = configuration.saveToDisk
            ? configuration.directoryURL
            : fileManager.temporaryDirectory.appendingPathComponent("MenuTools-Screenshots", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = ScreenshotFileNaming.makeBaseName(
            template: configuration.namingTemplate,
            mode: mode
        )
        return ScreenshotFileNaming.uniqueURL(
            directory: directory,
            baseName: baseName,
            format: configuration.format,
            fileManager: fileManager
        )
    }

    private func makeProcessCaptureURL(for outputURL: URL) throws -> URL {
        guard outputConfiguration.format != .png else { return outputURL }
        let url = outputURL.deletingPathExtension().appendingPathExtension("png")
        try? fileManager.removeItem(at: url)
        return url
    }

    private func validatedImageURL(_ url: URL) throws -> URL {
        guard fileManager.fileExists(atPath: url.path),
              let image = loadImage(at: url),
              image.width > 0,
              image.height > 0 else {
            throw ScreenshotError.imageUnavailable
        }
        return url
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeImage(_ image: CGImage, to url: URL) throws {
        try ScreenshotImageWriter.write(image, to: url, format: outputConfiguration.format)
    }

    private func transcodeIfNeeded(from sourceURL: URL, to outputURL: URL) throws {
        guard sourceURL != outputURL else { return }
        guard let image = loadImage(at: sourceURL) else { throw ScreenshotError.imageUnavailable }
        try writeImage(image, to: outputURL)
        try? fileManager.removeItem(at: sourceURL)
    }

    private func writeEditedData(_ data: Data, to url: URL) throws {
        guard outputConfiguration.format != .png else {
            try data.write(to: url, options: .atomic)
            return
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotError.imageUnavailable
        }
        let tempURL = url.appendingPathExtension("editing")
        try ScreenshotImageWriter.write(image, to: tempURL, format: outputConfiguration.format)
        _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
    }

    private func recordHistory(for url: URL, mode: ScreenshotCaptureMode) {
        guard let image = loadImage(at: url) else { return }
        let fileSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        ScreenshotHistoryStore.shared.add(
            ScreenshotHistoryEntry(
                fileURL: url,
                width: image.width,
                height: image.height,
                format: outputConfiguration.format,
                mode: mode,
                fileSize: fileSize
            )
        )
    }
}

private extension CGRect {
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
}
