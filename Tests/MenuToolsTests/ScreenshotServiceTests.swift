import CoreGraphics
import Foundation
import Testing
@testable import MenuTools

@MainActor
private struct NoScreenshotShortcutConflictChecker: ShortcutConflictChecking {
    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource? {
        nil
    }
}

@Test("截图模式覆盖全屏、自定义、当前窗口和长截图")
func screenshotModesContainExpectedOptions() {
    #expect(ScreenshotCaptureMode.allCases == [.fullScreen, .custom, .window, .long])
}

@Test("选区几何支持反向拖拽并生成稳定尺寸文案")
func screenshotSelectionGeometryNormalizesDrag() {
    #expect(
        ScreenshotSelectionGeometry.rect(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 100, y: 200))
            == CGRect(x: 100, y: 200, width: 200, height: 300)
    )
    #expect(ScreenshotSelectionGeometry.sizeLabel(for: CGRect(x: 0, y: 0, width: 200.6, height: 100.4)) == "201 × 100")
}

@Test("选区交互状态机覆盖拖选、窗口模式和取消")
func screenshotSelectionInteractionStateMachineHandlesCoreEvents() {
    let target = ScreenshotWindowTarget(
        id: 7,
        frame: CGRect(x: 200, y: 200, width: 500, height: 400),
        ownerName: "Demo",
        title: "Window"
    )
    var model = ScreenshotSelectionInteractionModel(
        allowsWindowMode: true,
        windowTargets: [target]
    )

    #expect(model.handle(.mouseDown(CGPoint(x: 1_800, y: 500))) == .none)
    #expect(model.handle(.mouseDragged(CGPoint(x: -100, y: 100))) == .none)
    #expect(model.selection == CGRect(x: -100, y: 100, width: 1_900, height: 400))
    #expect(
        model.handle(.mouseUp(CGPoint(x: -100, y: 100)))
            == .completed(.region(CGRect(x: -100, y: 100, width: 1_900, height: 400)))
    )

    #expect(model.handle(.toggleWindowMode) == .none)
    #expect(model.handle(.mouseMoved(CGPoint(x: 250, y: 250))) == .none)
    #expect(model.highlightedWindow == target)
    #expect(model.handle(.mouseDown(CGPoint(x: 250, y: 250))) == .completed(.window(7)))

    var cancelled = ScreenshotSelectionInteractionModel(allowsWindowMode: false, windowTargets: [])
    #expect(cancelled.handle(.cancel) == .cancelled)
}

@Test("截图命令按模式生成正确参数")
func screenshotCommandsMatchCaptureMode() {
    let outputURL = URL(fileURLWithPath: "/tmp/MenuTools-test.png")

    #expect(
        ScreenshotCommandBuilder.arguments(for: .fullScreen, outputURL: outputURL)
            == ["-x", outputURL.path]
    )
    #expect(
        ScreenshotCommandBuilder.arguments(for: .custom, outputURL: outputURL)
            == ["-x", "-i", outputURL.path]
    )
    #expect(
        ScreenshotCommandBuilder.windowArguments(windowID: 42, outputURL: outputURL)
            == ["-x", "-l", "42", outputURL.path]
    )
    #expect(
        ScreenshotCommandBuilder.windowSelectionArguments(outputURL: outputURL)
            == ["-x", "-i", "-w", outputURL.path]
    )
    #expect(
        ScreenshotCommandBuilder.regionArguments(
            rect: CGRect(x: 12.4, y: 25.6, width: 300.2, height: 180.8),
            outputURL: outputURL
        )
            == ["-x", "-R", "12,26,300,181", outputURL.path]
    )
}

@Test("长截图区域模式不绑定前台窗口，窗口模式保留已选窗口")
func longScreenshotTargetModePreservesSelectionBoundary() {
    #expect(
        ScreenshotLongCaptureTargetMode.forCapture(
            selectRegion: true,
            selectedWindowID: 42
        ) == .display
    )
    #expect(
        ScreenshotLongCaptureTargetMode.forCapture(
            selectRegion: false,
            selectedWindowID: 42
        ) == .window(42)
    )
}

