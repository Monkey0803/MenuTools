import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// 将 Snapzy 的“冻结显示器帧后裁剪”流程与窗口截图后端隔离。
///
/// 选区阶段不再让系统截图工具重新合成桌面，因此不会把选区提示、菜单栏
/// 弹层或鼠标移动造成的瞬态 UI 混入最终图片。CGImage 的尺寸始终使用显示器
/// 当前返回的原生像素尺寸，不假设 Retina 为固定 2 倍。
enum ScreenshotDisplayImageCropper {
    static func pixelCropRect(
        for selection: CGRect,
        in displayFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard displayFrame.width > 0,
              displayFrame.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return nil
        }

        let relative = selection.offsetBy(
            dx: -displayFrame.minX,
            dy: -displayFrame.minY
        ).intersection(
            CGRect(origin: .zero, size: displayFrame.size)
        )
        guard !relative.isNull, !relative.isEmpty else { return nil }

        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let pixelRect = CGRect(
            x: relative.minX * scaleX,
            // AppKit 的原点在左下角，CGImage 裁剪坐标从左上角开始。
            y: (displayFrame.height - relative.maxY) * scaleY,
            width: relative.width * scaleX,
            height: relative.height * scaleY
        ).integral

        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clamped = pixelRect.intersection(imageBounds).integral
        return clamped.width > 0 && clamped.height > 0 ? clamped : nil
    }

    static func crop(
        _ image: CGImage,
        selection: CGRect,
        displayFrame: CGRect
    ) -> CGImage? {
        guard let rect = pixelCropRect(
            for: selection,
            in: displayFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        ) else {
            return nil
        }
        return image.cropping(to: rect)
    }

    /// 合成跨显示器的选区。输出统一采用选区内最高原生像素倍率，低倍率
    /// 显示器只在跨屏合成时放大，单屏路径不会被重复重采样。
    static func cropComposite(
        _ snapshots: [(displayFrame: CGRect, image: CGImage)],
        selection: CGRect
    ) -> CGImage? {
        let intersecting = snapshots.compactMap { snapshot -> (intersection: CGRect, displayFrame: CGRect, image: CGImage, scale: CGFloat)? in
            let intersection = snapshot.displayFrame.intersection(selection)
            guard !intersection.isNull, !intersection.isEmpty,
                  snapshot.displayFrame.width > 0,
                  snapshot.displayFrame.height > 0 else { return nil }
            let scale = max(
                CGFloat(snapshot.image.width) / snapshot.displayFrame.width,
                CGFloat(snapshot.image.height) / snapshot.displayFrame.height
            )
            return (intersection, snapshot.displayFrame, snapshot.image, scale)
        }
        guard !intersecting.isEmpty,
              selection.width > 0,
              selection.height > 0 else { return nil }

        let outputScale = intersecting.map(\.scale).max() ?? 1
        let outputWidth = max(1, Int((selection.width * outputScale).rounded()))
        let outputHeight = max(1, Int((selection.height * outputScale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.translateBy(x: 0, y: CGFloat(outputHeight))
        context.scaleBy(x: 1, y: -1)

        for (intersection, displayFrame, image, _) in intersecting {
            guard let cropped = crop(
                image,
                selection: intersection,
                displayFrame: displayFrame
            ) else { continue }
            let destination = CGRect(
                x: (intersection.minX - selection.minX) * outputScale,
                y: (selection.maxY - intersection.maxY) * outputScale,
                width: intersection.width * outputScale,
                height: intersection.height * outputScale
            )
            context.draw(cropped, in: destination)
        }
        return context.makeImage()
    }
}

@MainActor
protocol ScreenshotImageCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage
    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage
}

/// 直接读取 WindowServer 的单帧图像。它是 Snapzy 的低延迟采集路径；
/// `ScreenshotService` 在 TCC 尚未授权或窗口已消失时会回退到 screencapture。
@MainActor
final class DefaultScreenshotImageCapturer: ScreenshotImageCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.imageUnavailable
        }

        let screen = NSScreen.screens.first(where: { $0.screenshotDisplayID == displayID })
        let logicalSize = screen?.frame.size ?? display.frame.size
        let scale = max(screen?.backingScaleFactor ?? 1, 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((logicalSize.width * scale).rounded()))
        configuration.height = max(1, Int((logicalSize.height * scale).rounded()))
        configuration.showsCursor = false
        if #available(macOS 14.2, *) {
            configuration.captureResolution = .best
        }
        let excludedApplications = Bundle.main.bundleIdentifier.map { bundleID in
            content.applications.filter { $0.bundleIdentifier == bundleID }
        } ?? []
        let filter: SCContentFilter
        if excludedApplications.isEmpty {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenshotError.imageUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let logicalSize = window.frame.size
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((logicalSize.width * scale).rounded()))
        configuration.height = max(1, Int((logicalSize.height * scale).rounded()))
        configuration.showsCursor = false
        if #available(macOS 14.2, *) {
            configuration.captureResolution = .best
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

extension NSScreen {
    var screenshotDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
