import AppKit
import Testing
@testable import MenuTools

@Test("菜单栏弹层窗口使用透明底板")
@MainActor
func menuBarPopoverWindowUsesTransparentBacking() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.backgroundColor = .windowBackgroundColor
    window.isOpaque = true

    MenuBarStatusItemController.configurePopoverWindow(window)

    #expect(window.backgroundColor == .clear)
    #expect(!window.isOpaque)
    #expect(window.contentView?.wantsLayer == true)
    #expect(window.contentView?.layer?.backgroundColor == NSColor.clear.cgColor)
}