@Test("截图编辑会话存在时仍然保持忙状态")
func screenshotLifecycleTreatsEditorSessionAsBusy() {
    #expect(ScreenshotCaptureLifecycle.isBusy(isCapturing: false, hasEditorSession: true))
    #expect(ScreenshotCaptureLifecycle.isBusy(isCapturing: true, hasEditorSession: false))
    #expect(!ScreenshotCaptureLifecycle.isBusy(isCapturing: false, hasEditorSession: false))
}

@Test("采集清理失败不会被静默吞掉")
func screenshotCleanupFailureIsReported() {
    let error = ScreenshotCaptureCleanupError.combined(
        primary: NSError(domain: "ScreenshotTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "截图已取消"
        ]),
        cleanup: NSError(domain: "ScreenshotTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "停止失败"
        ])
    )

    #expect(error.localizedDescription == ScreenshotCaptureCleanupError.combinedDescription(
        primary: "截图已取消",
        cleanup: "停止失败"
    ))

    // 测试进程取不到 lproj，L() 返回 key 本身，因此用显式模板验证两个错误都被带进文案。
    let description = ScreenshotCaptureCleanupError.combinedDescription(
        primary: "截图已取消",
        cleanup: "停止失败",
        template: "%@；采集会话清理失败：%@"
    )
    #expect(description.contains("截图已取消"))
    #expect(description.contains("停止失败"))
}

@Test("截图服务会保存并恢复上次选区")
func screenshotRegionStoreRoundTrips() {
    let defaults = UserDefaults(suiteName: "ScreenshotRegionStoreTests")!
    defaults.removePersistentDomain(forName: "ScreenshotRegionStoreTests")
    let store = ScreenshotRegionStore(
        defaults: defaults,
        key: "region"
    )
    let region = CGRect(x: 120.5, y: 80, width: 640, height: 360)

    store.save(region)

    #expect(store.load() == region)
}

@Test("长截图自定义区域会转换为 screencapture 的屏幕坐标")
func longScreenshotRegionUsesScreenCoordinates() {
    let screen = CGRect(x: 100, y: 200, width: 1_920, height: 1_080)
    let appKitRect = CGRect(x: 260, y: 540, width: 640, height: 360)

    #expect(
        ScreenshotRegionCoordinateConverter.screencaptureRect(
            from: appKitRect,
            in: screen
        ) == CGRect(x: 160, y: 380, width: 640, height: 360)
    )
}

@Test("窗口 Quartz 坐标可以转换为 AppKit 和 ScreenCaptureKit 坐标")
func windowCoordinatesUseDisplayLocalSpace() {
    let displayBounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let screenFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let quartzRect = CGRect(x: 260, y: 180, width: 640, height: 360)

    #expect(
        ScreenshotWindowCoordinateConverter.appKitRect(
            from: quartzRect,
            displayBounds: displayBounds,
            screenFrame: screenFrame
        ) == CGRect(x: 260, y: 540, width: 640, height: 360)
    )
    #expect(
        ScreenshotWindowCoordinateConverter.localSourceRect(
            from: quartzRect,
            displayBounds: displayBounds
        ) == CGRect(x: 260, y: 180, width: 640, height: 360)
    )
}

@Test("非主屏窗口坐标使用显示器自身原点")
func windowCoordinatesPreserveSecondaryDisplayOrigin() {
    let displayBounds = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
    let screenFrame = CGRect(x: -1_920, y: 120, width: 1_920, height: 1_080)
    let quartzRect = CGRect(x: -1_700, y: 180, width: 640, height: 360)

    #expect(
        ScreenshotWindowCoordinateConverter.appKitRect(
            from: quartzRect,
            displayBounds: displayBounds,
            screenFrame: screenFrame
        ) == CGRect(x: -1_700, y: 660, width: 640, height: 360)
    )
    #expect(
        ScreenshotWindowCoordinateConverter.localSourceRect(
            from: quartzRect,
            displayBounds: displayBounds
        ) == CGRect(x: 220, y: 180, width: 640, height: 360)
    )
}

