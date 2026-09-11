import CoreGraphics
import Foundation

/// 按应用记住窗口尺寸。
///
/// 两套记忆互不覆盖：
/// - `previous`：每次应用布局前自动记录，供「还原」直接使用，用户不需要先手动记住；
/// - `saved`：用户在设置里手动记住的尺寸。
///
/// 数据以 JSON 存在一份 `UserDefaults` 里，只保留最近使用的若干个应用（LRU），避免无限增长。
struct WindowFrameMemory {
    private struct Entry: Codable, Equatable {
        var previous: [Double]?
        var saved: [Double]?
        var sequence: Int
    }

    static let entriesKey = "windowManagement.frameMemory"
    static let sequenceKey = "windowManagement.frameMemory.sequence"

    private let defaults: UserDefaults
    private let limit: Int

    init(defaults: UserDefaults = .standard, limit: Int = 40) {
        self.defaults = defaults
        self.limit = max(1, limit)
    }

    func previousFrame(for bundleIdentifier: String) -> CGRect? {
        Self.frame(from: entries()[bundleIdentifier]?.previous)
    }

    func savedFrame(for bundleIdentifier: String) -> CGRect? {
        Self.frame(from: entries()[bundleIdentifier]?.saved)
    }

    func rememberPreviousFrame(_ frame: CGRect, for bundleIdentifier: String) {
        update(bundleIdentifier) { $0.previous = Self.values(frame) }
    }

    func saveFrame(_ frame: CGRect, for bundleIdentifier: String) {
        update(bundleIdentifier) { $0.saved = Self.values(frame) }
    }

    func clear(bundleIdentifier: String) {
        var entries = self.entries()
        entries.removeValue(forKey: bundleIdentifier)
        store(entries)
    }

    func removeAll() {
        defaults.removeObject(forKey: Self.entriesKey)
        defaults.removeObject(forKey: Self.sequenceKey)
    }

    // MARK: - 内部

    private func update(_ bundleIdentifier: String, _ mutate: (inout Entry) -> Void) {
        var entries = self.entries()
        var entry = entries[bundleIdentifier] ?? Entry(previous: nil, saved: nil, sequence: 0)
        mutate(&entry)
        entry.sequence = nextSequence()
        entries[bundleIdentifier] = entry

        if entries.count > limit {
            let stale = entries
                .sorted { $0.value.sequence < $1.value.sequence }
                .prefix(entries.count - limit)
            for (key, _) in stale {
                entries.removeValue(forKey: key)
            }
        }
        store(entries)
    }

    /// 单调递增序号，而不是时间戳：同一毫秒内的连续写入也能稳定分出先后。
    private func nextSequence() -> Int {
        let next = defaults.integer(forKey: Self.sequenceKey) + 1
        defaults.set(next, forKey: Self.sequenceKey)
        return next
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.entriesKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }

    private func store(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }

    private static func values(_ frame: CGRect) -> [Double] {
        [Double(frame.origin.x), Double(frame.origin.y), Double(frame.size.width), Double(frame.size.height)]
    }

    private static func frame(from values: [Double]?) -> CGRect? {
        guard let values, values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
