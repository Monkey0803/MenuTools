import AppKit
import SwiftUI

/// 剪贴板常用片段的分组、创建与复制入口。
struct ClipboardSnippetSettingsSection: View {
    let historyService: ClipboardHistoryService

    @State private var snippetService = ClipboardSnippetService.shared
    @State private var selectedSnippetGroupID = ClipboardSnippetStore.defaultGroupID
    @State private var isAddingSnippetGroup = false
    @State private var isRenamingSnippetGroup = false
    @State private var newSnippetGroupName = ""
    @State private var renamedSnippetGroupName = ""
    @State private var newSnippetTitle = ""
    @State private var newSnippetContent = ""
    @State private var newSnippetTags = ""
    @State private var snippetSearchText = ""
    @State private var editingSnippetID: UUID?
    @State private var editingSnippetGroupID = ClipboardSnippetStore.defaultGroupID
    @State private var editingSnippetTitle = ""
    @State private var editingSnippetContent = ""
    @State private var editingSnippetTags = ""
    @State private var copiedSnippetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(L("clipboard.snippets"), systemImage: "text.badge.star")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(snippetService.groups) { group in
                        Button(group.name) {
                            selectedSnippetGroupID = group.id
                        }
                    }
                } label: {
                    Label(selectedSnippetGroupName, systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.bordered)

                Button {
                    isAddingSnippetGroup.toggle()
                    newSnippetGroupName = ""
                } label: {
                    Image(systemName: isAddingSnippetGroup ? "xmark" : "plus")
                }
                .buttonStyle(.bordered)
                .help(L("clipboard.snippetGroup.add"))

                if selectedSnippetGroupID != ClipboardSnippetStore.defaultGroupID {
                    Button {
                        renamedSnippetGroupName = selectedSnippetGroupName
                        isRenamingSnippetGroup.toggle()
                    } label: {
                        Image(systemName: isRenamingSnippetGroup ? "xmark" : "pencil")
                    }
                    .buttonStyle(.bordered)
                    .help(L("clipboard.snippetGroup.rename"))

                    Button(role: .destructive) {
                        snippetService.removeGroup(id: selectedSnippetGroupID)
                        selectedSnippetGroupID = ClipboardSnippetStore.defaultGroupID
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help(L("clipboard.snippetGroup.delete"))
                }
            }

            if isAddingSnippetGroup {
                HStack(spacing: 8) {
                    TextField(L("clipboard.snippetGroup.placeholder"), text: $newSnippetGroupName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSnippetGroup)
                    Button(action: addSnippetGroup) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newSnippetGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if isRenamingSnippetGroup {
                HStack(spacing: 8) {
                    TextField(L("clipboard.snippetGroup.placeholder"), text: $renamedSnippetGroupName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(renameSnippetGroup)
                    Button(action: renameSnippetGroup) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renamedSnippetGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField(L("clipboard.snippetTitle"), text: $newSnippetTitle)
                    .textFieldStyle(.roundedBorder)
                TextField(L("clipboard.snippetTags"), text: $newSnippetTags)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newSnippetContent)
                    .font(.body)
                    .frame(minHeight: 72)
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))

                if !newSnippetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("clipboard.snippet.preview"), systemImage: "eye")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(renderedPreview)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                    }
                }

                HStack {
                    Text(L("clipboard.snippetDescription"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("clipboard.snippet.add"), action: addSnippet)
                        .buttonStyle(.borderedProminent)
                        .disabled(newSnippetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("clipboard.snippetSearch"), text: $snippetSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 9))

            let snippets = ClipboardSnippetSearch.results(
                in: snippetService.snippets(in: selectedSnippetGroupID),
                query: snippetSearchText
            )
            if snippets.isEmpty {
                Text(L("clipboard.snippets.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(snippets) { snippet in
                    if editingSnippetID == snippet.id {
                        snippetEditor(for: snippet)
                    } else {
                        snippetRow(snippet)
                    }
                }
            }

            if let persistenceErrorMessage = snippetService.persistenceErrorMessage {
                Label(persistenceErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .controlCenterSurface(interactive: true, shape: AnyShape(.rect(cornerRadius: 14)))
    }

    private func snippetRow(_ snippet: ClipboardSnippet) -> some View {
        HStack(spacing: 10) {
            Button(action: { copy(snippet) }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snippet.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(snippet.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L("clipboard.copy"))

            Button {
                snippetService.toggleFavorite(id: snippet.id)
            } label: {
                Image(systemName: snippet.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(snippet.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(snippet.isFavorite ? L("clipboard.snippet.unfavorite") : L("clipboard.snippet.favorite"))

            Image(systemName: copiedSnippetID == snippet.id ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(copiedSnippetID == snippet.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)

            Menu {
                Button(snippet.isFavorite ? L("clipboard.snippet.unfavorite") : L("clipboard.snippet.favorite")) {
                    snippetService.toggleFavorite(id: snippet.id)
                }
                Button(L("clipboard.snippet.edit")) { beginEditing(snippet) }
                Menu(L("clipboard.snippet.moveToGroup")) {
                    ForEach(snippetService.groups.filter { $0.id != snippet.groupID }) { group in
                        Button(group.name) {
                            _ = snippetService.updateSnippet(
                                id: snippet.id,
                                title: snippet.title,
                                content: snippet.content,
                                groupID: group.id
                            )
                        }
                    }
                }
                Button(L("clipboard.snippet.moveUp")) {
                    _ = snippetService.moveSnippet(id: snippet.id, direction: .up)
                }
                Button(L("clipboard.snippet.moveDown")) {
                    _ = snippetService.moveSnippet(id: snippet.id, direction: .down)
                }
                Divider()
                Button(L("clipboard.delete"), role: .destructive) {
                    snippetService.removeSnippet(id: snippet.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help(L("clipboard.actions"))
        }
        .padding(.vertical, 4)
    }

    private func snippetEditor(for snippet: ClipboardSnippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("clipboard.snippetTitle"), text: $editingSnippetTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $editingSnippetContent)
                .frame(minHeight: 72)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            TextField(L("clipboard.snippetTags"), text: $editingSnippetTags)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker(L("clipboard.snippet.moveToGroup"), selection: $editingSnippetGroupID) {
                    ForEach(snippetService.groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .labelsHidden()
                Spacer()
                Button(L("common.cancel")) { editingSnippetID = nil }
                Button(L("common.save")) { saveEditingSnippet(snippet) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingSnippetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 10))
    }

    private var selectedSnippetGroupName: String {
        snippetService.groups.first(where: { $0.id == selectedSnippetGroupID })?.name
            ?? snippetService.groups.first(where: { $0.id == ClipboardSnippetStore.defaultGroupID })?.name
            ?? L("clipboard.snippets")
    }

    private func addSnippetGroup() {
        let group = snippetService.addGroup(name: newSnippetGroupName)
        guard group.id != ClipboardSnippetStore.defaultGroupID else { return }
        selectedSnippetGroupID = group.id
        newSnippetGroupName = ""
        isAddingSnippetGroup = false
    }

    private func renameSnippetGroup() {
        guard snippetService.updateGroup(id: selectedSnippetGroupID, name: renamedSnippetGroupName) else {
            return
        }
        isRenamingSnippetGroup = false
        renamedSnippetGroupName = ""
    }

    private func addSnippet() {
        guard snippetService.addSnippet(
            title: newSnippetTitle,
            content: newSnippetContent,
            groupID: selectedSnippetGroupID,
            tags: newSnippetTags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
        ) != nil else {
            return
        }
        newSnippetTitle = ""
        newSnippetContent = ""
        newSnippetTags = ""
    }

    private func beginEditing(_ snippet: ClipboardSnippet) {
        editingSnippetID = snippet.id
        editingSnippetGroupID = snippet.groupID
        editingSnippetTitle = snippet.title
        editingSnippetContent = snippet.content
        editingSnippetTags = snippet.tags.joined(separator: ", ")
    }

    private func saveEditingSnippet(_ snippet: ClipboardSnippet) {
        guard snippetService.updateSnippet(
            id: snippet.id,
            title: editingSnippetTitle,
            content: editingSnippetContent,
            groupID: editingSnippetGroupID,
            tags: editingSnippetTags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
        ) else {
            return
        }
        editingSnippetID = nil
    }

    private func copy(_ snippet: ClipboardSnippet) {
        let renderedContent = ClipboardSnippetTemplate.render(
            snippet.content,
            clipboardText: NSPasteboard.general.string(forType: .string)
        )
        guard historyService.copy(.text(renderedContent)) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            copiedSnippetID = snippet.id
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard copiedSnippetID == snippet.id else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                copiedSnippetID = nil
            }
        }
    }

    private var renderedPreview: String {
        ClipboardSnippetTemplate.render(
            newSnippetContent,
            clipboardText: NSPasteboard.general.string(forType: .string)
        )
    }
}