@Test("副屏 AppKit 鼠标坐标转换为 Quartz 全局坐标")
func appKitMouseCoordinatesUseQuartzDisplayOrigin() {
    let displayBounds = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
    let screenFrame = CGRect(x: -1_920, y: 360, width: 1_920, height: 1_080)

    #expect(
        ScreenshotScreenCoordinateConverter.quartzPoint(
            from: CGPoint(x: -1_700, y: 660),
            screenFrame: screenFrame,
            displayBounds: displayBounds
        ) == CGPoint(x: -1_700, y: 780)
    )
    #expect(
        ScreenshotScrollLocation.forSelectedRegion(
            CGRect(x: -1_800, y: 600, width: 400, height: 300),
            in: screenFrame,
            displayBounds: displayBounds
        ) == CGPoint(x: -1_600, y: 690)
    )
}

@Test("长截图内存保护按总像素字节数限制追加帧")
func longScreenshotMemoryLimitProtectsLargeFrames() {
    #expect(
        ScreenshotLongCaptureLimits.canAppend(
            width: 2_000,
            height: 1_000,
            currentBytes: 0
        )
    )
    #expect(
        !ScreenshotLongCaptureLimits.canAppend(
            width: 8_000,
            height: 6_000,
            currentBytes: ScreenshotLongCaptureLimits.maximumBytes - 1
        )
    )
}

@Test("窗口悬停命中测试返回最前面的候选窗口")
func screenshotWindowHitTestReturnsFrontmostCandidate() {
    let back = ScreenshotWindowTarget(
        id: 10,
        frame: CGRect(x: 100, y: 100, width: 500, height: 400),
        ownerName: "Back",
        title: nil
    )
    let front = ScreenshotWindowTarget(
        id: 20,
        frame: CGRect(x: 200, y: 200, width: 500, height: 400),
        ownerName: "Front",
        title: "Window"
    )

    #expect(ScreenshotWindowQuery.hitTest(CGPoint(x: 250, y: 250), targets: [front, back]) == front)
    #expect(ScreenshotWindowQuery.hitTest(CGPoint(x: 120, y: 120), targets: [front, back]) == back)
    #expect(ScreenshotWindowQuery.hitTest(CGPoint(x: 10, y: 10), targets: [front, back]) == nil)
}

@Test("冻结显示器截图裁剪使用原生像素并翻转 AppKit Y 坐标")
func frozenDisplayCropUsesNativePixels() {
    let displayFrame = CGRect(x: 100, y: 200, width: 1_920, height: 1_080)
    let selection = CGRect(x: 260, y: 540, width: 640, height: 360)

    #expect(
        ScreenshotDisplayImageCropper.pixelCropRect(
            for: selection,
            in: displayFrame,
            imageSize: CGSize(width: 3_840, height: 2_160)
        ) == CGRect(x: 320, y: 760, width: 1_280, height: 720)
    )
}

@Test("越界的冻结显示器选区会被限制在截图像素范围内")
func frozenDisplayCropClampsToImageBounds() {
    let displayFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let selection = CGRect(x: -50, y: 700, width: 200, height: 200)

    #expect(
        ScreenshotDisplayImageCropper.pixelCropRect(
            for: selection,
            in: displayFrame,
            imageSize: CGSize(width: 1_000, height: 800)
        ) == CGRect(x: 0, y: 0, width: 150, height: 100)
    )
}

@Test("跨显示器冻结选区会合成为一张连续图片")
func frozenDisplayCropCompositesIntersectingDisplays() {
    let left = makeSolidTestImage(width: 200, height: 200, value: 20)
    let right = makeSolidTestImage(width: 200, height: 200, value: 80)
    let snapshots: [(displayFrame: CGRect, image: CGImage)] = [
        (CGRect(x: 0, y: 0, width: 100, height: 100), left),
        (CGRect(x: 100, y: 0, width: 100, height: 100), right)
    ]

    let result = ScreenshotDisplayImageCropper.cropComposite(
        snapshots,
        selection: CGRect(x: 50, y: 10, width: 100, height: 80)
    )

    #expect(result?.width == 200)
    #expect(result?.height == 160)
}

