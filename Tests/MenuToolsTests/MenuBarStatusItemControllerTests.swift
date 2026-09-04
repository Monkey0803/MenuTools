import AppKit
import SwiftUI
import Testing
@testable import MenuTools

@Test("剪贴板快捷键只确保历史面板显示，不反向关闭")
func clipboardQuickAccessDoesNotToggleVisiblePopover() {
    #expect(ClipboardQuickAccessPresentationPolicy.shouldShow(isShown: false))
    #expect(!ClipboardQuickAccessPresentationPolicy.shouldShow(isShown: true))
}

@Test("音量快捷键只确保音量面板显示，不反向关闭")
func appVolumeQuickAccessDoesNotToggleVisiblePopover() {
    #expect(AppVolumeQuickAccessPresentationPolicy.shouldShow(isShown: false))
    #expect(!AppVolumeQuickAccessPresentationPolicy.shouldShow(isShown: true))
}

@Test("窗口管理快捷键只确保布局面板显示，不反向关闭")
func windowManagementQuickAccessDoesNotToggleVisiblePopover() {
    #expect(WindowManagementQuickAccessPresentationPolicy.shouldShow(isShown: false))
    #expect(!WindowManagementQuickAccessPresentationPolicy.shouldShow(isShown: true))
}

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

@Test("设置窗口不会创建无内容工具栏")
@MainActor
func settingsWindowDoesNotCreateEmptyToolbar() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = NSHostingController(rootView: SettingsView())
    window.contentViewController?.view.layoutSubtreeIfNeeded()

    #expect(window.toolbar == nil)
}

@Test("菜单栏面板关闭后复用同一个 Popover")
@MainActor
func menuBarPopoverIsReused() {
    let existing = NSPopover()
    var creationCount = 0

    let reused = MenuBarStatusItemController.reusablePopover(existing: existing) {
        creationCount += 1
        return NSPopover()
    }
    let created = MenuBarStatusItemController.reusablePopover(existing: nil) {
        creationCount += 1
        return NSPopover()
    }

    #expect(reused === existing)
    #expect(created !== existing)
    #expect(creationCount == 1)
}
