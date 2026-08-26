import AppKit
import CoreGraphics
import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit

/// 基于真实像素重叠的滚动截图拼接器。
///
/// 先识别跨帧不变的顶部/底部区域，再只对中间滚动内容做位移搜索。
/// 这样 Mail、浏览器等带固定工具栏或列表标题的窗口不会把固定区域重复
/// 拼接到长图中。
struct ScreenshotFrameStitcher {
    // 用户一次滚动可能超过半屏；保留 10% 的真实重叠即可完成匹配，
    // 过高的下限会直接丢弃大步滚动后的有效帧。
    private static let minimumOverlapFraction = 0.10
    private static let maximumStaticBandFraction = 0.30
    private static let minimumStaticBandHeight = 8
    private static let maximumStaticBandHeight = 240
    private static let rowSampleCount = 48
    private static let matchThreshold = 12.0

    static func stitch(
        _ images: [CGImage],
        expectedOffset: Int? = nil
    ) -> CGImage? {
        guard !images.isEmpty else { return nil }
        guard images.dropFirst().allSatisfy({
            $0.width == images[0].width && $0.height == images[0].height
        }) else { return nil }
        if images.count == 1 { return images[0] }

        let normalized = images.compactMap(NormalizedFrame.init)
        guard normalized.count == images.count else { return nil }

        let bands = staticBands(in: normalized)
        let contentHeight = images[0].height - bands.top - bands.bottom
        guard contentHeight >= 32 else { return nil }

        let contentFrames = normalized.map {
            $0.cropping(top: bands.top, bottom: bands.bottom)
        }

        var stitched = contentFrames[0]
        for index in 1..<contentFrames.count {
            guard let offset = bestOffset(
                between: contentFrames[index - 1],
                and: contentFrames[index],
                expected: expectedOffset
            ) else {
                return nil
            }
            guard let next = append(
                base: stitched,
                current: contentFrames[index],
                offset: offset
            ) else {
                return nil
            }
            stitched = next
        }

        return compose(
            first: normalized[0],
            last: normalized[normalized.count - 1],
            dynamic: stitched,
            topBand: bands.top,
            bottomBand: bands.bottom
        )
    }

    static func fingerprint(_ image: CGImage) -> Data {
        guard let data = image.dataProvider?.data else { return Data() }
        return data as Data
    }

    private struct StaticBands {
        let top: Int
        let bottom: Int
    }

    private struct NormalizedFrame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: Data

