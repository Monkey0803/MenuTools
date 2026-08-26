import AppKit
import SwiftUI

/// 截图设置与手动截图入口。
struct ScreenshotSettingsView: View {
    @AppStorage(SettingsKey.screenshotMode) private var modeRawValue = ScreenshotCaptureMode.fullScreen.rawValue
    @AppStorage(SettingsKey.screenshotCopy) private var copyToClipboard = true
    @AppStorage(SettingsKey.screenshotEdit) private var openEditorAfterCapture = false
    @AppStorage(SettingsKey.screenshotLongSelectRegion) private var longSelectRegion = true
    @AppStorage(SettingsKey.screenshotSaveToDisk) private var saveToDisk = true
    @AppStorage(SettingsKey.screenshotDirectory) private var directoryPath = ""
    @AppStorage(SettingsKey.screenshotFormat) private var formatRawValue = ScreenshotOutputFormat.png.rawValue
    @AppStorage(SettingsKey.screenshotNamingTemplate) private var namingTemplate = "MenuTools_{datetime}_{mode}"

    @State private var screenshotService = ScreenshotService.shared
    @State private var shortcutService = ScreenshotShortcutService.shared
    @State private var historyStore = ScreenshotHistoryStore.shared
    @State private var ocrService = ScreenshotRegionOCRService.shared
    @State private var recordingMode: ScreenshotCaptureMode?
    @State private var isRecordingOCRShortcut = false
    @State private var statusMessage: String?
    @State private var isStatusError = false

    private var selectedMode: ScreenshotCaptureMode {
        get { ScreenshotCaptureMode(rawValue: modeRawValue) ?? .fullScreen }
        set { modeRawValue = newValue.rawValue }
    }

