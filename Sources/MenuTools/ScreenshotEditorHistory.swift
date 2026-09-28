import Foundation

/// 标注器的撤销/重做栈（纯逻辑，便于回归）。
///
/// 此前 `undo()` 只会 `annotations.popLast()`，而裁剪与旋转直接 `annotations.removeAll()`
/// 且没有任何快照：一刀剪下去就永远回不到原图，重做更是完全不存在。
/// 这里把「改动前的状态」压栈，让裁剪、旋转、清空、新增标注都变成可撤销的一步。
struct ScreenshotEditorHistory<State> {
    /// 保留的步数上限：每步都可能带着整张图，不能无限留。
    static var defaultLimit: Int { 30 }

    private(set) var past: [State] = []
    private(set) var future: [State] = []
    let limit: Int

    init(limit: Int = ScreenshotEditorHistory.defaultLimit) {
        // 至少保留一步：上限配成 0 也不能让撤销彻底失效。
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var pastCount: Int { past.count }
    var futureCount: Int { future.count }

    /// 在改动**之前**记录当前状态。记录新改动会清空重做栈（分支历史不再可达）。
    mutating func record(_ state: State) {
        past.append(state)
        if past.count > limit {
            past.removeFirst(past.count - limit)
        }
        future.removeAll()
    }

    /// 返回应当恢复的状态，并把传入的当前状态压入重做栈。
    mutating func undo(current: State) -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        if future.count > limit {
            future.removeFirst(future.count - limit)
        }
        return previous
    }

    /// 返回应当恢复的状态，并把传入的当前状态压回撤销栈。
    mutating func redo(current: State) -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        if past.count > limit {
            past.removeFirst(past.count - limit)
        }
        return next
    }

    mutating func reset() {
        past.removeAll()
        future.removeAll()
    }
}
