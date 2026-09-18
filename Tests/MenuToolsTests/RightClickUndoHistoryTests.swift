import Foundation
import Testing
@testable import MenuTools

@Test("撤销历史保留多条记录并按最后一条出栈")
func rightClickUndoHistoryKeepsRecordsInOrder() throws {
    try withUndoHistoryFile { file in
        let first = undoRecord(kind: .create, destination: "/tmp/one")
        let second = undoRecord(kind: .copy, destination: "/tmp/two", source: "/tmp/source")
        try RightClickUndoStore.push(first, at: file)
        try RightClickUndoStore.push(second, at: file)

        #expect(RightClickUndoStore.history(at: file) == [first, second])
        #expect(RightClickUndoStore.load(at: file) == second)
        #expect(RightClickUndoStore.count(at: file) == 2)

        try RightClickUndoStore.removeLast(at: file)
        #expect(RightClickUndoStore.load(at: file) == first)
        #expect(RightClickUndoStore.count(at: file) == 1)

        try RightClickUndoStore.removeLast(at: file)
        #expect(RightClickUndoStore.load(at: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test("撤销历史只保留最近的操作")
func rightClickUndoHistoryCapsDepth() throws {
    try withUndoHistoryFile { file in
        for index in 0..<(RightClickUndoStore.maxDepth + 3) {
            try RightClickUndoStore.push(undoRecord(kind: .create, destination: "/tmp/item-\(index)"), at: file)
        }
        let history = RightClickUndoStore.history(at: file)
        #expect(history.count == RightClickUndoStore.maxDepth)
        #expect(history.first?.entries.first?.destination == "/tmp/item-3")
        #expect(history.last?.entries.first?.destination == "/tmp/item-\(RightClickUndoStore.maxDepth + 2)")
    }
}

@Test("旧版单条撤销记录仍可读取")
func rightClickUndoHistoryReadsLegacyRecord() throws {
    try withUndoHistoryFile { file in
        let record = undoRecord(kind: .create, destination: "/tmp/legacy")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        #expect(RightClickUndoStore.load(at: file) == record)
        #expect(RightClickUndoStore.history(at: file) == [record])
    }
}

@Test("撤销历史过滤非法记录后再追加")
func rightClickUndoHistoryFiltersInvalidRecords() throws {
    try withUndoHistoryFile { file in
        let invalid = undoRecord(kind: .move, destination: "/tmp/moved")
        try JSONEncoder().encode([invalid]).write(to: file, options: .atomic)
        // 旧格式是单条记录，数组不是历史结构；这里验证损坏内容不会进入历史。
        #expect(RightClickUndoStore.history(at: file).isEmpty)

        let valid = undoRecord(kind: .create, destination: "/tmp/valid")
        try RightClickUndoStore.push(valid, at: file)
        #expect(RightClickUndoStore.history(at: file) == [valid])
    }
}

private func undoRecord(kind: RightClickUndoRecord.Kind, destination: String,
                        source: String? = nil) -> RightClickUndoRecord {
    .init(kind: kind, entries: [
        .init(source: source, destination: destination, destinationIdentity: .init(device: 1, inode: 2))
    ])
}

private func withUndoHistoryFile(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-UndoHistory-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appendingPathComponent("undo.json"))
}