    var body: some View {
        Form {
            Section(L("screenshot.section.capture")) {
                Picker(L("screenshot.mode"), selection: $modeRawValue) {
                    ForEach(ScreenshotCaptureMode.allCases) { mode in
                        Label(L(mode.titleKey), systemImage: mode.symbol)
                            .tag(mode.rawValue)
                    }
                }

                Toggle(L("screenshot.copy"), isOn: $copyToClipboard)
                Toggle(L("screenshot.edit"), isOn: $openEditorAfterCapture)
                if selectedMode == .long {
                    Toggle(L("screenshot.long.selectRegion"), isOn: $longSelectRegion)
                }

                HStack(spacing: 8) {
                    Button {
                        capture(mode: selectedMode, editAfterCapture: false)
                    } label: {
                        Label(L("screenshot.capture"), systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(screenshotService.isCapturing)

                    Button {
                        capture(mode: selectedMode, editAfterCapture: true)
                    } label: {
                        Label(L("screenshot.captureAndEdit"), systemImage: "pencil.and.outline")
                    }
                    .disabled(screenshotService.isCapturing)
                }

                Button {
                    captureSelectedWindow()
                } label: {
                    Label(L("screenshot.windowSelection.capture"), systemImage: "macwindow.on.rectangle")
                }
                .disabled(screenshotService.isCapturing)

                Button {
                    captureLastSelectedRegion(editAfterCapture: false)
                } label: {
                    Label(L("screenshot.repeat"), systemImage: "arrow.counterclockwise")
                }
                .disabled(screenshotService.isCapturing || !screenshotService.hasSavedRegion)

                Button {
                    recognizeRegion()
                } label: {
                    Label(L("screenshot.ocr.region"), systemImage: "text.viewfinder")
                }
                .disabled(screenshotService.isCapturing || ocrService.isRecognizing)
            }

            Section(L("screenshot.section.output")) {
                Toggle(L("screenshot.saveToDisk"), isOn: $saveToDisk)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("screenshot.directory"))
                        Text(outputDirectoryURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(L("screenshot.chooseDirectory")) {
                        chooseDirectory()
                    }
                }
                .disabled(!saveToDisk)

                Picker(L("screenshot.format"), selection: $formatRawValue) {
                    ForEach(ScreenshotOutputFormat.allCases) { format in
                        Text(L(format.titleKey)).tag(format.rawValue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("screenshot.namingTemplate"))
                    TextField("MenuTools_{datetime}_{mode}", text: $namingTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text(L("screenshot.namingTemplate.help"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("screenshot.section.shortcut")) {
                ForEach(ScreenshotCaptureMode.allCases) { mode in
                    HStack(spacing: 10) {
                        Image(systemName: mode.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(mode.titleKey))
                                .font(.callout.weight(.medium))
                            Text(L("screenshot.shortcut.desc.\(mode.rawValue)"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(shortcutService.binding(for: mode)?.displayName ?? L("settings.unset"))
                            .font(.caption.monospaced())
                            .foregroundStyle(
                                shortcutService.binding(for: mode) == nil
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(.tint)
                            )
                        Button {
                            recordingMode = recordingMode == mode ? nil : mode
                        } label: {
                            Image(systemName: recordingMode == mode ? "xmark" : "record.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("shortcut.record"))
                        .accessibilityLabel(L("shortcut.record"))
                        Button {
                            shortcutService.clearBinding(for: mode)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(shortcutService.binding(for: mode) == nil)
                        .help(L("shortcut.clear"))
                        .accessibilityLabel(L("shortcut.clear"))
                    }
                    .padding(.vertical, 5)
                }

                GlobalShortcutCaptureView(isRecording: recordingMode != nil) { shortcut in
                    guard let mode = recordingMode else { return }
                    recordingMode = nil
                    guard let shortcut else { return }
                    saveShortcut(shortcut, for: mode)
                }
                .frame(width: 1, height: 1)

                HStack(spacing: 10) {
                    Image(systemName: "text.viewfinder")
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("screenshot.ocr.region"))
                            .font(.callout.weight(.medium))
                        Text(L("screenshot.ocr.shortcut.desc"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ocrService.binding?.displayName ?? L("settings.unset"))
                        .font(.caption.monospaced())
                        .foregroundStyle(ocrService.binding == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    Button {
                        isRecordingOCRShortcut.toggle()
                    } label: {
                        Image(systemName: isRecordingOCRShortcut ? "xmark" : "record.circle")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        ocrService.binding = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(ocrService.binding == nil)
                }

                GlobalShortcutCaptureView(isRecording: isRecordingOCRShortcut) { shortcut in
                    isRecordingOCRShortcut = false
                    guard let shortcut else { return }
                    saveOCRShortcut(shortcut)
                }
                .frame(width: 1, height: 1)
            }

            Section {
                Label(L("screenshot.long.desc"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("screenshot.section.history")) {
                if historyStore.entries.isEmpty {
                    Text(L("screenshot.history.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historyStore.entries.prefix(8)) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.mode.symbol)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileURL.lastPathComponent)
                                    .lineLimit(1)
                                Text("\(entry.width) × \(entry.height) · \(entry.format.fileExtension)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                ScreenshotQuickAccessManager.shared.copy(imageURL: entry.fileURL)
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help(L("screenshot.quickAccess.copy"))
                            Button {
                                ScreenshotQuickAccessManager.shared.edit(imageURL: entry.fileURL)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help(L("screenshot.quickAccess.edit"))
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help(L("screenshot.quickAccess.reveal"))
                            Button {
                                ScreenshotQuickAccessManager.shared.delete(imageURL: entry.fileURL)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L("screenshot.history.remove"))
                        }
                    }
                    Button(L("screenshot.history.clear")) {
                        historyStore.clear()
                    }
                }
            }

            if screenshotService.isCapturing {
                ProgressView(L("screenshot.status.capturing"))
                if let phase = screenshotService.longCapturePhase {
                    Text(L(phase.titleKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if screenshotService.capturingMode == .long {
                    HStack(spacing: 8) {
                        Button(L("screenshot.long.finish")) {
                            screenshotService.requestStopLongCapture()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(L("screenshot.long.cancel")) {
                            screenshotService.cancelLongCapture()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isStatusError ? .red : .green)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .onChange(of: recordingMode) { _, mode in
            shortcutService.setRecordingShortcut(mode != nil)
        }
        .onChange(of: isRecordingOCRShortcut) { _, recording in
            shortcutService.setRecordingShortcut(recording)
        }
        .onDisappear {
            if screenshotService.capturingMode == .long {
                screenshotService.cancelLongCapture()
            }
            recordingMode = nil
            isRecordingOCRShortcut = false
            shortcutService.setRecordingShortcut(false)
        }
    }

    private func capture(mode: ScreenshotCaptureMode, editAfterCapture: Bool) {
        statusMessage = nil
        Task { @MainActor in
            do {
                _ = try await screenshotService.capture(
                    mode: mode,
                    copyToClipboard: copyToClipboard,
                    editAfterCapture: editAfterCapture || openEditorAfterCapture,
                    longSelectRegion: longSelectRegion
                )
                statusMessage = L("screenshot.success")
                isStatusError = false
            } catch {
                statusMessage = error.localizedDescription
                isStatusError = true
            }
        }
    }

    private func captureLastSelectedRegion(editAfterCapture: Bool) {
        statusMessage = nil
        Task { @MainActor in
            do {
                _ = try await screenshotService.captureLastSelectedRegion(
                    copyToClipboard: copyToClipboard,
                    editAfterCapture: editAfterCapture || openEditorAfterCapture
                )
                statusMessage = L("screenshot.success")
                isStatusError = false
            } catch {
                statusMessage = error.localizedDescription
                isStatusError = true
            }
        }
    }

    private func captureSelectedWindow() {
        statusMessage = nil
        Task { @MainActor in
            do {
                _ = try await screenshotService.captureSelectedWindow(
                    copyToClipboard: copyToClipboard,
                    editAfterCapture: openEditorAfterCapture
                )
                statusMessage = L("screenshot.success")
                isStatusError = false
            } catch {
                statusMessage = error.localizedDescription
                isStatusError = true
            }
        }
    }

    private func saveShortcut(_ shortcut: GlobalShortcut, for mode: ScreenshotCaptureMode) {
        do {
            try shortcutService.setBinding(shortcut, for: mode)
            statusMessage = L("screenshot.shortcutSaved")
            isStatusError = false
        } catch {
            statusMessage = error.localizedDescription
            isStatusError = true
        }
    }

    private var outputDirectoryURL: URL {
        ScreenshotOutputConfiguration.load().directoryURL
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryPath = url.path
    }

    private func recognizeRegion() {
        statusMessage = nil
        Task { @MainActor in
            do {
                _ = try await ocrService.recognizeSelectedRegion()
                statusMessage = L("screenshot.ocr.copied")
                isStatusError = false
            } catch {
                statusMessage = error.localizedDescription
                isStatusError = true
            }
        }
    }

    private func saveOCRShortcut(_ shortcut: GlobalShortcut) {
        guard shortcut.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            statusMessage = L("shortcut.error.modifierRequired")
            isStatusError = true
            return
        }
        ocrService.binding = shortcut
        statusMessage = L("screenshot.shortcutSaved")
        isStatusError = false
    }
}
