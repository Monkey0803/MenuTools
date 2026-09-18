import CryptoKit
import Darwin
import Foundation

enum RightClickFileError: LocalizedError {
    case invalidName, invalidDirectory, recursiveDestination, regularFileRequired, invalidChecksum, noGitRoot, undoTargetChanged

    var errorDescription: String? {
        switch self {
        case .invalidName: return L("rc.error.invalidName")
        case .invalidDirectory: return L("rc.error.invalidDirectory")
        case .recursiveDestination: return L("rc.error.recursiveDestination")
        case .regularFileRequired: return L("rc.error.regularFileRequired")
        case .invalidChecksum: return L("rc.error.invalidChecksum")
        case .noGitRoot: return L("rc.error.noGitRoot")
        case .undoTargetChanged: return L("rc.error.undoTargetChanged")
        }
    }
}

enum RightClickConflictPolicy: Sendable { case skip, keepBoth }

struct RightClickTransferResult: Sendable {
    struct Completion: Sendable {
        let source: URL
        let destination: URL
    }
    struct Failure: Sendable {
        let path: String
        let message: String
    }
    var completed: [URL] = []
    var completions: [Completion] = []
    var skipped: [URL] = []
    var failures: [Failure] = []
}

/// 不依赖 AppKit 的文件操作边界；调用方负责在后台执行耗时操作与展示结果。
enum RightClickFileService {
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RightClickFileError.invalidName
        }
    }

    static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw RightClickFileError.invalidDirectory
        }
    }

    /// lstat 将悬空符号链接也视为已占用，避免写入意外的链接目标。
    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) == 0 }
    }

    static func itemIdentity(_ url: URL) -> RightClickFileIdentity? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func candidate(in directory: URL, name: String, index: Int) -> URL {
        guard index > 1 else { return directory.appendingPathComponent(name) }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let numbered = ext.isEmpty ? "\(name) \(index)" : "\(stem) \(index).\(ext)"
        return directory.appendingPathComponent(numbered)
    }

    static func createFile(in directory: URL, name: String, data: Data) throws -> URL {
        try validateName(name)
        try validateDirectory(directory)
        var index = 1
        while true {
            let url = candidate(in: directory, name: name, index: index)
            if itemExists(url) { index += 1; continue }
            do {
                // 原子占用新文件名，避免检测与写入之间的竞争覆盖其他文件。
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == NSFileWriteFileExistsError {
                    index += 1
                    continue
                }
                throw error
            }
        }
    }

    static func createFolder(in directory: URL, name: String) throws -> URL {
        try validateName(name)
        try validateDirectory(directory)
        var index = 1
        while true {
            let url = candidate(in: directory, name: name, index: index)
            let result = url.path.withCString { mkdir($0, 0o777) }
            if result == 0 { return url }
            let code = errno
            if code == EEXIST { index += 1; continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static func hasConflicts(sources: [URL], destination: URL) throws -> Bool {
        try validateTransfer(sources: sources, destination: destination)
        var names = Set<String>()
        return sources.contains { source in
            !names.insert(source.lastPathComponent).inserted
                || itemExists(destination.appendingPathComponent(source.lastPathComponent))
        }
    }

    private static func validateTransfer(sources: [URL], destination: URL) throws {
        try validateDirectory(destination)
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        for source in sources {
            let original = source.resolvingSymlinksInPath().standardizedFileURL.path
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory && (target == original || target.hasPrefix(original == "/" ? "/" : original + "/")) {
                throw RightClickFileError.recursiveDestination
            }
        }
    }

    static func transfer(sources: [URL], destination: URL, move: Bool,
                         conflict: RightClickConflictPolicy,
                         progress: @escaping (RightClickTransferProgress) -> Void = { _ in },
                         isCancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> RightClickTransferResult {
        try validateTransfer(sources: sources, destination: destination)
        var report = RightClickTransferResult()
        var seen = Set<String>()
        let uniqueSources = sources.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let sizes = uniqueSources.map(itemSize)
        let totalBytes = sizes.reduce(0, +)
        var completedBytes: Int64 = 0
        progress(.init(completedItems: 0, totalItems: uniqueSources.count, completedBytes: 0,
                       totalBytes: totalBytes, currentName: uniqueSources.first?.lastPathComponent ?? ""))
        for (offset, source) in uniqueSources.enumerated() {
            do {
                if isCancelled() { throw CancellationError() }
                let name = source.lastPathComponent
                try validateName(name)
                var index = 1
                while true {
                    let target = candidate(in: destination, name: name, index: index)
                    if itemExists(target) {
                        if conflict == .skip { report.skipped.append(source); break }
                        index += 1
                        continue
                    }
                    do {
                        try copyItem(source, to: target, baseBytes: completedBytes,
                                     totalBytes: totalBytes, completedItems: offset,
                                     totalItems: uniqueSources.count, progress: progress,
                                     isCancelled: isCancelled)
                        if move {
                            do { try FileManager.default.removeItem(at: source) }
                            catch {
                                try? FileManager.default.removeItem(at: target)
                                throw error
                            }
                        }
                        report.completed.append(target)
                        report.completions.append(.init(source: source, destination: target))
                        completedBytes += sizes[offset]
                        progress(.init(completedItems: offset + 1, totalItems: uniqueSources.count,
                                       completedBytes: completedBytes, totalBytes: totalBytes,
                                       currentName: name))
                        break
                    } catch {
                        let nsError = error as NSError
                        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError {
                            if conflict == .skip { report.skipped.append(source); break }
                            index += 1
                            continue
                        }
                        throw error
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failures.append(.init(path: source.path, message: error.localizedDescription))
            }
        }
        return report
    }

    static func undo(_ record: RightClickUndoRecord) -> RightClickTransferResult {
        if record.kind == .rename { return undoRename(record) }
        var result = RightClickTransferResult()
        for entry in record.entries.reversed() {
            let destination = URL(fileURLWithPath: entry.destination)
            do {
                guard itemExists(destination) else { throw CocoaError(.fileNoSuchFile) }
                guard itemIdentity(destination) == entry.destinationIdentity else {
                    throw RightClickFileError.undoTargetChanged
                }
                switch record.kind {
                case .create, .copy:
                    try FileManager.default.removeItem(at: destination)
                    result.completed.append(destination)
                case .move:
                    guard let sourcePath = entry.source else { throw RightClickFileError.invalidName }
                    let source = URL(fileURLWithPath: sourcePath)
                    guard !itemExists(source) else { throw CocoaError(.fileWriteFileExists) }
                    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: destination, to: source)
                    result.completed.append(source)
                case .rename:
                    throw RightClickFileError.undoTargetChanged
                }
            } catch {
                result.failures.append(.init(path: entry.destination, message: error.localizedDescription))
            }
        }
        return result
    }

    private static func undoRename(_ record: RightClickUndoRecord) -> RightClickTransferResult {
        var result = RightClickTransferResult()
        do {
            let plans = try record.entries.map { entry -> RightClickBatchRenamePlan in
                guard let sourcePath = entry.source else { throw RightClickFileError.undoTargetChanged }
                return .init(
                    source: URL(fileURLWithPath: entry.destination),
                    destination: URL(fileURLWithPath: sourcePath),
                    sourceIdentity: entry.destinationIdentity)
            }
            let completions = try RightClickBatchRenameService.apply(plans)
            result.completed = completions.map(\.destination)
            result.completions = completions
        } catch {
            result.failures.append(.init(path: record.entries.first?.destination ?? "", message: error.localizedDescription))
        }
        return result
    }

    private static func itemSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                               options: [.skipsPackageDescendants]) else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = Int64((try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).isRegularFile) == true
                                 ? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) : 0)
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private static func copyItem(_ source: URL, to target: URL, baseBytes: Int64,
                                 totalBytes: Int64, completedItems: Int, totalItems: Int,
                                 progress: @escaping (RightClickTransferProgress) -> Void,
                                 isCancelled: @escaping () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        guard let state = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(state) }
        let context = RightClickCopyCallbackContext(
            baseBytes: baseBytes, totalBytes: totalBytes, completedItems: completedItems,
            totalItems: totalItems, fallbackName: source.lastPathComponent,
            progress: progress, isCancelled: isCancelled)
        let callback: copyfile_callback_t = rightClickCopyCallback
        let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPointer) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let result = source.path.withCString { from in
            target.path.withCString { to in copyfile(from, to, state, flags) }
        }
        if result != 0 {
            try? FileManager.default.removeItem(at: target)
            if context.cancelled || isCancelled() { throw CancellationError() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
        }
        if isCancelled() {
            try? FileManager.default.removeItem(at: target)
            throw CancellationError()
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RightClickFileError.regularFileRequired
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedSHA256(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RightClickFileError.invalidChecksum
        }
        return value
    }

    static func gitRelativePath(_ url: URL) throws -> String {
        let normalized = url.standardizedFileURL
        guard let root = gitRoot(containing: normalized) else { throw RightClickFileError.noGitRoot }
        return RightClickPathFormatter.relativePath(path: normalized.path, base: root.path)
    }

    static func gitRoot(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        if (try? current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            current.deleteLastPathComponent()
        }
        while true {
            if itemExists(current.appendingPathComponent(".git")) { return current }
            // Foundation 在根 URL 上继续删除路径分量可能产生空路径；必须显式终止。
            if current.path == "/" || current.path.isEmpty { return nil }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}

private final class RightClickCopyCallbackContext {
    let baseBytes: Int64
    let totalBytes: Int64
    let completedItems: Int
    let totalItems: Int
    let fallbackName: String
    let progress: (RightClickTransferProgress) -> Void
    let isCancelled: () -> Bool
    var currentPath = ""
    var priorFilesBytes: Int64 = 0
    var currentFileBytes: Int64 = 0
    var cancelled = false

    init(baseBytes: Int64, totalBytes: Int64, completedItems: Int, totalItems: Int,
         fallbackName: String, progress: @escaping (RightClickTransferProgress) -> Void,
         isCancelled: @escaping () -> Bool) {
        self.baseBytes = baseBytes
        self.totalBytes = totalBytes
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.fallbackName = fallbackName
        self.progress = progress
        self.isCancelled = isCancelled
    }
}

private func rightClickCopyCallback(
    _ what: Int32, _ stage: Int32, _ state: copyfile_state_t?,
    _ source: UnsafePointer<CChar>?, _ destination: UnsafePointer<CChar>?,
    _ rawContext: UnsafeMutableRawPointer?
) -> Int32 {
    guard let rawContext else { return Int32(COPYFILE_QUIT) }
    let context = Unmanaged<RightClickCopyCallbackContext>.fromOpaque(rawContext).takeUnretainedValue()
    if context.isCancelled() {
        context.cancelled = true
        return Int32(COPYFILE_QUIT)
    }
    guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state else {
        return Int32(COPYFILE_CONTINUE)
    }
    let path = source.map(String.init(cString:)) ?? context.fallbackName
    var copied: off_t = 0
    guard copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 else {
        return Int32(COPYFILE_CONTINUE)
    }
    if context.currentPath != path {
        context.priorFilesBytes += context.currentFileBytes
        context.currentFileBytes = 0
        context.currentPath = path
    }
    context.currentFileBytes = max(context.currentFileBytes, Int64(copied))
    context.progress(.init(
        completedItems: context.completedItems, totalItems: context.totalItems,
        completedBytes: min(context.totalBytes, context.baseBytes + context.priorFilesBytes + context.currentFileBytes),
        totalBytes: context.totalBytes,
        currentName: (path as NSString).lastPathComponent
    ))
    return Int32(COPYFILE_CONTINUE)
}
