import Foundation
import Testing
@testable import MenuTools

@Test("文件传输报告总量、当前项和最终进度")
func rightClickTransferReportsProgress() throws {
    try withRightClickOperationDirectory { directory in
        let source = try RightClickFileService.createFolder(in: directory, name: "source")
        let target = try RightClickFileService.createFolder(in: directory, name: "target")
        let first = try RightClickFileService.createFile(in: source, name: "a.txt", data: Data(repeating: 1, count: 100))
        let second = try RightClickFileService.createFile(in: source, name: "b.txt", data: Data(repeating: 2, count: 200))
        var values: [RightClickTransferProgress] = []
        let result = try RightClickFileService.transfer(
            sources: [first, second], destination: target, move: false, conflict: .keepBoth,
            progress: { values.append($0) }, isCancelled: { false })
        #expect(result.completed.count == 2)
        #expect(values.last?.completedItems == 2)
        #expect(values.last?.totalItems == 2)
        #expect(values.last?.completedBytes == 300)
        #expect(values.last?.totalBytes == 300)
    }
}

@Test("文件传输在开始前可取消且不产生目标")
func rightClickTransferCanCancel() throws {
    try withRightClickOperationDirectory { directory in
        let source = try RightClickFileService.createFile(in: directory, name: "a.txt", data: Data(repeating: 1, count: 1024))
        let target = try RightClickFileService.createFolder(in: directory, name: "target")
        #expect(throws: CancellationError.self) {
            try RightClickFileService.transfer(sources: [source], destination: target, move: false, conflict: .keepBoth,
                                               progress: { _ in }, isCancelled: { true })
        }
        #expect(!RightClickFileService.itemExists(target.appendingPathComponent("a.txt")))
    }
}

@Test("大文件复制可在传输中取消并清理半成品")
func rightClickTransferCancelsDuringCopy() throws {
    try withRightClickOperationDirectory { directory in
        let source = try RightClickFileService.createFile(
            in: directory, name: "large.bin", data: Data(repeating: 7, count: 8 * 1024 * 1024))
        let target = try RightClickFileService.createFolder(in: directory, name: "target")
        var shouldCancel = false
        #expect(throws: CancellationError.self) {
            try RightClickFileService.transfer(
                sources: [source], destination: target, move: true, conflict: .keepBoth,
                progress: { value in if value.completedBytes > 0 { shouldCancel = true } },
                isCancelled: { shouldCancel })
        }
        #expect(RightClickFileService.itemExists(source))
        #expect(!RightClickFileService.itemExists(target.appendingPathComponent("large.bin")))
    }
}

@Test("复制撤销移除副本，移动撤销恢复来源且不覆盖冲突")
func rightClickUndoCopyAndMoveSafely() throws {
    try withRightClickOperationDirectory { directory in
        let sourceDirectory = try RightClickFileService.createFolder(in: directory, name: "source")
        let target = try RightClickFileService.createFolder(in: directory, name: "target")
        let source = try RightClickFileService.createFile(in: sourceDirectory, name: "a.txt", data: Data("original".utf8))
        let copied = try RightClickFileService.transfer(sources: [source], destination: target, move: false, conflict: .keepBoth)
        let copiedIdentity = try #require(RightClickFileService.itemIdentity(copied.completed[0]))
        let copyRecord = RightClickUndoRecord(kind: .copy, entries: [
            .init(source: source.path, destination: copied.completed[0].path, destinationIdentity: copiedIdentity)
        ])
        let copyUndo = RightClickFileService.undo(copyRecord)
        #expect(copyUndo.completed.count == 1)
        #expect(!RightClickFileService.itemExists(copied.completed[0]))
        #expect(RightClickFileService.itemExists(source))

        let moved = try RightClickFileService.transfer(sources: [source], destination: target, move: true, conflict: .keepBoth)
        let movedIdentity = try #require(RightClickFileService.itemIdentity(moved.completed[0]))
        let moveRecord = RightClickUndoRecord(kind: .move, entries: [
            .init(source: source.path, destination: moved.completed[0].path, destinationIdentity: movedIdentity)
        ])
        try Data("conflict".utf8).write(to: source)
        let blocked = RightClickFileService.undo(moveRecord)
        #expect(blocked.completed.isEmpty)
        #expect(blocked.failures.count == 1)
        #expect(try String(contentsOf: source, encoding: .utf8) == "conflict")
        #expect(RightClickFileService.itemExists(moved.completed[0]))
    }
}

