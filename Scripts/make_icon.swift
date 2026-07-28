#!/usr/bin/swift
// 程序化生成 MenuTools 的 App 图标：渐变底 + 液态玻璃高光 + SF Symbol
import AppKit

let canvas: CGFloat = 1024

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let s = size / canvas
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS 图标本身留出边距，由系统绘制圆角遮罩；这里自绘 squircle
    let inset = 100 * s
    let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                xRadius: 185 * s, yRadius: 185 * s)

    // 背景渐变：蓝 -> 紫
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.48, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.52, green: 0.32, blue: 0.92, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -60)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // 玻璃高光：顶部弧形亮带
    let highlight = NSBezierPath(ovalIn: NSRect(x: -0.2 * size, y: 0.52 * size,
                                                width: 1.4 * size, height: 0.9 * size))
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.38),
        NSColor.white.withAlphaComponent(0.02),
    ])!.draw(in: highlight, angle: -90)

    // 底部反光
    let bottomGlow = NSBezierPath(ovalIn: NSRect(x: 0.1 * size, y: -0.35 * size,
                                                 width: 0.8 * size, height: 0.55 * size))
    NSColor.white.withAlphaComponent(0.10).setFill()
    bottomGlow.fill()

    NSGraphicsContext.current?.restoreGraphicsState()

    // 中心符号：wrench.and.screwdriver.fill
    let config = NSImage.SymbolConfiguration(pointSize: 380 * s, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let scale = min((520 * s) / symbolSize.width, (520 * s) / symbolSize.height)
        let w = symbolSize.width * scale
        let h = symbolSize.height * scale
        let origin = NSPoint(x: (size - w) / 2, y: (size - h) / 2)

        // 轻微阴影增加玻璃悬浮感
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()

        symbol.draw(in: NSRect(x: origin.x, y: origin.y, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 0.96)
    }

    return image
}

func savePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let master = drawIcon(size: canvas)
for (name, px) in sizes {
    savePNG(master, pixels: px, to: outDir.appendingPathComponent("\(name).png"))
}
print("iconset 已生成：\(outDir.path)")
