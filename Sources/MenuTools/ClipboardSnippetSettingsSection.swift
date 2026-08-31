import SwiftUI

/// 剪贴板常用片段的分组、创建与复制入口。
struct ClipboardSnippetSettingsSection: View {
    let historyService: ClipboardHistoryService

    @State private var snippetService = ClipboardSnippetService.shared
    @State private var selectedSnippetGroupID = ClipboardSnippetStore.defaultGroupID
    @State private var isAddingSnippetGroup = false
    @State private var newSnippetGroupName = ""
    @State private var newSnippetTitle = ""
    @State private var newSnippetContent = ""
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

            VStack(alignment: .leading, spacing: 8) {
                TextField(L("clipboard.snippetTitle"), text: $newSnippetTitle)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newSnippetContent)
                    .font(.body)
                    .frame(minHeight: 72)
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))

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

            let snippets = snippetService.snippets(in: selectedSnippetGroupID)
            if snippets.isEmpty {
                Text(L("clipboard.snippets.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(snippets) { snippet in
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

                        Image(systemName: copiedSnippetID == snippet.id ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(copiedSnippetID == snippet.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: 24, height: 24)

                        Button(role: .destructive) {
                            snippetService.removeSnippet(id: snippet.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help(L("clipboard.delete"))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .controlCenterSurface(interactive: true, shape: AnyShape(.rect(cornerRadius: 14)))
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

    private func addSnippet() {
        guard snippetService.addSnippet(
            title: newSnippetTitle,
            content: newSnippetContent,
            groupID: selectedSnippetGroupID
        ) != nil else {
            return
        }
        newSnippetTitle = ""
        newSnippetContent = ""
    }

    private func copy(_ snippet: ClipboardSnippet) {
        guard historyService.copy(.text(snippet.content)) else { return }
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
}
