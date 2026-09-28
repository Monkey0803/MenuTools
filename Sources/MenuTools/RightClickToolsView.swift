import SwiftUI
import Combine
import FinderSync
import UniformTypeIdentifiers

/// Finder 右键配置：菜单排序、文件模板及常用应用 / 目录。
struct RightClickToolsView: View {
    @State private var config = RightClickConfigStore.load()
    @StateObject private var extensionStatus = FinderSyncExtensionStatusService()
    @State private var page = 0
    @State private var templateDraft: RightClickTemplate?
    @State private var errorMessage: String?
    private let configChanges = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name(RightClickConfigStore.didChangeNotification))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fixedHeader
                .padding(.horizontal, SettingsScrollLayout.contentPadding)
                .padding(.top, SettingsScrollLayout.contentPadding)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case 1: templates
                    case 2: favorites
                    default: menuItems
                    }
                }
                // 留白必须加在内容内部，否则滚动条会压在右侧开关上
                .padding(SettingsScrollLayout.contentInsets())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .onAppear(perform: refreshExtensionStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExtensionStatus()
        }
        .onReceive(configChanges) { config = RightClickConfigNotification.applying($0, to: config) }
        .sheet(item: $templateDraft) { draft in
            RightClickTemplateEditor(template: draft) { edited in
                var next = config
                if let index = next.templates.firstIndex(where: { $0.id == edited.id }) { next.templates[index] = edited }
                else { next.templates.append(edited) }
                do {
                    try RightClickConfigStore.save(next)
                    config = next
                    return nil
                } catch { return error.localizedDescription }
            }
        }
        .alert(L("rc.error.title"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button(L("rc.button.ok")) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }

    /// 顶部标题、扩展状态与分页选择器固定不滚动。
    private var fixedHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "contextualmenu.and.cursorarrow").font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("rc.title")).font(.title3.weight(.semibold))
                    Text(L("rc.subtitle")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        L(extensionStatusTitleKey),
                        systemImage: extensionStatusIcon
                    )
                    .foregroundStyle(extensionStatusColor)
                    Text(L("rc.permission.title")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("rc.permission.refresh"), action: refreshExtensionStatus)
                    Button(L("rc.permission.openSettings")) {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                }
                Text(L("rc.permission.managementHint"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Picker(L("rc.settings.page"), selection: $page) {
                Text(L("rc.settings.menu")).tag(0)
                Text(L("rc.settings.templates")).tag(1)
                Text(L("rc.settings.favorites")).tag(2)
            }.pickerStyle(.segmented)
        }
    }

    private func refreshExtensionStatus() {
        extensionStatus.refresh(finderAPIEnabled: FIFinderSyncController.isExtensionEnabled)
    }

    private var extensionStatusTitleKey: String {
        switch extensionStatus.state {
        case .enabled: "rc.permission.enabled"
        case .registered: "rc.permission.registered"
        case .disabled: "rc.permission.disabled"
        case .unknown: "rc.permission.unknown"
        }
    }

    private var extensionStatusIcon: String {
        extensionStatus.state.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var extensionStatusColor: Color {
        extensionStatus.state.isAvailable ? .green : .orange
    }

    private var menuItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("rc.settings.menuHint")).font(.caption).foregroundStyle(.secondary)
            GroupBox(L("rc.settings.menuStyle")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("rc.settings.menuStyle"), selection: Binding(
                        get: { config.menuStyle },
                        set: { value in
                            var next = config
                            next.menuStyle = value
                            save(next)
                        }
                    )) {
                        ForEach(RightClickMenuStyle.allCases) { style in
                            Text(L(style.titleKey)).tag(style)
                        }
                    }.pickerStyle(.radioGroup).labelsHidden()
                    Text(L("rc.settings.menuStyleHint"))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            ForEach(Array(config.orderedItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L(item.titleKey))
                        if let key = item.subtitleKey { Text(L(key)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    reorderButtons(index: index, count: config.orderedItems.count) { offset in
                        var next = config
                        next.order = config.orderedItems.map(\.rawValue)
                        next.order.swapAt(index, index + offset)
                        save(next)
                    }
                    Toggle(L(item.titleKey), isOn: Binding(
                        get: { config.isEnabled(item) },
                        set: { value in
                            var next = config
                            next.enabled[item.rawValue] = value
                            save(next)
                        }
                    )).labelsHidden().toggleStyle(.switch)
                }.controlSize(.small).padding(.vertical, 5)
                Divider()
            }
            GroupBox(L("rc.settings.directoryListing")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L("rc.settings.listingHidden"), isOn: Binding(
                        get: { config.directoryListing.includeHidden },
                        set: { value in
                            var next = config
                            next.directoryListing.includeHidden = value
                            save(next)
                        }
                    ))
                    Stepper(value: Binding(
                        get: { config.directoryListing.maxDepth },
                        set: { value in
                            var next = config
                            next.directoryListing.maxDepth = value
                            save(next)
                        }
                    ), in: 0...50) {
                        Text(L("rc.settings.listingDepth", config.directoryListing.maxDepth))
                    }
                    TextField(L("rc.settings.listingIgnore"), text: Binding(
                        get: { config.directoryListing.ignoredPatterns.joined(separator: ", ") },
                        set: { value in
                            var next = config
                            next.directoryListing.ignoredPatterns = value
                                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            save(next)
                        }
                    ))
                    Text(L("rc.settings.listingIgnoreHint"))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            GroupBox(L("rc.settings.diagnostics")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L("rc.settings.logger"), isOn: Binding(
                        get: { config.loggerEnabled },
                        set: { value in
                            var next = config
                            next.loggerEnabled = value
                            guard save(next) else { return }
                            // 开关存在共享配置里，扩展进程由配置广播同步（沙盒读不到 App 的 defaults）
                            RightClickLogger.apply(next)
                        }
                    ))
                    Text(L("rc.settings.loggerHint"))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
            Text(L("rc.settings.templateHint")).font(.caption).foregroundStyle(.secondary)
            Text(L("rc.settings.templateVariables")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(L("rc.settings.addTemplate")) {
                    templateDraft = .init(id: UUID().uuidString, name: "", filename: "", content: "")
                }
            }
            ForEach(Array(config.templates.enumerated()), id: \.element.id) { index, template in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name)
                        Text(template.filename).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    reorderButtons(index: index, count: config.templates.count) { offset in
                        var next = config
                        next.templates.swapAt(index, index + offset)
                        save(next)
                    }
                    Button(L("rc.button.edit")) { templateDraft = template }
                    Button(role: .destructive) {
                        var next = config
                        next.templates.removeAll { $0.id == template.id }
                        save(next)
                    } label: { Image(systemName: "trash") }.help(L("rc.button.remove"))
                }.controlSize(.small)
                Divider()
            }
            if config.templates.isEmpty { Text(L("rc.settings.noTemplates")).foregroundStyle(.secondary) }
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("rc.settings.applications")).font(.headline)
                Spacer()
                Button(L("rc.settings.addApplication"), action: addApplications)
            }
            Text(L("rc.settings.applicationHint")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(config.applications.enumerated()), id: \.element.id) { index, application in
                applicationRow(application, index: index)
            }
            Divider().padding(.vertical, 8)
            HStack {
                Text(L("rc.settings.destinations")).font(.headline)
                Spacer()
                Button(L("rc.settings.addDestination"), action: addDestinations)
            }
            Text(L("rc.settings.destinationHint")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(config.destinations.enumerated()), id: \.element.id) { index, destination in
                favoriteRow(name: destination.name, path: destination.path, index: index,
                            count: config.destinations.count, move: { offset in
                    var next = config
                    next.destinations.swapAt(index, index + offset)
                    save(next)
                }, remove: {
                    var next = config
                    next.destinations.removeAll { $0.id == destination.id }
                    save(next)
                })
            }
        }
    }

    private func applicationRow(_ application: RightClickApplication, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name)
                Text(application.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(application.path)
            }
            Spacer()
            Menu {
                Button(L("rc.fileKind.all")) {
                    var next = config
                    next.applications[index].filter = .all
                    save(next)
                }
                Divider()
                ForEach(RightClickFileKind.allCases) { kind in
                    Button {
                        var next = config
                        if next.applications[index].filter.kinds.contains(kind) {
                            next.applications[index].filter.kinds.remove(kind)
                        } else {
                            next.applications[index].filter.kinds.insert(kind)
                        }
                        save(next)
                    } label: {
                        if application.filter.kinds.contains(kind) { Label(L(kind.titleKey), systemImage: "checkmark") }
                        else { Text(L(kind.titleKey)) }
                    }
                }
            } label: {
                Text(application.filter == .all ? L("rc.fileKind.all") : L("rc.fileKind.count", application.filter.kinds.count))
            }.help(L("rc.settings.applicationFilter"))
            reorderButtons(index: index, count: config.applications.count) { offset in
                var next = config
                next.applications.swapAt(index, index + offset)
                save(next)
            }
            Button(role: .destructive) {
                var next = config
                next.applications.removeAll { $0.id == application.id }
                save(next)
            } label: { Image(systemName: "trash") }.help(L("rc.button.remove"))
        }.controlSize(.small)
    }

    private func reorderButtons(index: Int, count: Int, move: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help(L("rc.settings.moveUp")).accessibilityLabel(L("rc.settings.moveUp"))
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1).help(L("rc.settings.moveDown")).accessibilityLabel(L("rc.settings.moveDown"))
        }
    }

    private func favoriteRow(name: String, path: String, index: Int, count: Int,
                             move: @escaping (Int) -> Void, remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path)
            }
            Spacer()
            reorderButtons(index: index, count: count, move: move)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help(L("rc.button.remove"))
        }.controlSize(.small)
    }

    @discardableResult private func save(_ next: RightClickConfig) -> Bool {
        do {
            try RightClickConfigStore.save(next)
            config = next
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func addApplications() {
        let panel = NSOpenPanel()
        panel.title = L("rc.settings.addApplication")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var next = config
        for url in panel.urls where !next.applications.contains(where: { $0.path == url.path }) {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
            next.applications.append(.init(id: UUID().uuidString,
                name: FileManager.default.displayName(atPath: url.path), path: url.path, bundleIdentifier: identifier))
        }
        save(next)
    }

    private func addDestinations() {
        let panel = NSOpenPanel()
        panel.title = L("rc.settings.addDestination")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var next = config
        for url in panel.urls where !next.destinations.contains(where: { $0.path == url.path }) {
            next.destinations.append(.init(id: UUID().uuidString,
                name: FileManager.default.displayName(atPath: url.path), path: url.path))
        }
        save(next)
    }
}

private struct RightClickTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var template: RightClickTemplate
    @State private var validationError: String?
    let save: (RightClickTemplate) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("rc.settings.editTemplate")).font(.headline)
            TextField(L("rc.settings.templateName"), text: $template.name)
            TextField(L("rc.settings.templateFilename"), text: $template.filename)
            Text(L("rc.settings.templateContent")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $template.content).font(.system(.body, design: .monospaced))
                .frame(minHeight: 220).border(.separator)
            if let validationError { Text(validationError).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L("rc.button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("rc.button.save")) {
                    do {
                        try RightClickFileService.validateName(template.filename)
                        if let message = save(template) { validationError = message }
                        else { dismiss() }
                    } catch { validationError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || template.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}
