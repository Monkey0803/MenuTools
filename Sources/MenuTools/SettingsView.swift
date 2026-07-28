import SwiftUI

/// 独立设置窗口（⌘, / 面板齿轮按钮打开）
struct SettingsView: View {
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue
    @AppStorage(SettingsKey.preferredTerminal) private var preferredTerminal = TerminalApp.systemDefault.rawValue
    @AppStorage(SettingsKey.autoCheckUpdate) private var autoCheckUpdate = true

    @State private var isCheckingUpdate = false
    @State private var checkResult: String?
    @State private var availableUpdate: UpdateInfo?

    var body: some View {
        Form {
            Section("菜单栏图标") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        iconOption(icon)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("终端 App") {
                Picker("在终端打开 Finder 路径时使用", selection: $preferredTerminal) {
                    ForEach(TerminalApp.installed) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
            }

            Section("软件更新") {
                Toggle(isOn: $autoCheckUpdate) {
                    Text("自动检查更新")
                    Text("打开面板时静默检查，每 24 小时最多一次")
                }

                LabeledContent("当前版本", value: "v\(UpdateCheckerService.currentVersion)")

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
                            Button("下载 v\(update.version)") {
                                UpdateCheckerService.openDownloadPage(update)
                            }
                        } else {
                            Button("立即检查") {
                                checkForUpdate()
                            }
                        }
                    }
                } label: {
                    Text("手动检查")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("MenuTools 设置")
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
                    checkResult = "发现新版本 v\(update.version)"
                } else {
                    checkResult = "已是最新版本"
                }
            } catch {
                isCheckingUpdate = false
                checkResult = "检查失败：\(error.localizedDescription)"
            }
        }
    }
}
