import SwiftUI

/// 独立设置窗口（⌘, / 面板齿轮按钮打开）
struct SettingsView: View {
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue
    @AppStorage(SettingsKey.preferredTerminal) private var preferredTerminal = TerminalApp.systemDefault.rawValue
    @AppStorage(SettingsKey.autoCheckUpdate) private var autoCheckUpdate = true
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue

    @State private var isCheckingUpdate = false
    @State private var checkResult: String?
    @State private var availableUpdate: UpdateInfo?

    var body: some View {
        Form {
            Section(L("settings.section.icon")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        iconOption(icon)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(L("settings.section.language")) {
                Picker(L("settings.language.label"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            }

            Section(L("settings.section.terminal")) {
                Picker(L("settings.terminal.desc"), selection: $preferredTerminal) {
                    ForEach(TerminalApp.installed) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
            }

            Section(L("settings.section.update")) {
                Toggle(isOn: $autoCheckUpdate) {
                    Text(L("settings.autoCheck"))
                    Text(L("settings.autoCheck.desc"))
                }

                LabeledContent(L("settings.currentVersion"), value: "v\(UpdateCheckerService.currentVersion)")

                LabeledContent {
                    HStack(spacing: 10) {
                        if let result = checkResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(availableUpdate == nil ? .secondary : .primary)
                        }
                        if isCheckingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        } else if let update = availableUpdate {
                            Button(L("settings.download", update.version)) {
                                UpdateCheckerService.openDownloadPage(update)
                            }
                        } else {
                            Button(L("settings.checkNow")) {
                                checkForUpdate()
                            }
                        }
                    }
                } label: {
                    Text(L("settings.manualCheck"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L("settings.title"))
    }

    private func iconOption(_ icon: MenuBarIcon) -> some View {
        let isSelected = menuBarIcon == icon.rawValue
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                menuBarIcon = icon.rawValue
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon.rawValue)
                    .font(.body)
                    .symbolEffect(.bounce, value: isSelected)
                Text(icon.displayName)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: 1)
        )
    }

    private func checkForUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        checkResult = nil
        Task {
            do {
                let update = try await UpdateCheckerService.check()
                isCheckingUpdate = false
                if let update {
                    availableUpdate = update
                    checkResult = L("settings.found", update.version)
                } else {
                    checkResult = L("settings.latest")
                }
            } catch {
                isCheckingUpdate = false
                checkResult = L("settings.checkFailed", error.localizedDescription)
            }
        }
    }
}
