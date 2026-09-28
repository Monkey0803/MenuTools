import Testing
@testable import MenuTools

@Test("编辑器撤销栈：记录、撤销、重做")
func editorHistoryUndoRedo() {
    var history = ScreenshotEditorHistory<Int>(limit: 10)
    #expect(!history.canUndo)
    #expect(!history.canRedo)
    #expect(history.undo(current: 0) == nil)
    #expect(history.redo(current: 0) == nil)

    history.record(1)
    history.record(2)
    #expect(history.canUndo)
    #expect(history.pastCount == 2)

    #expect(history.undo(current: 3) == 2)
    #expect(history.canRedo)
    #expect(history.undo(current: 2) == 1)
    #expect(history.redo(current: 1) == 2)
    #expect(history.redo(current: 2) == 3)
    #expect(!history.canRedo)

    // 新的改动会清空重做栈：分支历史不再可回到
    history.record(9)
    #expect(!history.canRedo)
    #expect(history.undo(current: 10) == 9)
}

@Test("编辑器撤销栈受上限约束，不会无限增长")
func editorHistoryIsBounded() {
    var history = ScreenshotEditorHistory<Int>(limit: 3)
    for value in 1 ... 20 {
        history.record(value)
    }
    #expect(history.pastCount == 3)

    // 只能回退保留范围内的步数
    #expect(history.undo(current: 21) == 20)
    #expect(history.undo(current: 20) == 19)
    #expect(history.undo(current: 19) == 18)
    #expect(history.undo(current: 18) == nil)

    // 重做栈同样受限
    var redoBounded = ScreenshotEditorHistory<Int>(limit: 1)
    redoBounded.record(1)
    redoBounded.record(2)
    _ = redoBounded.undo(current: 3)
    _ = redoBounded.undo(current: 2)
    #expect(redoBounded.futureCount == 1)

    // 非法上限至少保留一步，避免撤销完全失效
    var minimum = ScreenshotEditorHistory<Int>(limit: 0)
    minimum.record(1)
    minimum.record(2)
    #expect(minimum.pastCount == 1)

    // reset 清空两侧
    minimum.reset()
    #expect(!minimum.canUndo)
    #expect(!minimum.canRedo)
}
