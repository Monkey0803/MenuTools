import Foundation

enum RightClickBatchRenameRule: Sendable {
    case regex(pattern: String, replacement: String)
    case sequence(start: Int)
    case datePrefix(Date, TimeZone)
    case `extension`(String)
}

enum RightClickBatchRenameError: LocalizedError, Equatable, Sendable {
    case invalidRule
    case noChanges
    case conflict(String)
    case sourceChanged(String)

    var errorDescription: String? {
        switch self {
        case .invalidRule: return L("rc.rename.error.invalidRule")
        case .noChanges: return L("rc.rename.error.noChanges")
        case .conflict(let name): return L("rc.rename.error.conflict", name)
        case .sourceChanged(let name): return L("rc.rename.error.sourceChanged", name)
        }
    }
}

struct RightClickBatchRenamePlan: Equatable, Sendable {
    var source: URL
    var destination: URL
    var sourceIdentity: RightClickFileIdentity
}

enum RightClickBatchRenameService {
    static func plan(_ urls: [URL], rule: RightClickBatchRenameRule) throws -> [RightClickBatchRenamePlan] {
        guard !urls.isEmpty, urls.count <= 1_000 else { throw RightClickBatchRenameError.invalidRule }
        let expression: NSRegularExpression?
        if case .regex(let pattern, let replacement) = rule {
            guard !pattern.isEmpty else { throw RightClickBatchRenameError.invalidRule }
            do {
                let compiled = try NSRegularExpression(pattern: pattern)
                guard replacementCaptureGroupsAreValid(
                    replacement, maximumGroup: compiled.numberOfCaptureGroups
                ) else { throw RightClickBatchRenameError.invalidRule }
                expression = compiled
            }
            catch { throw RightClickBatchRenameError.invalidRule }
        } else {
            expression = nil
        }
        if case .sequence(let start) = rule, start < 0 { throw RightClickBatchRenameError.invalidRule }
        let convertedExtension: String?
        if case .extension(let value) = rule {
            let ext = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !ext.isEmpty, ext.utf8.count <= 32,
                  ext.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
                throw RightClickBatchRenameError.invalidRule
            }
            convertedExtension = ext
        } else {
            convertedExtension = nil
        }

