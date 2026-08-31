import AppKit
import SwiftUI

struct AppVolumeCard: View {
    @Bindable var service: AppVolumeService
    let openDetails: () -> Void

    private var visibleSessions: [AppAudioSession] {
        Array(service.sessions.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("volume.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L("volume.enabled"))
                Button(action: openDetails) {
                    HStack(spacing: 3) {
                        Text(L("volume.showAll"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("volume.showAll"))
            }

            SystemOutputVolumeRow(service: service, compact: true)

            if visibleSessions.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(L("volume.empty"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            } else {
                ForEach(visibleSessions) { session in
                    AppVolumeRow(service: service, session: session, compact: true)
                }
            }

            if service.sessions.count > visibleSessions.count {
                Button(action: openDetails) {
                    HStack {
                        Text(L("volume.more", service.sessions.count - visibleSessions.count))
                        Spacer()
                        Image(systemName: "ellipsis.circle")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .cyan)
    }
}

enum AppVolumeQuickAccessLayout {
    static func displayedSessions(from sessions: [AppAudioSession]) -> [AppAudioSession] {
        sessions
    }
}

enum AppVolumeRowInteractionPolicy {
    static func canAdjust(isEnabled: Bool) -> Bool {
        isEnabled
    }
}

enum AppVolumeIconPolicy {
    static func symbolName(volume: Double, isMuted: Bool) -> String {
        guard !isMuted, volume.isFinite, volume > 0 else {
            return "speaker.slash.fill"
        }
        if volume < 1.0 / 3.0 {
            return "speaker.wave.1.fill"
        }
        if volume < 2.0 / 3.0 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }
}

/// 可由全局快捷键直接唤起的紧凑音量管理面板。
struct AppVolumeQuickAccessView: View {
    @State private var service = AppVolumeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("volume.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L("volume.enabled"))
            }

            SystemOutputVolumeRow(service: service, compact: true)

            Divider()

            if service.sessions.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(L("volume.empty"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 3)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(AppVolumeQuickAccessLayout.displayedSessions(from: service.sessions)) { session in
                            AppVolumeRow(service: service, session: session, compact: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
            }

            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 300, height: 360, alignment: .top)
    }
}

struct AppVolumeSettingsView: View {
    @State private var service = AppVolumeService.shared
    @State private var shortcutService = AppVolumeShortcutService.shared
    @State private var isRecordingShortcut = false
    @State private var capturedShortcut: GlobalShortcut?
    @State private var shortcutError: String?

    private var activeSessions: [AppAudioSession] {
        service.sessions.filter(\.isRunningOutput)
    }

    private var rememberedSessions: [AppAudioSession] {
        service.sessions.filter { !$0.isRunningOutput }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { service.isEnabled },
                    set: { service.setEnabled($0) }
                )) {
                    Text(L("volume.enabled"))
                    Text(L("volume.enabled.desc"))
                }

                if service.permissionState == .denied {
                    LabeledContent(L("volume.permission.status")) {
                        HStack(spacing: 8) {
                            Text(L("volume.permission.denied"))
                                .foregroundStyle(.orange)
                            Button(L("volume.openSettings"), action: openSystemSettings)
                        }
                    }
                } else if service.permissionState == .notRequested {
                    LabeledContent(
                        L("volume.permission.status"),
                        value: L("volume.permission.pending")
                    )
                } else {
                    LabeledContent(L("volume.permission.status")) {
                        Label(L("volume.permission.authorized"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Button(L("volume.resetAll"), role: .destructive) {
                    service.resetAllProfiles()
                }
                .disabled(!service.hasProfiles)

                if !shortcutService.isAccessibilityTrusted {
                    LabeledContent(L("volume.shortcut")) {
                        HStack(spacing: 8) {
                            Label(L("shortcut.permission"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button(L("shortcut.openPermission"), action: openAccessibilitySettings)
                        }
                    }
                }

                volumeShortcutControl
            } header: {
                Label(L("volume.section.control"), systemImage: "waveform.badge.magnifyingglass")
            }

            Section {
                SystemOutputVolumeRow(service: service, compact: false)
            } header: {
                Label(L("volume.section.output"), systemImage: "speaker.wave.2")
            }

            Section {
                if activeSessions.isEmpty {
                    Text(L("volume.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeSessions) { session in
                        AppVolumeRow(service: service, session: session, compact: false)
                    }
                }
            } header: {
                Label(L("volume.section.active"), systemImage: "waveform")
            }

            if !rememberedSessions.isEmpty {
                Section {
                    ForEach(rememberedSessions) { session in
                        AppVolumeRow(service: service, session: session, compact: false)
                    }
                } header: {
                    Label(L("volume.section.remembered"), systemImage: "clock.arrow.circlepath")
                }
            }

            if let errorMessage = service.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            shortcutService.refreshAccessibilityTrust()
        }
        .overlay {
            GlobalShortcutCaptureView(isRecording: isRecordingShortcut) { shortcut in
                isRecordingShortcut = false
                guard let shortcut else { return }
                capturedShortcut = shortcut
                shortcutError = nil
            }
            .frame(width: 1, height: 1)
        }
    }

    private var volumeShortcutControl: some View {
        LabeledContent(L("volume.shortcut")) {
            HStack(spacing: 8) {
                Text(
                    isRecordingShortcut
                        ? L("settings.recording")
                        : capturedShortcut?.displayName ?? shortcutService.binding?.displayName ?? L("settings.unset")
                )
                .font(.callout.monospaced())
                .foregroundStyle(isRecordingShortcut || capturedShortcut != nil || shortcutService.binding != nil ? .primary : .secondary)

                if capturedShortcut != nil {
                    Button(L("volume.shortcutSave"), action: saveShortcut)
                }

                Button {
                    capturedShortcut = nil
                    shortcutError = nil
                    isRecordingShortcut.toggle()
                } label: {
                    Image(systemName: isRecordingShortcut ? "xmark" : "record.circle")
                }
                .help(isRecordingShortcut ? L("settings.recording") : L("shortcut.record"))

                if shortcutService.binding != nil, !isRecordingShortcut {
                    Button {
                        shortcutService.clearBinding()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L("shortcut.clear"))
                }
            }
        }
        .help(L("volume.shortcutDescription"))
        .overlay(alignment: .bottomLeading) {
            if let shortcutError {
                Text(shortcutError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .offset(y: 16)
            }
        }
        .padding(.bottom, shortcutError == nil ? 0 : 14)
    }

    private func saveShortcut() {
        guard let capturedShortcut else { return }
        do {
            try shortcutService.setBinding(capturedShortcut)
            self.capturedShortcut = nil
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SystemOutputVolumeRow: View {
    @Bindable var service: AppVolumeService
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            Button {
                service.setMasterMuted(!service.output.isMuted)
            } label: {
                Image(systemName: AppVolumeIconPolicy.symbolName(
                    volume: service.output.volume,
                    isMuted: service.output.isMuted
                ))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: compact ? 18 : 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(service.output.isMuted ? Color.orange : Color.accentColor)
            .disabled(!service.output.canSetMute)
            .accessibilityLabel(L("volume.mute"))

            VStack(alignment: .leading, spacing: 3) {
                Text(service.output.deviceName.isEmpty ? L("volume.output.unknown") : service.output.deviceName)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(compact ? .secondary : .primary)
                    .lineLimit(1)
                Slider(value: Binding(
                    get: { service.output.volume },
                    set: { service.setMasterVolume($0) }
                ), in: 0...1)
                .disabled(!service.output.canSetVolume)
                .accessibilityLabel(L("volume.master"))
                if !compact && !service.output.canSetVolume {
                    Text(L("volume.output.fixed"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("\(Int((service.output.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct AppVolumeRow: View {
    @Bindable var service: AppVolumeService
    let session: AppAudioSession
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            appIcon
                .frame(width: compact ? 18 : 26, height: compact ? 18 : 26)

            if compact {
                compactControls
            } else {
                HStack(spacing: 5) {
                    Text(session.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    if session.isRunningOutput {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel(L("volume.active"))
                    }
                    if session.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 180, alignment: .leading)

                Slider(value: Binding(
                    get: { service.session(id: session.rootBundleID)?.volume ?? session.volume },
                    set: { service.setVolume($0, for: session.rootBundleID) }
                ), in: 0...1)
                .disabled(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: service.isEnabled))
                .accessibilityLabel(L("volume.app", session.displayName))
            }

            Button {
                service.toggleMute(for: session.rootBundleID)
            } label: {
                Image(systemName: AppVolumeIconPolicy.symbolName(
                    volume: session.volume,
                    isMuted: session.volume == 0
                ))
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.volume == 0 ? .orange : .secondary)
            .disabled(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: service.isEnabled))
            .accessibilityLabel(L("volume.muteApp", session.displayName))

            Text("\(Int((session.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            if !compact {
                Button {
                    service.resetProfile(for: session.rootBundleID)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("volume.resetApp", session.displayName))
            }
        }
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(session.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                if session.isRunningOutput {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel(L("volume.active"))
                }
                if session.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Slider(value: Binding(
                get: { service.session(id: session.rootBundleID)?.volume ?? session.volume },
                set: { service.setVolume($0, for: session.rootBundleID) }
            ), in: 0...1)
            .disabled(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: service.isEnabled))
            .accessibilityLabel(L("volume.app", session.displayName))
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let bundleURL = session.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: session.rootBundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundleURL.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}