        init?(_ image: CGImage) {
            let imageWidth = image.width
            let imageHeight = image.height
            let imageBytesPerRow = imageWidth * 4
            var rendered = Data(repeating: 0, count: imageBytesPerRow * imageHeight)
            let success = rendered.withUnsafeMutableBytes { buffer -> Bool in
                guard let base = buffer.baseAddress,
                      let context = CGContext(
                          data: base,
                          width: imageWidth,
                          height: imageHeight,
                          bitsPerComponent: 8,
                          bytesPerRow: imageBytesPerRow,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else {
                    return false
                }
                // 把 CGImage 转为视觉上的 top-to-bottom 行序，匹配滚动内容的
                // “上一帧底部 -> 下一帧顶部”关系。
                context.translateBy(x: 0, y: CGFloat(imageHeight))
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(imageWidth),
                    height: CGFloat(imageHeight)
                ))
                return true
            }
            guard success else { return nil }
            width = imageWidth
            height = imageHeight
            bytesPerRow = imageBytesPerRow
            data = rendered
        }

        func cropping(top: Int, bottom: Int) -> NormalizedFrame {
            let start = max(0, top) * bytesPerRow
            let endRow = max(top, height - max(0, bottom))
            let end = endRow * bytesPerRow
            return NormalizedFrame(
                width: width,
                height: endRow - max(0, top),
                bytesPerRow: bytesPerRow,
                data: data.subdata(in: start..<end)
            )
        }

        fileprivate init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.data = data
        }
    }

    private static func staticBands(in frames: [NormalizedFrame]) -> StaticBands {
        guard let first = frames.first else { return StaticBands(top: 0, bottom: 0) }
        let maximum = min(
            maximumStaticBandHeight,
            Int(Double(first.height) * maximumStaticBandFraction)
        )
        guard maximum >= minimumStaticBandHeight else {
            return StaticBands(top: 0, bottom: 0)
        }

        var top = 0
        while top < maximum,
              isStaticRow(top, in: frames) {
            top += 1
        }
        if top < minimumStaticBandHeight { top = 0 }

        var bottom = 0
        while bottom < maximum - top,
              isStaticRow(first.height - bottom - 1, in: frames) {
            bottom += 1
        }
        if bottom < minimumStaticBandHeight { bottom = 0 }

        return StaticBands(top: top, bottom: bottom)
    }

    private static func isStaticRow(_ row: Int, in frames: [NormalizedFrame]) -> Bool {
        guard let first = frames.first, row >= 0, row < first.height else { return false }
        return frames.dropFirst().allSatisfy {
            rowDifference(first, row: row, $0, row: row) <= 4.0
        }
    }

    private static func bestOffset(
        between previous: NormalizedFrame,
        and current: NormalizedFrame,
        expected: Int?
    ) -> Int? {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.height > 0 else {
            return nil
        }

        let minimumOverlap = max(
            16,
            Int(Double(previous.height) * minimumOverlapFraction)
        )
        let maximumOffset = previous.height - minimumOverlap
        guard maximumOffset >= 1 else { return nil }

        var ranges: [ClosedRange<Int>] = []
        if let expected {
            let radius = max(120, expected / 3)
            let lower = max(1, expected - radius)
            let upper = min(maximumOffset, expected + radius)
            if lower <= upper { ranges.append(lower...upper) }
        }
        ranges.append(1...maximumOffset)

        var best: (offset: Int, score: Double)?
        for range in ranges {
            for offset in range {
                let score = overlapScore(previous: previous, current: current, offset: offset)
                if best == nil || score < best!.score {
                    best = (offset, score)
                }
            }
            if let best, best.score <= matchThreshold { break }
        }

        guard let best, best.score <= matchThreshold else { return nil }
        return best.offset
    }

    private static func overlapScore(
        previous: NormalizedFrame,
        current: NormalizedFrame,
        offset: Int
    ) -> Double {
        let overlap = previous.height - offset
        guard overlap > 0 else { return .greatestFiniteMagnitude }

        let sampleStep = max(1, previous.width / rowSampleCount)
        var difference = 0.0
        var samples = 0
        for row in 0..<overlap {
            let previousRow = offset + row
            let currentRow = row
            for x in stride(from: 0, to: previous.width, by: sampleStep) {
                let previousIndex = previousRow * previous.bytesPerRow + x * 4
                let currentIndex = currentRow * current.bytesPerRow + x * 4
                difference += abs(Double(previous.data[previousIndex]) - Double(current.data[currentIndex]))
                difference += abs(Double(previous.data[previousIndex + 1]) - Double(current.data[currentIndex + 1]))
                difference += abs(Double(previous.data[previousIndex + 2]) - Double(current.data[currentIndex + 2]))
                samples += 3
            }
        }
        return samples > 0 ? difference / Double(samples) : .greatestFiniteMagnitude
    }

    private static func rowDifference(
        _ lhs: NormalizedFrame,
        row lhsRow: Int,
        _ rhs: NormalizedFrame,
        row rhsRow: Int
    ) -> Double {
        guard lhs.width == rhs.width,
              lhsRow >= 0, lhsRow < lhs.height,
              rhsRow >= 0, rhsRow < rhs.height else {
            return .greatestFiniteMagnitude
        }
        let step = max(1, lhs.width / rowSampleCount)
        var difference = 0.0
        var samples = 0
        for x in stride(from: 0, to: lhs.width, by: step) {
            let lhsIndex = lhsRow * lhs.bytesPerRow + x * 4
            let rhsIndex = rhsRow * rhs.bytesPerRow + x * 4
            difference += abs(Double(lhs.data[lhsIndex]) - Double(rhs.data[rhsIndex]))
            difference += abs(Double(lhs.data[lhsIndex + 1]) - Double(rhs.data[rhsIndex + 1]))
            difference += abs(Double(lhs.data[lhsIndex + 2]) - Double(rhs.data[rhsIndex + 2]))
            samples += 3
        }
        return samples > 0 ? difference / Double(samples) : .greatestFiniteMagnitude
    }

    private static func append(
        base: NormalizedFrame,
        current: NormalizedFrame,
        offset: Int
    ) -> NormalizedFrame? {
        guard base.width == current.width,
              offset > 0,
              offset < current.height else {
            return nil
        }
        let newStart = (current.height - offset) * current.bytesPerRow
        var data = base.data
        data.append(current.data.suffix(from: newStart))
        return NormalizedFrame(
            width: base.width,
            height: base.height + offset,
            bytesPerRow: base.bytesPerRow,
            data: data
        )
    }

    private static func compose(
        first: NormalizedFrame,
        last: NormalizedFrame,
        dynamic: NormalizedFrame,
        topBand: Int,
        bottomBand: Int
    ) -> CGImage? {
        let width = dynamic.width
        let height = topBand + dynamic.height + bottomBand
        guard height > 0 else { return nil }

        var data = Data()
        if topBand > 0 {
            data.append(first.data.prefix(topBand * first.bytesPerRow))
        }
        data.append(dynamic.data)
        if bottomBand > 0 {
            let start = (last.height - bottomBand) * last.bytesPerRow
            data.append(last.data.suffix(from: start))
        }
        guard data.count == height * first.bytesPerRow else { return nil }
        return makeImage(
            width: width,
            height: height,
            bytesPerRow: first.bytesPerRow,
            data: data
        )
    }

    private static func makeImage(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        data: Data
    ) -> CGImage? {
        // `data` 使用的是视觉上的 top-to-bottom 行序；CGImage provider 的
        // 原始行序需要反过来，否则导出的 PNG 会整体上下翻转。
        guard height > 0 else { return nil }
        var providerData = Data()
        providerData.reserveCapacity(data.count)
        for row in stride(from: height - 1, through: 0, by: -1) {
            let start = row * bytesPerRow
            providerData.append(data[start..<(start + bytesPerRow)])
        }
        guard let provider = CGDataProvider(data: providerData as CFData) else { return nil }
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
}

