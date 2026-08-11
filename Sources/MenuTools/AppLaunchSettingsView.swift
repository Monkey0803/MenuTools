import AppKit
import SwiftUI

/// 应用启动快捷键设置：选择应用并为它绑定一个全局快捷键。
struct AppLaunchSettingsView: View {
    @Bindable private var shortcutService: AppShortcutService
    @Bindable private var launcher: AppLauncherService

    @State private var searchText = ""
    @State private var selectedAppPath: String?
    @State private var frontmostApp: LaunchableApp?
    @State private var isShowingAppPicker = false
    @State private var appToBind: LaunchableApp?

    init(
        shortcutService: AppShortcutService = .shared,
        launcher: AppLauncherService = .shared
    ) {
        self.shortcutService = shortcutService
        self.launcher = launcher
    }

    private var activationNotifications: NotificationCenter.Publisher {
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
    }

    private var discoveredApps: [LaunchableApp] {
        var apps = launcher.apps
        if let frontmostApp, !apps.contains(where: { $0.path == frontmostApp.path }) {
            apps.append(frontmostApp)
        }
        for path in shortcutService.bindings.keys {
            if let app = launcher.application(atPath: path), !apps.contains(where: { $0.path == app.path }) {
                apps.append(app)
            }
        }
        return Array(Set(apps)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var boundApps: [LaunchableApp] {
        let boundPaths = Set(shortcutService.bindings.keys)
        return AppLauncherCatalog.visibleApps(
            discoveredApps.filter { boundPaths.contains($0.path) },
            query: searchText,
            favoritePaths: launcher.favoritePaths,
            recentPaths: launcher.recentPaths,
            limit: 500
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if !shortcutService.isAccessibilityTrusted {
                    Label(L("shortcut.permission"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                frontmostSection
                appListSection
            }
            .padding(16)
        }
        .scrollIndicators(.automatic)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .task {
            launcher.refresh()
            shortcutService.start()
            refreshFrontmostApp()
        }
        .onReceive(activationNotifications) { _ in
            refreshFrontmostApp()
        }
        .sheet(isPresented: $isShowingAppPicker) {
            AppSelectionSheet(apps: discoveredApps) { app in
                isShowingAppPicker = false
                presentBindingSheet(for: app)
            }
        }
        .sheet(item: $appToBind) { app in
            AppBindingSheet(app: app, shortcutService: shortcutService)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L("appShortcut.title"), systemImage: "app.badge")
                .font(.headline)
            Text(L("appShortcut.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var frontmostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("appShortcut.frontmost"), systemImage: "macwindow.on.rectangle")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    refreshFrontmostApp()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focusEffectDisabled()
                .accessibilityLabel(L("appShortcut.refresh"))
            }

            if let frontmostApp {
                HStack(spacing: 10) {
                    appIcon(frontmostApp, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(frontmostApp.name)
                            .font(.caption.weight(.semibold))
                        Text(frontmostApp.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        presentBindingSheet(for: frontmostApp)
                    } label: {
                        Label(
                            L("appShortcut.bindCurrent"),
                            systemImage: "keyboard"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Text(L("appShortcut.noFrontmost"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.blue.opacity(0.12)), in: .rect(cornerRadius: 14))
    }

    private var appListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("appShortcut.bound"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    isShowingAppPicker = true
                } label: {
                    Label(L("appShortcut.add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("appShortcut.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 9))

            if boundApps.isEmpty {
                Text(L("appShortcut.emptyBound"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(boundApps) { app in
                    appRow(app)
                }
            }
        }
    }

    private func appRow(_ app: LaunchableApp) -> some View {
        HStack(spacing: 8) {
            Button {
                presentBindingSheet(for: app)
            } label: {
                HStack(spacing: 9) {
                    appIcon(app, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text(shortcutService.binding(for: app)?.displayName ?? L("settings.unset"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(
                                shortcutService.binding(for: app) == nil
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(.tint)
                            )
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Button {
                presentBindingSheet(for: app)
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .focusEffectDisabled()
            .accessibilityLabel(L("shortcut.record"))

            if shortcutService.binding(for: app) != nil {
                Button {
                    shortcutService.clearBinding(for: app)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focusEffectDisabled()
                .accessibilityLabel(L("shortcut.clear"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            selectedAppPath == app.path
                ? AnyShapeStyle(.tint.opacity(0.12))
                : AnyShapeStyle(.quaternary.opacity(0.22)),
            in: .rect(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    selectedAppPath == app.path ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                    lineWidth: 1
                )
        }
    }

    private func appIcon(_ app: LaunchableApp, size: CGFloat) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
            .resizable()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.2))
    }

    private func presentBindingSheet(for app: LaunchableApp) {
        selectedAppPath = app.path
        DispatchQueue.main.async {
            appToBind = app
        }
    }

    private func refreshFrontmostApp() {
        frontmostApp = launcher.frontmostExternalApplication()
    }
}

private struct AppBindingSheet: View {
    let app: LaunchableApp
    @Bindable private var shortcutService: AppShortcutService

    @Environment(\.dismiss) private var dismiss
    @State private var isRecording = false
    @State private var capturedShortcut: GlobalShortcut?
    @State private var errorMessage: String?

    init(app: LaunchableApp, shortcutService: AppShortcutService) {
        self.app = app
        self.shortcutService = shortcutService
    }

    private var displayedShortcut: GlobalShortcut? {
        capturedShortcut ?? shortcutService.binding(for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 42, height: 42)
                    .clipShape(.rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.headline)
                    Text(app.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            HStack {
                Label(L("appShortcut.currentBinding"), systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(displayedShortcut?.displayName ?? L("settings.unset"))
                    .font(.caption.monospaced())
                    .foregroundStyle(displayedShortcut == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }

            Button {
                capturedShortcut = nil
                errorMessage = nil
                isRecording.toggle()
            } label: {
                Label(
                    isRecording ? L("settings.recording") : L("shortcut.record"),
                    systemImage: isRecording ? "xmark" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            AppShortcutCaptureView(isRecording: isRecording) { shortcut in
                isRecording = false
                guard let shortcut else { return }
                capturedShortcut = shortcut
                errorMessage = nil
            }
            .frame(width: 1, height: 1)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L("update.cancel")) {
                    dismiss()
                }
                Button(L("appShortcut.save")) {
                    saveBinding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(capturedShortcut == nil)
            }
        }
        .padding(18)
        .frame(width: 390, height: 285)
    }

    private func saveBinding() {
        guard let capturedShortcut else { return }
        do {
            try shortcutService.setBinding(capturedShortcut, for: app)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AppSelectionSheet: View {
    let apps: [LaunchableApp]
    let onSelect: (LaunchableApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredApps: [LaunchableApp] {
        AppLauncherCatalog.visibleApps(
            apps,
            query: searchText,
            favoritePaths: [],
            recentPaths: [],
            limit: 500
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("appShortcut.addTitle"))
                        .font(.headline)
                    Text(L("appShortcut.select"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("update.cancel")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("appShortcut.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 9))

            if filteredApps.isEmpty {
                Text(L("appShortcut.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredApps) { app in
                            Button {
                                onSelect(app)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                        .clipShape(.rect(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.name)
                                            .font(.caption)
                                        Text(app.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(.rect(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 9))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 500)
    }
}

private struct AppShortcutCaptureView: NSViewRepresentable {
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
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, nsView.isRecording else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((GlobalShortcut?) -> Void)?
        var isRecording = false {
            didSet { updateLocalMonitor() }
        }
        private var localMonitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            capture(event)
        }

        private func capture(_ event: NSEvent) {
            if event.keyCode == 53 {
                onCapture?(nil)
                return
            }
            onCapture?(GlobalShortcut(
                keyCode: event.keyCode,
                modifiers: GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            ))
        }

        private func updateLocalMonitor() {
            if isRecording, localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.isRecording else { return event }
                    self.capture(event)
                    return nil
                }
            } else if !isRecording, let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
