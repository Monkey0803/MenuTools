import AppKit
import SwiftUI

/// 主面板的应用启动器：搜索启动、收藏与最近使用。
///
/// 这三项能力此前在界面上完全不存在——`toggleFavorite` 在整个 Sources 里零调用，
/// 所以收藏集合永远是空的，连「工作模式打开收藏 App」也成了结构性空操作。
struct AppLauncherCard: View {
    @Bindable var service: AppLauncherService

    private var recentApps: [LaunchableApp] {
        AppLauncherPanelPolicy.recentPaths(
            service.recentPaths,
            exists: { FileManager.default.fileExists(atPath: $0) }
        ).compactMap { service.application(atPath: $0) }
    }

    private var showsRecents: Bool {
        AppLauncherPanelPolicy.showsRecents(query: service.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField

            if service.visibleApps.isEmpty {
                Text(L("appShortcut.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if showsRecents {
                if !service.favoriteApps.isEmpty {
                    sectionTitle(L("appLauncher.favorites"))
                    ForEach(service.favoriteApps) { app in
                        appRow(app)
                    }
                }
                if !recentApps.isEmpty {
                    sectionTitle(L("appLauncher.recent"))
                    ForEach(recentApps) { app in
                        appRow(app)
                    }
                }
                if service.favoriteApps.isEmpty && recentApps.isEmpty {
                    // 还没有收藏与最近记录时，先给出前几个应用，避免面板空空如也。
                    ForEach(Array(service.visibleApps.prefix(6))) { app in
                        appRow(app)
                    }
                }
            } else {
                ForEach(Array(service.visibleApps.prefix(6))) { app in
                    appRow(app)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "app.badge")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(L("plugin.app-launcher.title"))
                .font(.caption.weight(.semibold))
            Spacer()
            if !service.favoriteApps.isEmpty {
                Text("\(service.favoriteApps.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(L("appShortcut.search"), text: $service.query)
                .textFieldStyle(.plain)
                .font(.caption)
            if !service.query.isEmpty {
                Button {
                    service.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func appRow(_ app: LaunchableApp) -> some View {
        let isFavorite = service.favoritePaths.contains(app.path)
        return HStack(spacing: 8) {
            Button {
                _ = service.launch(app)
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(app.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                service.toggleFavorite(app)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            .help(L(isFavorite ? "appLauncher.favorite.remove" : "appLauncher.favorite.add"))
            .accessibilityLabel(L(isFavorite ? "appLauncher.favorite.remove" : "appLauncher.favorite.add"))
        }
    }
}