@Test("显示器错位时中心落在间隙的选区仍可合成")
func frozenDisplayCropAllowsSelectionCenterInDisplayGap() {
    let lower = makeSolidTestImage(width: 100, height: 400, value: 20)
    let upper = makeSolidTestImage(width: 100, height: 400, value: 80)
    let snapshots: [(displayFrame: CGRect, image: CGImage)] = [
        (CGRect(x: 0, y: 0, width: 100, height: 400), lower),
        (CGRect(x: 0, y: 500, width: 100, height: 400), upper)
    ]

    let result = ScreenshotDisplayImageCropper.cropComposite(
        snapshots,
        selection: CGRect(x: 0, y: 350, width: 100, height: 200)
    )

    #expect(result?.width == 100)
    #expect(result?.height == 200)
}

@Test("OCR 文本和二维码结果会去重并保持可复制格式")
func screenshotOCRResultComposerDeduplicatesPayloads() {
    #expect(
        ScreenshotOCRResultComposer.compose(
            textLines: ["订单号 ABC-123", "https://example.com"],
            barcodePayloads: ["https://example.com", "otpauth://totp/demo", "otpauth://totp/demo"]
        ) == "订单号 ABC-123\nhttps://example.com\notpauth://totp/demo"
    )
}

@Test("长截图滚动位置使用用户选区中心")
func longScreenshotScrollsAtSelectedRegionCenter() {
    let screen = CGRect(x: 100, y: 200, width: 1_920, height: 1_080)
    let region = CGRect(x: 260, y: 540, width: 640, height: 360)

    #expect(
        ScreenshotScrollLocation.forSelectedRegion(
            region,
            in: screen,
            displayBounds: screen
        )
            == CGPoint(x: 580, y: 760)
    )
}

@Test("长截图拼接高度会扣除相邻截图重叠区域")
func longScreenshotHeightAccountsForOverlap() {
    #expect(ScreenshotImageStitcher.outputHeight(for: [800, 800, 800], overlap: 120) == 2_160)
}

@Test("长截图拼接会按 Vision 识别出的新增行数追加内容")
func longScreenshotStitcherAppendsDetectedRows() {
    let first = makeStitchTestImage(values: Array(UInt8(0)..<UInt8(40)))
    let second = makeStitchTestImage(
        values: Array(UInt8(25)..<UInt8(40)) + Array(UInt8(0)..<UInt8(25))
    )

    let stitched = ScreenshotImageStitcher.verticallyStitchByNewRows(
        [first, second],
        newRows: [15]
    )

    #expect(stitched?.height == 55)
    #expect(rawRows(stitched!) == Array(rawRows(second).prefix(15)) + rawRows(first))
}

@Test("长截图向下滚动只追加当前帧底部新增区域")
func longScreenshotStitcherAppendsBottomStripWithoutRepeatingOldContent() {
    let first = makeStitchTestImage(values: Array(UInt8(0)..<UInt8(40)))
    let second = makeStitchTestImage(
        values: Array(UInt8(40)..<UInt8(55)) + Array(UInt8(0)..<UInt8(25))
    )

    let stitched = ScreenshotImageStitcher.verticallyStitchByScrollOffsets(
        [first, second],
        offsets: [15]
    )

    #expect(stitched?.height == 55)
    #expect(rawRows(stitched!) == Array(UInt8(40)..<UInt8(55)) + rawRows(first))
}

@Test("长截图固定顶部区域只保留一次")
func longScreenshotStitcherRemovesRepeatedStaticHeader() {
    let first = makeStitchTestImage(
        values: Array(UInt8(0)..<UInt8(80)).reversed() + Array(repeating: 240, count: 8)
    )
    let second = makeStitchTestImage(
        values: Array(UInt8(10)..<UInt8(90)).reversed() + Array(repeating: 240, count: 8)
    )

    let stitched = ScreenshotFrameStitcher.stitch(
        [first, second],
        expectedOffset: 10
    )

    #expect(stitched?.height == 98)
}

