import Foundation
import Observation

enum ClipboardSnippetTemplate {
    static func render(
        _ template: String,
        clipboardText: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let date = now.formatted(.dateTime.year().month().day())
        let time = now.formatted(.dateTime.hour().minute())
        return template
            .replacingOccurrences(of: "{{date}}", with: date)
            .replacingOccurrences(of: "{{time}}", with: time)
            .replacingOccurrences(of: "{{clipboard}}", with: clipboardText ?? "")
    }
}

struct ClipboardSnippetGroup: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
}

struct ClipboardSnippet: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var groupID: UUID
    var title: String
    var content: String
    var updatedAt: Date
}

struct ClipboardSnippetStore {
    enum MoveDirection {
        case up
        case down
    }

    static let defaultGroupID = UUID(uuidString: "C6BEEFE8-690F-45F3-9E91-154E5F163A38")!
    static var defaultGroupName: String { L("clipboard.snippet.defaultGroup") }

    private(set) var groups: [ClipboardSnippetGroup]
    private(set) var allSnippets: [ClipboardSnippet]

    init(
        groups: [ClipboardSnippetGroup] = [],
        snippets: [ClipboardSnippet] = []
    ) {
        var normalizedGroups = groups
        if !normalizedGroups.contains(where: { $0.id == Self.defaultGroupID }) {
            normalizedGroups.insert(
                ClipboardSnippetGroup(id: Self.defaultGroupID, name: Self.defaultGroupName),
                at: 0
            )
        }
        self.groups = normalizedGroups.sorted { lhs, rhs in
            if lhs.id == Self.defaultGroupID { return true }
            if rhs.id == Self.defaultGroupID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let validGroupIDs = Set(self.groups.map(\.id))
        self.allSnippets = snippets.map { snippet in
            guard validGroupIDs.contains(snippet.groupID) else {
                return ClipboardSnippet(
                    id: snippet.id,
                    groupID: Self.defaultGroupID,
                    title: snippet.title,
                    content: snippet.content,
                    updatedAt: snippet.updatedAt
                )
            }
            return snippet
        }
    }

    func snippets(in groupID: UUID) -> [ClipboardSnippet] {
        allSnippets.filter { $0.groupID == groupID }
    }

    mutating func addGroup(name: String) -> ClipboardSnippetGroup {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            return defaultGroup
        }
        if let existing = groups.first(where: {
            $0.name.compare(normalizedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing
        }

        let group = ClipboardSnippetGroup(id: UUID(), name: normalizedName)
        groups.append(group)
        groups.sort { lhs, rhs in
            if lhs.id == Self.defaultGroupID { return true }
            if rhs.id == Self.defaultGroupID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return group
    }

    mutating func removeGroup(id: UUID) {
        guard id != Self.defaultGroupID,
              groups.contains(where: { $0.id == id }) else {
            return
        }
        groups.removeAll { $0.id == id }
        for index in allSnippets.indices where allSnippets[index].groupID == id {
            allSnippets[index].groupID = Self.defaultGroupID
        }
    }

    @discardableResult
    mutating func updateGroup(id: UUID, name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != Self.defaultGroupID,
              !normalizedName.isEmpty,
              let index = groups.firstIndex(where: { $0.id == id }),
              !groups.contains(where: {
                  $0.id != id && $0.name.compare(
                      normalizedName,
                      options: [.caseInsensitive, .diacriticInsensitive]
                  ) == .orderedSame
              }) else {
            return false
        }
        groups[index].name = normalizedName
        groups.sort { lhs, rhs in
            if lhs.id == Self.defaultGroupID { return true }
            if rhs.id == Self.defaultGroupID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return true
    }

    mutating func addSnippet(
        title: String,
        content: String,
        groupID: UUID,
        now: Date = Date()
    ) -> ClipboardSnippet? {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return nil }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = ClipboardSnippet(
            id: UUID(),
            groupID: groups.contains(where: { $0.id == groupID }) ? groupID : Self.defaultGroupID,
            title: normalizedTitle.isEmpty ? String(normalizedContent.prefix(24)) : normalizedTitle,
            content: normalizedContent,
            updatedAt: now
        )
        allSnippets.insert(snippet, at: 0)
        return snippet
    }

    @discardableResult
    mutating func updateSnippet(
        id: UUID,
        title: String,
        content: String,
        groupID: UUID,
        now: Date = Date()
    ) -> Bool {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty,
              let index = allSnippets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedGroupID = groups.contains(where: { $0.id == groupID }) ? groupID : Self.defaultGroupID
        var snippet = allSnippets.remove(at: index)
        let didMoveGroups = snippet.groupID != resolvedGroupID
        snippet.groupID = resolvedGroupID
        snippet.title = normalizedTitle.isEmpty ? String(normalizedContent.prefix(24)) : normalizedTitle
        snippet.content = normalizedContent
        snippet.updatedAt = now
        if didMoveGroups, let destinationIndex = allSnippets.firstIndex(where: { $0.groupID == resolvedGroupID }) {
            allSnippets.insert(snippet, at: destinationIndex)
        } else if didMoveGroups {
            allSnippets.append(snippet)
        } else {
            allSnippets.insert(snippet, at: min(index, allSnippets.count))
        }
        return true
    }

    @discardableResult
    mutating func moveSnippet(id: UUID, direction: MoveDirection) -> Bool {
        guard let index = allSnippets.firstIndex(where: { $0.id == id }) else { return false }
        let groupID = allSnippets[index].groupID
        let groupIndexes = allSnippets.indices.filter { allSnippets[$0].groupID == groupID }
        guard let position = groupIndexes.firstIndex(of: index) else { return false }
        let destinationPosition = direction == .up ? position - 1 : position + 1
        guard groupIndexes.indices.contains(destinationPosition) else { return false }
        allSnippets.swapAt(index, groupIndexes[destinationPosition])
        return true
    }

    mutating func removeSnippet(id: UUID) {
        allSnippets.removeAll { $0.id == id }
    }

    private var defaultGroup: ClipboardSnippetGroup {
        groups.first(where: { $0.id == Self.defaultGroupID })
            ?? ClipboardSnippetGroup(id: Self.defaultGroupID, name: Self.defaultGroupName)
    }
}

enum ClipboardSnippetSearch {
    static func results(in snippets: [ClipboardSnippet], query: String) -> [ClipboardSnippet] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.content.localizedCaseInsensitiveContains(normalized)
        }
    }
}

private struct ClipboardSnippetDocument: Codable {
    var groups: [ClipboardSnippetGroup]
    var snippets: [ClipboardSnippet]
}

enum ClipboardSnippetPersistence {
    private static let directoryName = "MenuTools"
    private static let fileName = "ClipboardSnippets.json"

    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    static func load(from url: URL) -> ClipboardSnippetStore {
        guard let data = try? Data(contentsOf: url) else { return ClipboardSnippetStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let document = try? decoder.decode(ClipboardSnippetDocument.self, from: data) else {
            return ClipboardSnippetStore()
        }
        return ClipboardSnippetStore(groups: document.groups, snippets: document.snippets)
    }

    static func save(_ store: ClipboardSnippetStore, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let document = ClipboardSnippetDocument(groups: store.groups, snippets: store.allSnippets)
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
final class ClipboardSnippetService {
    static let shared = ClipboardSnippetService()

    private let persistenceURL: URL?
    private var store: ClipboardSnippetStore

    private(set) var groups: [ClipboardSnippetGroup]
    private(set) var snippets: [ClipboardSnippet]

    init(persistenceURL: URL? = ClipboardSnippetPersistence.defaultURL()) {
        let loadedStore = persistenceURL.map(ClipboardSnippetPersistence.load) ?? ClipboardSnippetStore()
        self.persistenceURL = persistenceURL
        self.store = loadedStore
        self.groups = loadedStore.groups
        self.snippets = loadedStore.allSnippets
    }

    func snippets(in groupID: UUID) -> [ClipboardSnippet] {
        store.snippets(in: groupID)
    }

    @discardableResult
    func addGroup(name: String) -> ClipboardSnippetGroup {
        let group = store.addGroup(name: name)
        synchronizeAndPersist()
        return group
    }

    func removeGroup(id: UUID) {
        store.removeGroup(id: id)
        synchronizeAndPersist()
    }

    @discardableResult
    func updateGroup(id: UUID, name: String) -> Bool {
        let didUpdate = store.updateGroup(id: id, name: name)
        if didUpdate { synchronizeAndPersist() }
        return didUpdate
    }

    @discardableResult
    func addSnippet(title: String, content: String, groupID: UUID) -> ClipboardSnippet? {
        let snippet = store.addSnippet(title: title, content: content, groupID: groupID)
        if snippet != nil {
            synchronizeAndPersist()
        }
        return snippet
    }

    func removeSnippet(id: UUID) {
        store.removeSnippet(id: id)
        synchronizeAndPersist()
    }

    @discardableResult
    func updateSnippet(id: UUID, title: String, content: String, groupID: UUID) -> Bool {
        let didUpdate = store.updateSnippet(id: id, title: title, content: content, groupID: groupID)
        if didUpdate { synchronizeAndPersist() }
        return didUpdate
    }

    @discardableResult
    func moveSnippet(id: UUID, direction: ClipboardSnippetStore.MoveDirection) -> Bool {
        let didMove = store.moveSnippet(id: id, direction: direction)
        if didMove { synchronizeAndPersist() }
        return didMove
    }

    func replaceImported(groups: [ClipboardSnippetGroup], snippets: [ClipboardSnippet]) {
        store = ClipboardSnippetStore(groups: groups, snippets: snippets)
        synchronizeAndPersist()
    }

    private func synchronizeAndPersist() {
        groups = store.groups
        snippets = store.allSnippets
        guard let persistenceURL else { return }
        try? ClipboardSnippetPersistence.save(store, to: persistenceURL)
    }
}
