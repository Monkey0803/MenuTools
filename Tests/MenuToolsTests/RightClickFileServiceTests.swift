import Foundation
import Testing
@testable import MenuTools

private func withRightClickDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuTools-RightClick-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test("新建文件写入模板且同名时保留原文件")
func rightClickCreatePreservesExistingFile() throws {
    try withRightClickDirectory { directory in
        let first = try RightClickFileService.createFile(in: directory, name: "README.md", data: Data("# 原文".utf8))
        let second = try RightClickFileService.createFile(in: directory, name: "README.md", data: Data("# 新文".utf8))
        #expect(first.lastPathComponent == "README.md")
        #expect(second.lastPathComponent == "README 2.md")
        #expect(try String(contentsOf: first, encoding: .utf8) == "# 原文")
        #expect(try String(contentsOf: second, encoding: .utf8) == "# 新文")
    }
}

@Test("拒绝路径穿越文件名并正确处理点文件重名")
func rightClickCreateValidatesNames() throws {
    try withRightClickDirectory { directory in
        for name in ["", ".", "..", "../outside.txt", "a/b", "a:b", "a\u{0}b"] {
            #expect(throws: (any Error).self) {
                try RightClickFileService.createFile(in: directory, name: name, data: Data())
            }
        }
        _ = try RightClickFileService.createFile(in: directory, name: ".gitignore", data: Data())
        let next = try RightClickFileService.createFile(in: directory, name: ".gitignore", data: Data())
        #expect(next.lastPathComponent == ".gitignore 2")
    }
}

@Test("新建目录保留现有目录，悬空符号链接也算重名")
func rightClickCreateHandlesDirectoriesAndDanglingLinks() throws {
    try withRightClickDirectory { directory in
        let first = try RightClickFileService.createFolder(in: directory, name: "文件夹")
        let second = try RightClickFileService.createFolder(in: directory, name: "文件夹")
        #expect(first != second)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.txt").path,
                                                  withDestinationPath: "/nonexistent/menutools-test")
        let file = try RightClickFileService.createFile(in: directory, name: "link.txt", data: Data("safe".utf8))
        #expect(file.lastPathComponent == "link 2.txt")
    }
}

@Test("文件创建失败会抛出错误而非静默成功")
func rightClickCreationReportsFailure() throws {
    try withRightClickDirectory { directory in
        #expect(throws: (any Error).self) {
            try RightClickFileService.createFile(in: directory.appendingPathComponent("missing"), name: "test.txt", data: Data())
        }
    }
}

@Test("批量复制支持保留两者与跳过且不覆盖原内容")
func rightClickTransferConflictPolicies() throws {
    try withRightClickDirectory { directory in
        let source = try RightClickFileService.createFolder(in: directory, name: "source")
        let target = try RightClickFileService.createFolder(in: directory, name: "target")
        let a = try RightClickFileService.createFile(in: source, name: "a.txt", data: Data("new".utf8))
        let b = try RightClickFileService.createFile(in: source, name: "b.txt", data: Data("b".utf8))
        let old = try RightClickFileService.createFile(in: target, name: "a.txt", data: Data("old".utf8))
        #expect(try RightClickFileService.hasConflicts(sources: [a, b], destination: target))
        let skipped = try RightClickFileService.transfer(sources: [a, b], destination: target, move: false, conflict: .skip)
        #expect(skipped.completed.count == 1)
        #expect(skipped.skipped.count == 1)
        #expect(skipped.failures.isEmpty)
        let copied = try RightClickFileService.transfer(sources: [a], destination: target, move: false, conflict: .keepBoth)
        #expect(copied.completed.first?.lastPathComponent == "a 2.txt")
        #expect(try String(contentsOf: old, encoding: .utf8) == "old")
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}

@Test("移动支持多文件且报告局部失败")
func rightClickMoveReportsPartialFailure() throws {
    try withRightClickDirectory { directory in
        let target = try RightClickFileService.createFolder(in: directory, name: "target")
        let file = try RightClickFileService.createFile(in: directory, name: "ok.txt", data: Data())
        let result = try RightClickFileService.transfer(sources: [file, directory.appendingPathComponent("missing")],
                                                      destination: target, move: true, conflict: .keepBoth)
        #expect(result.completed.count == 1)
        #expect(result.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("ok.txt").path))
    }
}

@Test("复制目录到自身或符号链接指向的子目录会在操作前拒绝")
func rightClickTransferRejectsRecursiveDestination() throws {
    try withRightClickDirectory { directory in
        let child = try RightClickFileService.createFolder(in: directory, name: "child")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        for target in [directory, child, link] {
            #expect(throws: (any Error).self) {
                try RightClickFileService.transfer(sources: [directory], destination: target, move: false, conflict: .keepBoth)
            }
        }
    }
}

@Test("SHA256 使用已知向量且支持大小写输入比对")
func rightClickSHA256KnownVector() throws {
    try withRightClickDirectory { directory in
        let file = try RightClickFileService.createFile(in: directory, name: "abc.txt", data: Data("abc".utf8))
        let hash = try RightClickFileService.sha256(file)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try RightClickFileService.normalizedSHA256(" \n" + hash.uppercased()) == hash)
        #expect(throws: (any Error).self) { try RightClickFileService.normalizedSHA256("abc") }
        #expect(throws: (any Error).self) { try RightClickFileService.sha256(directory) }
    }
}

@Test("SHA256 分块读取覆盖多块数据")
func rightClickSHA256MultipleChunks() throws {
    try withRightClickDirectory { directory in
        let file = try RightClickFileService.createFile(in: directory, name: "large", data: Data(repeating: 97, count: 1_000_000))
        #expect(try RightClickFileService.sha256(file) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

@Test("Git 根目录支持普通仓库与 worktree 的 .git 文件")
func rightClickGitRootDetection() throws {
    try withRightClickDirectory { directory in
        let source = try RightClickFileService.createFolder(in: directory, name: "Sources")
        let file = try RightClickFileService.createFile(in: source, name: "test.swift", data: Data())
        #expect(RightClickFileService.gitRoot(containing: file) == nil)
        _ = try RightClickFileService.createFile(in: directory, name: ".git", data: Data("gitdir: /tmp/example".utf8))
        #expect(RightClickFileService.gitRoot(containing: file)?.standardizedFileURL == directory.standardizedFileURL)
    }
}

@Test("Git 相对路径统一 macOS private 路径别名")
func rightClickGitRelativePathNormalizesAliases() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/MenuTools-GitAlias-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let source = try RightClickFileService.createFolder(in: directory, name: "Sources")
        let file = try RightClickFileService.createFile(in: source, name: "test.swift", data: Data())
        _ = try RightClickFileService.createFolder(in: directory, name: ".git")
        #expect(try RightClickFileService.gitRelativePath(file) == "Sources/test.swift")
    }
}
