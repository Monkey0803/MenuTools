import SwiftUI
import FinderSync

/// Finder 右键工具配置页（设置窗口的一个标签）
struct RightClickToolsView: View {
    @State private var config = RightClickConfigStore.load()
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                permissionSection
                group(.directory)
                group(.copy)
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
        .onReceive(refreshTimer) { _ in
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "contextualmenu.and.cursorarrow")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.teal, .blue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(L("rc.title"))
                    .font(.title3.weight(.semibold))
                Text(L("rc.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(icon: "lock.shield", title: L("rc.section.permission"))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L("rc.permission.title"))
                            .font(.body.weight(.medium))
                        statusBadge
                    }
                    Text(L("rc.permission.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L("rc.permission.openSettings")) {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                .controlSize(.small)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(extensionEnabled ? L("rc.permission.enabled") : L("rc.permission.disabled"))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(extensionEnabled ? .green : .orange)
    }

    // MARK: - 分组开关

    private func group(_ group: RightClickItem.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(icon: group == .directory ? "folder" : "doc.on.doc", title: L(group.titleKey))

            VStack(spacing: 0) {
                let items = RightClickItem.allCases.filter { $0.group == group }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    toggleRow(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private func toggleRow(_ item: RightClickItem) -> some View {
        Toggle(isOn: binding(for: item)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(item.titleKey))
                    .font(.body)
                if let subtitleKey = item.subtitleKey {
                    Text(L(subtitleKey))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 10)
    }

    private func binding(for item: RightClickItem) -> Binding<Bool> {
        Binding(
            get: { config.isEnabled(item) },
            set: { newValue in
                config.enabled[item.rawValue] = newValue
                RightClickConfigStore.save(config)
            }
        )
    }

    private func sectionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}
