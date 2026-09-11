import AppKit
import ApplicationServices
import Foundation
import Observation

/// 独立的区域 OCR 流程：冻结显示器帧、手动选区、Vision 识别并复制纯文本。
/// 它不产生图片文件，符合 Snapzy Capture Text 的行为。
@MainActor
@Observable
final class ScreenshotRegionOCRService {
    static let shared = ScreenshotRegionOCRService()

    private let defaults: UserDefaults
    private let regionSelector: any ScreenshotRegionSelecting
    private let imageCapturer: any ScreenshotImageCapturing
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isRunning = false
    private(set) var isRecognizing = false
    private(set) var lastError: String?

    init(
        defaults: UserDefaults = .standard,
        regionSelector: any ScreenshotRegionSelecting = ScreenshotRegionSelector.shared,
        imageCapturer: any ScreenshotImageCapturing = DefaultScreenshotImageCapturer()
    ) {
        self.defaults = defaults
        self.regionSelector = regionSelector
        self.imageCapturer = imageCapturer
    }

    var binding: GlobalShortcut? {
        get {
            guard let data = defaults.data(forKey: SettingsKey.screenshotOCRShortcut) else { return nil }
            return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: SettingsKey.screenshotOCRShortcut)
            } else {
                defaults.removeObject(forKey: SettingsKey.screenshotOCRShortcut)
            }
        }
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers)
            }
            return event
        }
        isRunning = globalMonitor != nil || localMonitor != nil
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isRunning = false
    }

    func recognizeSelectedRegion() async throws -> String {
        guard !isRecognizing else { throw ScreenshotError.alreadyCapturing }
        isRecognizing = true
        lastError = nil
        defer { isRecognizing = false }

        var snapshots: [(displayFrame: CGRect, image: CGImage)] = []
        for screen in NSScreen.screens {
            if let image = try? await imageCapturer.captureDisplay(screen.screenshotDisplayID) {
                snapshots.append((screen.frame, image))
            }
        }
        let region = try await regionSelector.select()
        guard let image = ScreenshotDisplayImageCropper.cropComposite(snapshots, selection: region) else {
            throw ScreenshotError.imageUnavailable
        }
        do {
            let text = try await ScreenshotOCRService.recognizeExclusively(image)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw ScreenshotError.clipboardFailed
            }
            ClipboardHistoryService.shared.refresh()
            return text
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func handle(keyCode: UInt16, modifiers: UInt) {
        guard let binding,
              binding.keyCode == keyCode,
              binding.modifiers == modifiers,
              !isRecognizing else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await recognizeSelectedRegion() }
            catch { lastError = error.localizedDescription }
        }
    }
}
