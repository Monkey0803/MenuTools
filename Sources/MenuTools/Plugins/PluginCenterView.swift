import SwiftUI

enum PluginCenterFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case attention

    var id: String { rawValue }

    var titleKey: String {
        "plugin.filter.\(rawValue)"
    }

    func includes(
        isEnabled: Bool,
        state: BuiltInPluginRuntimeState
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .enabled:
            return isEnabled
        case .attention:
            if case .failed = state {
                return true
            }
            return false
        }
    }
}

/// 管理内置功能模块。关闭模块会同步停止其后台监听和快捷键。
struct PluginCenterView: View {
    @Bindable var manager: BuiltInPluginManager
    let openSettings: (SettingsTab) -> Void

    @State private var filter: PluginCenterFilter = .all
    @State private var errorMessage: String?

    private var filteredManifests: [BuiltInPluginManifest] {
        manager.manifests.filter { manifest in
            filter.includes(
                isEnabled: manager.isEnabled(manifest.id),
                state: manager.runtimeState(for: manifest.id)
            )
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summary

                Picker(L("plugin.filter.label"), selection: $filter) {
                    ForEach(PluginCenterFilter.allCases) { option in
                        Text(L(option.titleKey))
                            .tag(option)
                            .accessibilityLabel(L(option.titleKey))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if filteredManifests.isEmpty {
                    emptyState
                } else {
                    pluginGroups
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .alert(
            L("plugin.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L("plugin.error.dismiss"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("plugin.center.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("plugin.enabledCount", manager.enabledPluginIDs.count, manager.manifests.count))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 12)

            Menu {
                Button(L("plugin.enableAll"), systemImage: "checkmark.circle", action: enableAll)
                Button(L("plugin.disableAll"), systemImage: "xmark.circle", action: disableAll)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help(L("plugin.actions"))
            .accessibilityLabel(L("plugin.actions"))
        }
        .padding(16)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var pluginGroups: some View {
        ForEach(BuiltInPluginCategory.allCases, id: \.self) { category in
            let manifests = filteredManifests.filter { $0.category == category }
            if !manifests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("plugin.category.\(category.rawValue)"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(manifests.enumerated()), id: \.element.id) { index, manifest in
                            pluginRow(manifest)
                            if index < manifests.count - 1 {
                                Divider()
                                    .padding(.leading, 55)
                            }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .attention ? "checkmark.circle" : "square.stack.3d.up.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L(filter == .attention ? "plugin.empty.attention" : "plugin.empty.filtered"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func pluginRow(_ manifest: BuiltInPluginManifest) -> some View {
        HStack(spacing: 12) {
            pluginRowContent(manifest)

            Toggle("", isOn: Binding(
                get: { manager.isEnabled(manifest.id) },
                set: { setEnabled($0, for: manifest.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(L(manifest.titleKey))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private func pluginRowContent(_ manifest: BuiltInPluginManifest) -> some View {
        if let destination = settingsTab(for: manifest), manager.isEnabled(manifest.id) {
            Button {
                openSettings(destination)
            } label: {
                pluginLabel(manifest, showsChevron: true)
            }
            .buttonStyle(.plain)
            .help(L("plugin.openSettings"))
            .accessibilityLabel(L(manifest.titleKey))
        } else {
            pluginLabel(manifest, showsChevron: false)
        }
    }

    private func pluginLabel(
        _ manifest: BuiltInPluginManifest,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: manifest.symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(L(manifest.titleKey))
                        .font(.body.weight(.medium))
                    runtimeBadge(manager.runtimeState(for: manifest.id))
                }

                Text(L(manifest.descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if case .failed = manager.runtimeState(for: manifest.id),
                   !manifest.requiredPermissions.isEmpty {
                    Text(permissionDescription(manifest.requiredPermissions))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func runtimeBadge(_ state: BuiltInPluginRuntimeState) -> some View {
        if case .failed = state {
            Text(L("plugin.state.failed"))
                .foregroundStyle(.orange)
                .pluginStateBadge()
        }
    }

    private func settingsTab(for manifest: BuiltInPluginManifest) -> SettingsTab? {
        SettingsTab.allCases.first { $0.pluginID == manifest.id }
    }

    private func permissionDescription(_ permissions: Set<BuiltInPluginPermission>) -> String {
        let names = permissions
            .sorted { $0.rawValue < $1.rawValue }
            .map { L("plugin.permission.\($0.rawValue)") }
            .joined(separator: L("plugin.permission.separator"))
        return L("plugin.permissions", names)
    }

    private func setEnabled(_ enabled: Bool, for id: BuiltInPluginID) {
        do {
            try manager.setEnabled(enabled, for: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enableAll() {
        for id in manager.orderedPluginIDs where !manager.isEnabled(id) {
            do {
                try manager.setEnabled(true, for: id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private func disableAll() {
        for id in manager.orderedPluginIDs.reversed() where manager.isEnabled(id) {
            do {
                try manager.setEnabled(false, for: id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }
}

private extension View {
    func pluginStateBadge() -> some View {
        font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
