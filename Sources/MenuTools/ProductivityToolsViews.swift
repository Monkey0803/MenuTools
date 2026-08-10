import AppKit
import SwiftUI

/// App 快速启动器卡片。
struct AppLauncherCard: View {
    @Bindable var service: AppLauncherService
    let report: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoHeader
            TextField(L("launcher.search"), text: $service.query)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if service.visibleApps.isEmpty {
                Text(L("launcher.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(service.visibleApps.prefix(6)) { app in
                    appRow(app)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.14)), in: .rect(cornerRadius: 16))
        .task { service.refresh() }
    }

    private var infoHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.grid.2x2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(L("launcher.title"))
                .font(.caption.weight(.semibold))
            Spacer()
            Text(L("launcher.subtitle"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func appRow(_ app: LaunchableApp) -> some View {
        HStack(spacing: 8) {
            Button {
                if !service.launch(app) {
                    report(L("launcher.launchFailed", app.name), true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(app.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Button {
                service.toggleFavorite(app)
            } label: {
                Image(systemName: service.favoritePaths.contains(app.path) ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(service.favoritePaths.contains(app.path) ? .yellow : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("launcher.favorite"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 9))
    }
}

/// 配置场景卡片。
struct ScenePresetsCard: View {
    let activeScene: ScenePreset?
    let apply: (ScenePreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("scene.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if let activeScene {
                    Text(L(activeScene.titleKey))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }

            HStack(spacing: 8) {
                ForEach(ScenePreset.allCases) { scene in
                    Button { apply(scene) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: scene.symbol)
                                .font(.body.weight(.semibold))
                            Text(L(scene.titleKey))
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(activeScene == scene ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .glassEffect(
                        activeScene == scene ? .regular.tint(.blue.opacity(0.25)).interactive() : .regular.interactive(),
                        in: .rect(cornerRadius: 10)
                    )
                    .accessibilityLabel(L(scene.titleKey))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.blue.opacity(0.14)), in: .rect(cornerRadius: 16))
    }
}

/// 场景全局快捷键配置卡片。
struct GlobalShortcutCard: View {
    @Bindable var service: GlobalShortcutService
    let report: (String, Bool) -> Void
    @State private var recordingScene: ScenePreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("shortcut.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(!service.isAccessibilityTrusted ? L("shortcut.permission") : (service.isRunning ? L("shortcut.active") : L("shortcut.inactive")))
                    .font(.caption2)
                    .foregroundStyle(!service.isAccessibilityTrusted ? .orange : (service.isRunning ? .green : .secondary))
                if !service.isAccessibilityTrusted {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L("shortcut.openPermission"))
                }
            }

            ForEach(ScenePreset.allCases) { scene in
                HStack(spacing: 8) {
                    Image(systemName: scene.symbol)
                        .font(.caption)
                        .frame(width: 18)
                    Text(L(scene.titleKey))
                        .font(.caption)
                    Spacer()
                    Text(recordingScene == scene ? L("shortcut.recording") : (service.binding(for: scene)?.displayName ?? L("settings.unset")))
                        .font(.caption2.monospaced())
                        .foregroundStyle(
                            recordingScene == scene
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.secondary)
                        )
                    Button {
                        recordingScene = recordingScene == scene ? nil : scene
                    } label: {
                        Image(systemName: recordingScene == scene ? "xmark" : "record.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(L("shortcut.record"))
                    if service.binding(for: scene) != nil {
                        Button {
                            service.clearBinding(for: scene)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("shortcut.clear"))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 9))
            }

            ShortcutCaptureView(isRecording: recordingScene != nil) { shortcut in
                guard let scene = recordingScene else { return }
                recordingScene = nil
                guard let shortcut else { return }
                do {
                    try service.setBinding(shortcut, for: scene)
                } catch {
                    report(error.localizedDescription, true)
                }
            }
            .frame(width: 1, height: 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.pink.opacity(0.14)), in: .rect(cornerRadius: 16))
        .task { service.start() }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        nsView.isRecording = isRecording
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((GlobalShortcut?) -> Void)?
        var isRecording = false

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {
                onCapture?(nil)
                return
            }
            onCapture?(GlobalShortcut(
                keyCode: event.keyCode,
                modifiers: GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            ))
        }
    }
}

/// 专注模式卡片。
struct FocusModeCard: View {
    let isEnabled: Bool?
    let isDoNotDisturbEnabled: Bool?
    let isBusy: Bool
    let toggle: () -> Void
    let toggleDoNotDisturb: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isEnabled == true ? "moon.fill" : "moon")
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled == true ? .indigo : .secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("focus.title"))
                    .font(.caption.weight(.semibold))
                Text(isEnabled.map { $0 ? L("focus.enabled") : L("focus.disabled") } ?? L("focus.unknown"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                toggle()
            } label: {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(L("focus.toggle"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBusy)
            Button {
                toggleDoNotDisturb()
            } label: {
                Image(systemName: isDoNotDisturbEnabled == true ? "bell.slash.fill" : "bell.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDoNotDisturbEnabled == true ? .orange : .secondary)
            .disabled(isBusy)
            .help(L("focus.doNotDisturb"))
            .accessibilityLabel(L("focus.doNotDisturb"))
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("focus.openSettings"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.indigo.opacity(0.14)), in: .rect(cornerRadius: 16))
    }
}