@Test("长截图连续滚动帧保持内容顺序")
func longScreenshotStitcherPreservesScrollOrder() {
    let first = makeStitchTestImage(values: Array(UInt8(0)..<UInt8(100)).reversed())
    let second = makeStitchTestImage(values: Array(UInt8(15)..<UInt8(115)).reversed())
    let third = makeStitchTestImage(values: Array(UInt8(30)..<UInt8(130)).reversed())

    let stitched = ScreenshotFrameStitcher.stitch(
        [first, second, third],
        expectedOffset: 15
    )

    #expect(stitched?.height == 130)
    let expectedFirst = (0..<100).map { UInt8($0) }
    let expectedSecond = (0..<15).map { UInt8(100 + $0) }
    let expectedThird = (0..<15).map { UInt8(115 + $0) }
    let expected = expectedFirst + expectedSecond + expectedThird
    #expect(visualRows(stitched!) == expected)
}

@Test("长截图像素重叠无法确认时拒绝拼接")
func longScreenshotStitcherRejectsUnmatchedFrame() {
    let first = makeStitchTestImage(values: Array(UInt8(0)..<UInt8(40)))
    let unrelated = makeStitchTestImage(values: Array(repeating: 255, count: 40))

    #expect(
        ScreenshotFrameStitcher.stitch(
            [first, unrelated],
            expectedOffset: 10
        ) == nil
    )
}

private func makeStitchTestImage(values: [UInt8], width: Int = 16) -> CGImage {
    let bytesPerRow = width * 4
    var data = Data(repeating: 0, count: bytesPerRow * values.count)
    data.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for (row, value) in values.enumerated() {
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                base[offset] = value
                base[offset + 3] = 255
            }
        }
    }
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width,
        height: values.count,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makeSolidTestImage(width: Int, height: Int, value: UInt8) -> CGImage {
    makeStitchTestImage(values: Array(repeating: value, count: height), width: width)
}

private func rawRows(_ image: CGImage) -> [UInt8] {
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return [] }
    return (0..<image.height).map { bytes[$0 * image.bytesPerRow] }
}

private func visualRows(_ image: CGImage) -> [UInt8] {
    rawRows(image).reversed()
}

@Test("截图快捷键可以匹配绑定")
func screenshotShortcutMatchesBinding() {
    let bindings = [
        ScreenshotCaptureMode.fullScreen: GlobalShortcut(
            keyCode: 23,
            modifiers: GlobalShortcutModifier.controlOption
        ),
        ScreenshotCaptureMode.long: GlobalShortcut(
            keyCode: 24,
            modifiers: GlobalShortcutModifier.controlOption
        )
    ]
    #expect(
        ScreenshotShortcutCatalog.match(
            keyCode: 23,
            modifiers: GlobalShortcutModifier.controlOption,
            bindings: bindings
        ) == .fullScreen
    )
    #expect(
        ScreenshotShortcutCatalog.match(
            keyCode: 24,
            modifiers: GlobalShortcutModifier.controlOption,
            bindings: bindings
    ) == .long
    )
}

@Test("截图快捷键事件门只接受一次 global/local 重复 keyDown")
func screenshotShortcutEventGateDeduplicatesMonitorEvents() {
    var gate = ScreenshotShortcutEventGate()

    let first = gate.accept(keyCode: 23, modifiers: GlobalShortcutModifier.controlOption, timestamp: 10)
    let duplicate = gate.accept(keyCode: 23, modifiers: GlobalShortcutModifier.controlOption, timestamp: 10.1)
    let later = gate.accept(keyCode: 23, modifiers: GlobalShortcutModifier.controlOption, timestamp: 10.5)

    #expect(first)
    #expect(!duplicate)
    #expect(later)
}

