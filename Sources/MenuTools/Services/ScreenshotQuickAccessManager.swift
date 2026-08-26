import AppKit
import SwiftUI

/// 截图完成后显示的轻量浮动卡片，提供 Snapzy 风格的复制、编辑、定位和删除入口。
@MainActor
final class ScreenshotQuickAccessManager {
    static let shared = ScreenshotQuickAccessManager()

    private var panel: NSPanel?
    private var pinWindow: NSPanel?
    private(set) var imageURL: URL?

    func show(imageURL: URL) {
        self.imageURL = imageURL
        let rootView = ScreenshotQuickAccessView(
            imageURL: imageURL,
            onCopy: { [weak self] in self?.copyImage() },
            onEdit: { [weak self] in self?.editImage() },
            onSaveOrReveal: { [weak self] in self?.saveOrRevealImage() },
            onReveal: { [weak self] in self?.revealImage() },
            onDelete: { [weak self] in self?.deleteImage() },
            onPin: { [weak self] in self?.pinImage() },
            onClose: { [weak self] in self?.hide() }
        )

        if let panel {
            panel.contentView = NSHostingView(rootView: rootView)
            position(panel)
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: rootView)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let x = min(max(mouse.x - panel.frame.width / 2, frame.minX + 16), frame.maxX - panel.frame.width - 16)
        let y = max(frame.minY + 16, frame.maxY - panel.frame.height - 28)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func copy(imageURL: URL) {
        guard let data = try? Data(contentsOf: imageURL), !data.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let format = ScreenshotHistoryStore.shared.entries.first(where: { $0.fileURL == imageURL })?.format ?? .png
        _ = pasteboard.setData(data, forType: NSPasteboard.PasteboardType(format.typeIdentifier))
        if let image = NSImage(contentsOf: imageURL), let tiff = image.tiffRepresentation {
            _ = pasteboard.setData(tiff, forType: .tiff)
        }
        ClipboardHistoryService.shared.refresh()
    }

    private func copyImage() {
        guard let imageURL else { return }
        copy(imageURL: imageURL)
    }

    private func editImage() {
        guard let imageURL else { return }
        edit(imageURL: imageURL)
    }

    func edit(imageURL: URL) {
        do {
            try ScreenshotService.shared.editCapture(at: imageURL)
            if self.imageURL == imageURL { hide() }
        } catch {
            NSSound.beep()
        }
    }

    private func revealImage() {
        guard let imageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
    }

    private func saveOrRevealImage() {
        guard let imageURL else { return }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuTools-Screenshots", isDirectory: true)
            .standardizedFileURL
        let normalizedPath = imageURL.standardizedFileURL.path
        let rootPath = temporaryRoot.path.hasSuffix("/") ? temporaryRoot.path : temporaryRoot.path + "/"
        guard normalizedPath.hasPrefix(rootPath) else {
            revealImage()
            return
        }

        let configuration = ScreenshotOutputConfiguration.load()
        let format = ScreenshotHistoryStore.shared.entries.first(where: { $0.fileURL == imageURL })?.format
            ?? configuration.format
        do {
            try FileManager.default.createDirectory(
                at: configuration.directoryURL,
                withIntermediateDirectories: true
            )
            let baseName = imageURL.deletingPathExtension().lastPathComponent
            let destination = ScreenshotFileNaming.uniqueURL(
                directory: configuration.directoryURL,
                baseName: baseName,
                format: format
            )
            try FileManager.default.moveItem(at: imageURL, to: destination)
            ScreenshotHistoryStore.shared.update(
                fileURL: destination,
                replacingPath: imageURL.path
            )
            self.imageURL = destination
            show(imageURL: destination)
        } catch {
            NSSound.beep()
        }
    }

    private func deleteImage() {
        guard let imageURL else { return }
        delete(imageURL: imageURL)
    }

    func delete(imageURL: URL) {
        ScreenshotHistoryStore.shared.remove(fileURL: imageURL)
        try? FileManager.default.trashItem(at: imageURL, resultingItemURL: nil)
        if self.imageURL == imageURL { hide() }
    }

    private func pinImage() {
        guard let imageURL else { return }
        pin(imageURL: imageURL)
    }

    func pin(imageURL: URL) {
        guard let image = NSImage(contentsOf: imageURL) else { return }
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let pinWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pinWindow.title = L("screenshot.quickAccess.pin")
        pinWindow.isFloatingPanel = true
        pinWindow.level = .floating
        pinWindow.hidesOnDeactivate = false
        pinWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pinWindow.contentView = imageView
        pinWindow.center()
        pinWindow.makeKeyAndOrderFront(nil)
        self.pinWindow = pinWindow
    }
}

private struct ScreenshotQuickAccessView: View {
    let imageURL: URL
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSaveOrReveal: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 148, height: 120)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("screenshot.quickAccess.title"))
                        .font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Text(imageURL.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    actionButton("doc.on.clipboard", L("screenshot.quickAccess.copy"), action: onCopy)
                    actionButton("pencil", L("screenshot.quickAccess.edit"), action: onEdit)
                    actionButton("arrow.down.to.line", L("screenshot.quickAccess.save"), action: onSaveOrReveal)
                    actionButton("folder", L("screenshot.quickAccess.reveal"), action: onReveal)
                    actionButton("pin", L("screenshot.quickAccess.pin"), action: onPin)
                    actionButton("trash", L("screenshot.quickAccess.delete"), action: onDelete)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        }
        .padding(4)
    }

    private func actionButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }
}