/// ScreenCaptureKit 连续帧采集器。滚动服务只读取稳定后的最新帧，避免每次
/// 滚动都重新启动 `screencapture` 并把命令行截图延迟混入拼接结果。
@MainActor
final class ScreenshotScreenCaptureSession {
    private let screen: NSScreen
    private let sourceRect: CGRect
    private let targetMode: ScreenshotLongCaptureTargetMode
    private let frameStore = ScreenshotStreamFrameStore()
    private let errorStore = ScreenshotStreamErrorStore()
    private let sampleQueue = DispatchQueue(label: "com.qoder.menutools.screenshot-stream")
    private var stream: SCStream?
    private var output: ScreenshotStreamOutput?

    init(
        screen: NSScreen,
        sourceRect: CGRect,
        targetMode: ScreenshotLongCaptureTargetMode = .display
    ) {
        self.screen = screen
        self.sourceRect = sourceRect
        self.targetMode = targetMode
    }

    static func localSourceRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    func start() async throws {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ScreenshotError.captureFailed("无法确定显示器")
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.captureFailed("无法找到目标显示器")
        }

        let filter: SCContentFilter
        switch targetMode {
        case .display:
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            // 区域模式读取真实显示器画面，但排除 MenuTools 自己的选区提示层。
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        case let .window(windowID):
            // 窗口模式固定使用启动采集时的窗口 ID，不能在选区层出现后重新查询前台窗口。
            guard let targetWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenshotError.captureFailed("无法找到目标窗口的屏幕内容")
            }
            filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        }
        let scale = max(screen.backingScaleFactor, 1)
        let configuration = SCStreamConfiguration()
        // desktopIndependentWindow 的坐标原点是窗口左上角；显示器过滤器
        // 则使用显示器左上角。统一转换后才能避免多显示器或窗口过滤下的错位裁剪。
        configuration.sourceRect = switch targetMode {
        case .display:
            sourceRect
        case .window:
            CGRect(origin: .zero, size: sourceRect.size)
        }
        configuration.width = max(2, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(2, Int((sourceRect.height * scale).rounded()))
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4

        let output = ScreenshotStreamOutput(store: frameStore)
        output.errorStore = errorStore
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.output = output
        self.stream = stream
    }

    func waitForSettledImage(previousFingerprint: Data?) async throws -> CGImage? {
        var lastFingerprint: Data?
        var stableSamples = 0
        var latest: CGImage?

        // 不要让“完成长截图”在没有新画面时卡住约两秒才响应；稳定帧通常
        // 只需要连续几个采样，超时后由上层继续等待即可。
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let error = errorStore.message() {
                throw ScreenshotError.captureFailed(error)
            }
            if let image = frameStore.snapshot() {
                latest = image
                let fingerprint = ScreenshotFrameStitcher.fingerprint(image)
                if fingerprint == lastFingerprint {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                    lastFingerprint = fingerprint
                }
                if stableSamples >= 2,
                   previousFingerprint == nil || fingerprint != previousFingerprint {
                    return image
                }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        // 首帧允许使用当前画面作为初始内容；后续调用如果在等待窗口内没有
        // 得到稳定的新画面，必须返回 nil，让上层继续等待用户滚动，不能把
        // 未稳定的过渡帧当成一次有效滚动。
        return previousFingerprint == nil ? latest : nil
    }

    func stop() async throws {
        let activeStream = stream
        self.stream = nil
        output = nil
        try await activeStream?.stopCapture()
        if let error = errorStore.message() {
            throw ScreenshotError.captureFailed(error)
        }
    }
}

private final class ScreenshotStreamFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGImage?

    func update(_ image: CGImage) {
        lock.lock()
        latest = image
        lock.unlock()
    }

    func snapshot() -> CGImage? {
        lock.lock()
        let image = latest
        lock.unlock()
        return image
    }
}

private final class ScreenshotStreamErrorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func update(_ error: Error) {
        lock.lock()
        value = error.localizedDescription
        lock.unlock()
    }

    func message() -> String? {
        lock.lock()
        let value = self.value
        lock.unlock()
        return value
    }
}

private final class ScreenshotStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let store: ScreenshotStreamFrameStore
    private let ciContext = CIContext(options: nil)
    weak var errorStore: ScreenshotStreamErrorStore?

    init(store: ScreenshotStreamFrameStore) {
        self.store = store
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        store.update(cgImage)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorStore?.update(error)
    }
}