@MainActor
@Test("截图快捷键可以按截图方式持久化")
func screenshotShortcutsPersistPerMode() throws {
    let suiteName = "MenuToolsTests.ScreenshotShortcutBindings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let service = ScreenshotShortcutService(
        defaults: defaults,
        conflictChecker: NoScreenshotShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] }
    )
    let binding = GlobalShortcut(keyCode: 23, modifiers: GlobalShortcutModifier.controlOption)

    try service.setBinding(binding, for: .custom)

    #expect(service.binding(for: .custom) == binding)
    #expect(service.binding(for: .fullScreen) == nil)

    let restored = ScreenshotShortcutService(
        defaults: defaults,
        conflictChecker: NoScreenshotShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] }
    )
    #expect(restored.binding(for: .custom) == binding)
}

@Test("截图输出格式提供 PNG、JPEG 和 WebP 扩展名")
func screenshotOutputFormatsExposeFileExtensions() {
    #expect(ScreenshotOutputFormat.png.fileExtension == "png")
    #expect(ScreenshotOutputFormat.jpeg.fileExtension == "jpg")
    #expect(ScreenshotOutputFormat.webp.fileExtension == "webp")
}

@Test("截图输出配置可以持久化并恢复")
func screenshotOutputConfigurationRoundTrips() throws {
    let suiteName = "MenuToolsTests.ScreenshotOutputConfiguration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configuration = ScreenshotOutputConfiguration(
        saveToDisk: false,
        directoryURL: URL(fileURLWithPath: "/tmp/MenuTools-Screenshots", isDirectory: true),
        format: .webp,
        namingTemplate: "Capture_{date}_{mode}"
    )
    configuration.save(to: defaults)

    #expect(ScreenshotOutputConfiguration.load(from: defaults) == configuration)
}

@Test("截图命名模板会替换日期、模式并清理非法字符")
func screenshotFileNamingSanitizesTemplate() {
    let date = Date(timeIntervalSince1970: 0)
    let name = ScreenshotFileNaming.makeBaseName(
        template: "MenuTools/{mode}: {date}",
        mode: .custom,
        date: date
    )

    #expect(name.contains("custom"))
    #expect(!name.contains("/"))
    #expect(!name.contains(":"))
}

@MainActor
@Test("截图历史记录支持写入、删除、清空并限制数量")
func screenshotHistoryStorePersistsRecentEntries() throws {
    let suiteName = "MenuToolsTests.ScreenshotHistory.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = ScreenshotHistoryStore(defaults: defaults, key: "history", maximumEntries: 2)
    let first = ScreenshotHistoryEntry(
        fileURL: URL(fileURLWithPath: "/tmp/first.png"),
        createdAt: Date(timeIntervalSince1970: 1),
        width: 100,
        height: 80,
        format: .png,
        mode: .fullScreen
    )
    let second = ScreenshotHistoryEntry(
        fileURL: URL(fileURLWithPath: "/tmp/second.jpg"),
        createdAt: Date(timeIntervalSince1970: 2),
        width: 200,
        height: 160,
        format: .jpeg,
        mode: .custom
    )
    let third = ScreenshotHistoryEntry(
        fileURL: URL(fileURLWithPath: "/tmp/third.webp"),
        createdAt: Date(timeIntervalSince1970: 3),
        width: 300,
        height: 240,
        format: .webp,
        mode: .window
    )

    store.add(first)
    store.add(second)
    store.add(third)
    #expect(store.entries.map(\.id) == [third.id, second.id])

    store.remove(id: second.id)
    #expect(store.entries.map(\.id) == [third.id])
    store.clear()
    #expect(store.entries.isEmpty)
}

@Test("编辑器裁剪会把归一化选区转换为像素坐标")
func screenshotEditorCropUsesImagePixelCoordinates() {
    #expect(
        ScreenshotImageTransform.pixelCropRect(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
            imageSize: CGSize(width: 1_000, height: 800)
        ) == CGRect(x: 100, y: 320, width: 500, height: 320)
    )
}