        let unique = Dictionary(grouping: urls, by: { $0.standardizedFileURL.path })
        guard unique.values.allSatisfy({ $0.count == 1 }) else { throw RightClickBatchRenameError.invalidRule }
        let sourcePaths = Set(urls.map { $0.standardizedFileURL.path })
        let width: Int
        if case .sequence(let start) = rule {
            width = max(2, String(start + urls.count - 1).count)
        } else { width = 0 }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var destinations = Set<String>()
        var plans: [RightClickBatchRenamePlan] = []
        for (index, source) in urls.enumerated() {
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                throw RightClickBatchRenameError.invalidRule
            }
            guard let identity = RightClickFileService.itemIdentity(source) else {
                throw RightClickBatchRenameError.sourceChanged(source.lastPathComponent)
            }
            let oldName = source.lastPathComponent
            let newName: String
            switch rule {
            case .regex(_, let replacement):
                let range = NSRange(oldName.startIndex..<oldName.endIndex, in: oldName)
                newName = expression?.stringByReplacingMatches(
                    in: oldName, range: range, withTemplate: replacement) ?? oldName
            case .sequence(let start):
                let parts = nameParts(oldName)
                let number = String(format: "%0*d", width, start + index)
                newName = parts.extension.isEmpty
                    ? "\(parts.stem) \(number)"
                    : "\(parts.stem) \(number).\(parts.extension)"
            case .datePrefix(let date, let timeZone):
                dateFormatter.timeZone = timeZone
                newName = dateFormatter.string(from: date) + "_" + oldName
            case .extension:
                let parts = nameParts(oldName)
                newName = parts.stem + "." + (convertedExtension ?? "")
            }
            try RightClickFileService.validateName(newName)
            let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
            if destination.path == source.path { continue }
            let collisionKey = destination.standardizedFileURL.path.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard destinations.insert(collisionKey).inserted else {
                throw RightClickBatchRenameError.conflict(newName)
            }
            if RightClickFileService.itemExists(destination),
               !sourcePaths.contains(destination.standardizedFileURL.path),
               source.path.caseInsensitiveCompare(destination.path) != .orderedSame {
                throw RightClickBatchRenameError.conflict(newName)
            }
            plans.append(.init(source: source, destination: destination, sourceIdentity: identity))
        }
        guard !plans.isEmpty else { throw RightClickBatchRenameError.noChanges }
        let renamedSourceKeys = Set(plans.map { pathKey($0.source) })
        for plan in plans where RightClickFileService.itemExists(plan.destination) {
            if !renamedSourceKeys.contains(pathKey(plan.destination)),
               plan.source.path.caseInsensitiveCompare(plan.destination.path) != .orderedSame {
                throw RightClickBatchRenameError.conflict(plan.destination.lastPathComponent)
            }
        }
        return plans
    }

    static func apply(_ plans: [RightClickBatchRenamePlan]) throws -> [RightClickTransferResult.Completion] {
        guard !plans.isEmpty else { throw RightClickBatchRenameError.noChanges }
        for plan in plans {
            guard RightClickFileService.itemIdentity(plan.source) == plan.sourceIdentity else {
                throw RightClickBatchRenameError.sourceChanged(plan.source.lastPathComponent)
            }
        }
        var staged: [(RightClickBatchRenamePlan, URL)] = []
        do {
            for plan in plans {
                let temporary = try unusedTemporaryURL(in: plan.source.deletingLastPathComponent())
                try FileManager.default.moveItem(at: plan.source, to: temporary)
                staged.append((plan, temporary))
            }
        } catch {
            for (plan, temporary) in staged.reversed() {
                try? FileManager.default.moveItem(at: temporary, to: plan.source)
            }
            throw error
        }

        var completed: [(RightClickBatchRenamePlan, URL)] = []
        do {
            for (plan, temporary) in staged {
                if RightClickFileService.itemExists(plan.destination) {
                    throw RightClickBatchRenameError.conflict(plan.destination.lastPathComponent)
                }
                try FileManager.default.moveItem(at: temporary, to: plan.destination)
                completed.append((plan, temporary))
            }
        } catch {
            for (plan, temporary) in completed.reversed() {
                try? FileManager.default.moveItem(at: plan.destination, to: temporary)
            }
            for (plan, temporary) in staged.reversed() where RightClickFileService.itemExists(temporary) {
                try? FileManager.default.moveItem(at: temporary, to: plan.source)
            }
            throw error
        }
        return plans.map { .init(source: $0.source, destination: $0.destination) }
    }

    private static func nameParts(_ name: String) -> (stem: String, `extension`: String) {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        return ext.isEmpty ? (name, "") : (nsName.deletingPathExtension, ext)
    }

    private static func unusedTemporaryURL(in directory: URL) throws -> URL {
        for _ in 0..<100 {
            let url = directory.appendingPathComponent(".menutools-rename-\(UUID().uuidString)")
            if !RightClickFileService.itemExists(url) { return url }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func replacementCaptureGroupsAreValid(
        _ replacement: String, maximumGroup: Int
    ) -> Bool {
        let characters = Array(replacement)
        var index = 0
        while index < characters.count {
            if characters[index] == "\\" {
                index += min(2, characters.count - index)
                continue
            }
            guard characters[index] == "$" else {
                index += 1
                continue
            }
            var cursor = index + 1
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }
            if !digits.isEmpty, (Int(digits) ?? maximumGroup + 1) > maximumGroup {
                return false
            }
            index = max(cursor, index + 1)
        }
        return true
    }
}
