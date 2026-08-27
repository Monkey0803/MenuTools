import SwiftUI

/// 管理内置功能模块。关闭模块会同步停止其后台监听和快捷键。
struct PluginCenterView: View {
    @Bindable var manager: BuiltInPluginManager
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("plugin.center.title"))
                        .font(.headline)
                    Text(L("plugin.center.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                HStack {
                    Button(L("plugin.enableAll"), action: enableAll)
                    Button(L("plugin.disableAll"), action: disableAll)
                    Spacer()
                    Text(L("plugin.enabledCount", manager.enabledPluginIDs.count, manager.manifests.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(BuiltInPluginCategory.allCases, id: \.self) { category in
                let manifests = manager.manifests.filter { $0.category == category }
                if !manifests.isEmpty {
                    Section(L("plugin.category.\(category.rawValue)")) {
                        ForEach(manifests) { manifest in
                            pluginRow(manifest)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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

    private func pluginRow(_ manifest: BuiltInPluginManifest) -> some View {
        Toggle(isOn: Binding(
            get: { manager.isEnabled(manifest.id) },
            set: { setEnabled($0, for: manifest.id) }
        )) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: manifest.symbol)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(L(manifest.titleKey))
                            .font(.body.weight(.medium))
                        runtimeBadge(manager.runtimeState(for: manifest.id))
                    }
                    Text(L(manifest.descriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !manifest.requiredPermissions.isEmpty {
                        Text(permissionDescription(manifest.requiredPermissions))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func runtimeBadge(_ state: BuiltInPluginRuntimeState) -> some View {
        switch state {
        case .running:
            Text(L("plugin.state.running"))
                .foregroundStyle(.green)
                .pluginStateBadge()
        case .failed:
            Text(L("plugin.state.failed"))
                .foregroundStyle(.orange)
                .pluginStateBadge()
        case .stopped:
            EmptyView()
        }
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