@Test("撤销不会删除已被其他项目占用的原目标路径")
func rightClickUndoRejectsReplacedDestination() throws {
    try withRightClickOperationDirectory { directory in
        let generated = try RightClickFileService.createFile(
            in: directory, name: "generated.txt", data: Data("generated".utf8))
        let identity = try #require(RightClickFileService.itemIdentity(generated))
        let record = RightClickUndoRecord(kind: .create, entries: [
            .init(source: nil, destination: generated.path, destinationIdentity: identity)
        ])
        try FileManager.default.removeItem(at: generated)
        try Data("replacement".utf8).write(to: generated)

        let result = RightClickFileService.undo(record)

        #expect(result.completed.isEmpty)
        #expect(result.failures.count == 1)
        #expect(try String(contentsOf: generated, encoding: .utf8) == "replacement")
    }
}

@Test("撤销记录可原子保存、读取和清空")
func rightClickUndoStoreRoundTrip() throws {
    try withRightClickOperationDirectory { directory in
        let file = directory.appendingPathComponent("undo.json")
        let record = RightClickUndoRecord(kind: .create, entries: [
            .init(source: nil, destination: "/tmp/test", destinationIdentity: .init(device: 1, inode: 2))
        ])
        try RightClickUndoStore.save(record, at: file)
        #expect(RightClickUndoStore.load(at: file) == record)
        try RightClickUndoStore.clear(at: file)
        #expect(RightClickUndoStore.load(at: file) == nil)
    }
}

@Test("撤销记录接受 Finder 使用的 private tmp 系统别名路径")
func rightClickUndoStoreAcceptsSystemAliasPath() throws {
    try withRightClickOperationDirectory { directory in
        let file = directory.appendingPathComponent("undo.json")
        let aliasName = "MenuTools-Alias-\(UUID()).txt"
        let canonicalDestination = URL(fileURLWithPath: "/tmp").appendingPathComponent(aliasName)
        try Data().write(to: canonicalDestination)
        defer { try? FileManager.default.removeItem(at: canonicalDestination) }
        let record = RightClickUndoRecord(kind: .rename, entries: [
            .init(
                source: "/private/tmp/original.txt",
                destination: "/private/tmp/\(aliasName)",
                destinationIdentity: .init(device: 1, inode: 2))
        ])
        try RightClickUndoStore.save(record, at: file)
        #expect(RightClickUndoStore.load(at: file) == record)
    }
}

@Test("撤销记录拒绝根目录、非规范路径和无来源的移动")
func rightClickUndoStoreRejectsUnsafePaths() throws {
    try withRightClickOperationDirectory { directory in
        let file = directory.appendingPathComponent("undo.json")
        for record in [
            RightClickUndoRecord(kind: .create, entries: [.init(source: nil, destination: "/", destinationIdentity: .init(device: 1, inode: 2))]),
            RightClickUndoRecord(kind: .copy, entries: [.init(source: nil, destination: "/tmp/../tmp/copy", destinationIdentity: .init(device: 1, inode: 2))]),
            RightClickUndoRecord(kind: .move, entries: [.init(source: nil, destination: "/tmp/moved", destinationIdentity: .init(device: 1, inode: 2))]),
            RightClickUndoRecord(kind: .move, entries: [.init(source: "/tmp/same", destination: "/tmp/same", destinationIdentity: .init(device: 1, inode: 2))]),
        ] {
            try JSONEncoder().encode(record).write(to: file, options: .atomic)
            #expect(RightClickUndoStore.load(at: file) == nil)
        }
    }
}

private func withRightClickOperationDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuTools-Operation-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
