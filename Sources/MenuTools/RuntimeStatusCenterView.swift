import SwiftUI

/// 权限与运行状态中心：同页呈现系统授权、插件运行状态和可执行的设置入口。
struct RuntimeStatusCenterView: View {
    @Bindable var manager: BuiltInPluginManager
    let openFeatureSettings: (SettingsTab) -> Void

    @State private var permissionMonitor = RuntimePermissionMonitor.shared

    private var pluginReadiness: [(manifest: BuiltInPluginManifest, readiness: PluginReadiness)] {
        manager.manifests.map { manifest in
            (
                manifest,
                RuntimeStatusCenter.readiness(
                    for: manifest,
                    isEnabled: manager.isEnabled(manifest.id),
                    runtimeState: manager.runtimeState(for: manifest.id),
                    permissions: permissionMonitor.states
                )
            )
        }
    }

    private var summary: RuntimeStatusSummary {
        RuntimeStatusCenter.summary(for: pluginReadiness.map(\.readiness))
    }

    private var usedPermissions: [BuiltInPluginPermission] {
        Set(manager.manifests.flatMap(\.requiredPermissions))
            .sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryCard
                permissionsSection
                pluginsSection
            }
            .padding(SettingsScrollLayout.contentInsets())
        }
        .task { permissionMonitor.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("runtime.title"))
                    .font(.title3.weight(.semibold))
                Text(L("runtime.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                permissionMonitor.refresh()
            } label: {
                Label(L("runtime.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(permissionMonitor.isRefreshing)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryValue(summary.running, key: "runtime.summary.running", color: .green)
            Divider().frame(height: 32)
            summaryValue(summary.attention, key: "runtime.summary.attention", color: .orange)
            Divider().frame(height: 32)
            summaryValue(summary.disabled, key: "runtime.summary.disabled", color: .secondary)
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1)
        }
    }

    private func summaryValue(_ value: Int, key: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            Text(L(key))
                .font(.caption2)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("runtime.section.permissions"))
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(usedPermissions.enumerated()), id: \.element) { index, permission in
                    permissionRow(permission)
                    if index < usedPermissions.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1)
            }
        }
    }

    private func permissionRow(_ permission: BuiltInPluginPermission) -> some View {
        let status = permissionMonitor.states[permission, default: .notDetermined]
        return HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .foregroundStyle(permissionColor(status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("plugin.permission.\(permission.rawValue)"))
                Text(L(status.titleKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let url = RuntimePermissionSettingsLink.url(for: permission) {
                Button(L("runtime.openSettings")) {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("runtime.section.plugins"))
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(pluginReadiness.enumerated()), id: \.element.manifest.id) { index, item in
                    pluginRow(item.manifest, readiness: item.readiness)
                    if index < pluginReadiness.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1)
            }
        }
    }

    private func pluginRow(
        _ manifest: BuiltInPluginManifest,
        readiness: PluginReadiness
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: readiness.symbolName)
                .foregroundStyle(readinessColor(readiness))
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(manifest.titleKey))
                    .font(.callout.weight(.medium))
                Text(readinessDescription(readiness))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let tab = SettingsTab.allCases.first(where: { $0.pluginID == manifest.id }) {
                Button(L("runtime.openFeature")) {
                    openFeatureSettings(tab)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func readinessDescription(_ readiness: PluginReadiness) -> String {
        switch readiness {
        case .failed(let message): return L("runtime.plugin.failedDetail", message)
        case .requiresPermissions(let permissions):
            let names = permissions.map { L("plugin.permission.\($0.rawValue)") }
                .joined(separator: L("plugin.permission.separator"))
            return L("runtime.plugin.permissionsDetail", names)
        case .disabled, .running, .stopped: return L(readiness.titleKey)
        }
    }

    private func permissionColor(_ status: RuntimePermissionStatus) -> Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined, .requiresVerification: .orange
        }
    }

    private func readinessColor(_ readiness: PluginReadiness) -> Color {
        switch readiness {
        case .running: .green
        case .disabled, .stopped: .secondary
        case .failed: .red
        case .requiresPermissions: .orange
        }
    }
}
