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
            .replacingOccurrences(of: "{{newline}}", with: "\n")
            .replacingOccurrences(of: "{{clipboard}}", with: clipboardText ?? "")
    }
}

struct ClipboardSnippetGroup: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// 名称最后修改时间：重命名冲突时较新的一方胜出；旧数据为 nil。
    var updatedAt: Date?
    /// 删除墓碑：非空表示分组已删除，只用于把删除动作同步给其他设备。
    var deletedAt: Date?
}

struct ClipboardSnippet: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var groupID: UUID
    var title: String
    var content: String
    var updatedAt: Date
    var tags: [String] = []
    var isFavorite = false
    /// 删除墓碑：非空表示片段已删除，只用于把删除动作同步给其他设备。
    var deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, groupID, title, content, updatedAt, tags, isFavorite, deletedAt
    }

    init(
        id: UUID,
        groupID: UUID,
        title: String,
        content: String,
        updatedAt: Date,
        tags: [String] = [],
        isFavorite: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.title = title
        self.content = content
        self.updatedAt = updatedAt
        self.tags = tags
        self.isFavorite = isFavorite
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        groupID = try container.decode(UUID.self, forKey: .groupID)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

struct ClipboardSnippetStore {
    enum MoveDirection {
        case up
        case down
    }

    static let defaultGroupID = UUID(uuidString: "C6BEEFE8-690F-45F3-9E91-154E5F163A38")!
    static var defaultGroupName: String { L("clipboard.snippet.defaultGroup") }

    /// 墓碑保留时长与数量上限，与剪贴板历史一致。
    static let tombstoneRetention: TimeInterval = 30 * 86_400
    static let tombstoneLimit = 200

    private(set) var groups: [ClipboardSnippetGroup]
    private(set) var allSnippets: [ClipboardSnippet]
    private(set) var groupTombstones: [ClipboardSnippetGroup]
    private(set) var snippetTombstones: [ClipboardSnippet]

    init(
        groups: [ClipboardSnippetGroup] = [],
        snippets: [ClipboardSnippet] = [],
        groupTombstones: [ClipboardSnippetGroup] = [],
        snippetTombstones: [ClipboardSnippet] = []
    ) {
        self.groupTombstones = groupTombstones.isEmpty
            ? groups.filter { $0.deletedAt != nil }
            : groupTombstones
        self.snippetTombstones = snippetTombstones.isEmpty
            ? snippets.filter { $0.deletedAt != nil }
            : snippetTombstones
        let groups = groups.filter { $0.deletedAt == nil }
        let snippets = snippets.filter { $0.deletedAt == nil }
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
                    updatedAt: snippet.updatedAt,
                    tags: snippet.tags,
                    isFavorite: snippet.isFavorite
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

    mutating func removeGroup(id: UUID, now: Date = Date()) {
        guard id != Self.defaultGroupID,
              let removedGroup = groups.first(where: { $0.id == id }) else {
            return
        }
        groups.removeAll { $0.id == id }
        recordGroupTombstone(removedGroup, now: now)
        // 与本地语义一致：组内片段回到默认分组。
        // 「片段指向了已删除分组」这件事由合并的孤儿重分配统一处理，不在这里改时间戳。
        for index in allSnippets.indices where allSnippets[index].groupID == id {
            allSnippets[index].groupID = Self.defaultGroupID
        }
    }

    /// 按 ID 覆盖或追加分组（同步导入用），保持默认分组在前的排序。
    mutating func replaceGroup(_ group: ClipboardSnippetGroup) {
        guard group.id != Self.defaultGroupID else { return }
        groups.removeAll { $0.id == group.id }
        groups.append(group)
        groups.sort { lhs, rhs in
            if lhs.id == Self.defaultGroupID { return true }
            if rhs.id == Self.defaultGroupID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 按 ID 覆盖或追加片段（同步导入用）。
    mutating func replaceSnippet(_ snippet: ClipboardSnippet) {
        allSnippets.removeAll { $0.id == snippet.id }
        allSnippets.append(snippet)
    }

    mutating func removeSnippet(id: UUID, now: Date = Date()) {
        guard let index = allSnippets.firstIndex(where: { $0.id == id }) else { return }
        recordSnippetTombstone(allSnippets.remove(at: index), now: now)
    }

    /// 墓碑只保留身份与删除时间，避免正文跟着残留。
    private mutating func recordSnippetTombstone(_ snippet: ClipboardSnippet, now: Date) {
        snippetTombstones.removeAll { $0.id == snippet.id }
        snippetTombstones.insert(ClipboardSnippet(
            id: snippet.id,
            groupID: Self.defaultGroupID,
            title: "",
            content: "",
            updatedAt: now,
            deletedAt: now
        ), at: 0)
        trimTombstones(now: now)
    }

    private mutating func recordGroupTombstone(_ group: ClipboardSnippetGroup, now: Date) {
        groupTombstones.removeAll { $0.id == group.id }
        groupTombstones.insert(ClipboardSnippetGroup(
            id: group.id,
            name: "",
            updatedAt: now,
            deletedAt: now
        ), at: 0)
        trimTombstones(now: now)
    }

    /// 应用远端墓碑：删除本地对应条目并继续保留墓碑往下传。
    mutating func applyTombstones(
        groups incomingGroups: [ClipboardSnippetGroup],
        snippets incomingSnippets: [ClipboardSnippet],
        now: Date = Date()
    ) {
        for incoming in incomingGroups {
            guard let deletedAt = incoming.deletedAt else { continue }
            if let existing = groupTombstones.first(where: { $0.id == incoming.id }),
               (existing.deletedAt ?? .distantPast) >= deletedAt {
                continue
            }
            groupTombstones.removeAll { $0.id == incoming.id }
            groupTombstones.insert(incoming, at: 0)
            removeGroupLocally(id: incoming.id, now: now)
        }
        for incoming in incomingSnippets {
            guard let deletedAt = incoming.deletedAt else { continue }
            if let index = allSnippets.firstIndex(where: { $0.id == incoming.id }) {
                guard allSnippets[index].updatedAt <= deletedAt else { continue }
                allSnippets.remove(at: index)
            }
            if let existing = snippetTombstones.first(where: { $0.id == incoming.id }),
               (existing.deletedAt ?? .distantPast) >= deletedAt {
                continue
            }
            snippetTombstones.removeAll { $0.id == incoming.id }
            snippetTombstones.insert(incoming, at: 0)
        }
        trimTombstones(now: now)
    }

    /// 应用墓碑时删除本地分组：组内片段移回默认分组，但不再产生新墓碑。
    private mutating func removeGroupLocally(id: UUID, now: Date) {
        guard id != Self.defaultGroupID, groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        for index in allSnippets.indices where allSnippets[index].groupID == id {
            allSnippets[index].groupID = Self.defaultGroupID
        }
    }

    private mutating func trimTombstones(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.tombstoneRetention)
        groupTombstones.removeAll { ($0.deletedAt ?? .distantPast) < cutoff }
        snippetTombstones.removeAll { ($0.deletedAt ?? .distantPast) < cutoff }
        if groupTombstones.count > Self.tombstoneLimit {
            groupTombstones.removeLast(groupTombstones.count - Self.tombstoneLimit)
        }
        if snippetTombstones.count > Self.tombstoneLimit {
            snippetTombstones.removeLast(snippetTombstones.count - Self.tombstoneLimit)
        }
    }

    /// 导入（同步或归档）存活条目：清掉对应墓碑，避免刚导入就被自己的墓碑删掉。
    mutating func restoreImported(
        groups importedGroups: [ClipboardSnippetGroup],
        snippets importedSnippets: [ClipboardSnippet]
    ) {
        let groupIDs = Set(importedGroups.map(\.id))
        let snippetIDs = Set(importedSnippets.map(\.id))
        groupTombstones.removeAll { groupIDs.contains($0.id) }
        snippetTombstones.removeAll { snippetIDs.contains($0.id) }
    }

    @discardableResult
    mutating func updateGroup(id: UUID, name: String, now: Date = Date()) -> Bool {
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
        groups[index].updatedAt = now
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
        tags: [String] = [],
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
            updatedAt: now,
            tags: Self.normalizedTags(tags)
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
        tags: [String]? = nil,
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
        if let tags {
            snippet.tags = Self.normalizedTags(tags)
        }
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

    // 删除走带墓碑的 removeSnippet(id:now:)，这里不再保留无墓碑版本。

    mutating func toggleFavorite(id: UUID, now: Date = Date()) {
        guard let index = allSnippets.firstIndex(where: { $0.id == id }) else { return }
        allSnippets[index].isFavorite.toggle()
        // 收藏也是一种编辑：不刷新时间戳的话，其他设备上的旧副本会在合并时把它改回去。
        allSnippets[index].updatedAt = now
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
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
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(normalized) }
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
        // 墓碑跟随同一份文档持久化，重启后仍能参与同步。
        let document = ClipboardSnippetDocument(
            groups: store.groups + store.groupTombstones,
            snippets: store.allSnippets + store.snippetTombstones
        )
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
final class ClipboardSnippetService {
    static let shared = ClipboardSnippetService()

    private let persistenceURL: URL?
    private let persistenceSaver: @Sendable (ClipboardSnippetStore, URL) throws -> Void
    private var store: ClipboardSnippetStore

    private(set) var groups: [ClipboardSnippetGroup]
    private(set) var snippets: [ClipboardSnippet]
    private(set) var persistenceErrorMessage: String?

    init(
        persistenceURL: URL? = ClipboardSnippetPersistence.defaultURL(),
        persistenceSaver: @escaping @Sendable (ClipboardSnippetStore, URL) throws -> Void = ClipboardSnippetPersistence.save
    ) {
        let loadedStore = persistenceURL.map(ClipboardSnippetPersistence.load) ?? ClipboardSnippetStore()
        self.persistenceURL = persistenceURL
        self.persistenceSaver = persistenceSaver
        self.store = loadedStore
        self.groups = loadedStore.groups
        self.snippets = loadedStore.allSnippets
        self.persistenceErrorMessage = nil
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
    func addSnippet(title: String, content: String, groupID: UUID, tags: [String] = []) -> ClipboardSnippet? {
        let snippet = store.addSnippet(title: title, content: content, groupID: groupID, tags: tags)
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
    func updateSnippet(
        id: UUID,
        title: String,
        content: String,
        groupID: UUID,
        tags: [String]? = nil
    ) -> Bool {
        let didUpdate = store.updateSnippet(id: id, title: title, content: content, groupID: groupID, tags: tags)
        if didUpdate { synchronizeAndPersist() }
        return didUpdate
    }

    func toggleFavorite(id: UUID) {
        guard store.allSnippets.contains(where: { $0.id == id }) else { return }
        store.toggleFavorite(id: id)
        synchronizeAndPersist()
    }

    @discardableResult
    func moveSnippet(id: UUID, direction: ClipboardSnippetStore.MoveDirection) -> Bool {
        let didMove = store.moveSnippet(id: id, direction: direction)
        if didMove { synchronizeAndPersist() }
        return didMove
    }

    /// 参与共享文件夹同步的条目：存活的分组/片段 + 删除墓碑。
    var syncGroups: [ClipboardSnippetGroup] { store.groups + store.groupTombstones }
    var syncSnippets: [ClipboardSnippet] { store.allSnippets + store.snippetTombstones }

    func replaceImported(groups: [ClipboardSnippetGroup], snippets: [ClipboardSnippet]) {
        // 归档导入是「恢复」动作：保留本机墓碑，避免导入后删除过的条目又被同步回来。
        store = ClipboardSnippetStore(
            groups: groups,
            snippets: snippets,
            groupTombstones: store.groupTombstones,
            snippetTombstones: store.snippetTombstones
        )
        synchronizeAndPersist()
    }

    /// 同步导入：先应用远端墓碑，再导入存活条目。
    func importSynced(groups: [ClipboardSnippetGroup], snippets: [ClipboardSnippet]) {
        let liveGroups = groups.filter { $0.deletedAt == nil }
        let liveSnippets = snippets.filter { $0.deletedAt == nil }
        let hasTombstones = groups.contains { $0.deletedAt != nil } || snippets.contains { $0.deletedAt != nil }
        guard hasTombstones || !liveGroups.isEmpty || !liveSnippets.isEmpty else { return }

        store.applyTombstones(groups: groups, snippets: snippets)
        store.restoreImported(groups: liveGroups, snippets: liveSnippets)
        for group in liveGroups {
            store.replaceGroup(group)
        }
        for snippet in liveSnippets {
            store.replaceSnippet(snippet)
        }
        synchronizeAndPersist()
    }

    private func synchronizeAndPersist() {
        groups = store.groups
        snippets = store.allSnippets
        guard let persistenceURL else { return }
        do {
            try persistenceSaver(store, persistenceURL)
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }
}
