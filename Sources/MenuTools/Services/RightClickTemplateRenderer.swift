import Foundation

enum RightClickTemplateRenderer {
    struct Context: Sendable {
        var directory: URL
        var date: Date
        var timeZone: TimeZone
        var projectName: String?
        var uuid: String = UUID().uuidString.lowercased()
        var clipboard: String = ""
        var prompts: [String: String] = [:]
    }

    static func render(_ template: String, context: Context) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = context.timeZone
        func value(_ format: String) -> String {
            dateFormatter.dateFormat = format
            return dateFormatter.string(from: context.date)
        }
        let replacements = [
            "{{datetime}}": value("yyyy-MM-dd_HH-mm-ss"),
            "{{date}}": value("yyyy-MM-dd"),
            "{{time}}": value("HH-mm-ss"),
            "{{directory}}": context.directory.lastPathComponent,
            "{{project}}": context.projectName ?? context.directory.lastPathComponent,
            "{{uuid}}": context.uuid,
            "{{clipboard}}": context.clipboard
        ]
        var output = template
        for token in ["{{datetime}}", "{{date}}", "{{time}}", "{{directory}}", "{{project}}", "{{uuid}}", "{{clipboard}}"] {
            output = output.replacingOccurrences(of: token, with: replacements[token]!)
        }
        if let expression = try? NSRegularExpression(pattern: #"\{\{prompt:([^{}]{1,64})\}\}"#) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in expression.matches(in: output, range: range).reversed() {
                guard let nameRange = Range(match.range(at: 1), in: output),
                      let fullRange = Range(match.range, in: output) else { continue }
                let name = String(output[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = context.prompts[name] { output.replaceSubrange(fullRange, with: value) }
            }
        }
        return output
    }

    static func promptNames(in templates: [String]) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\{\{prompt:([^{}]{1,64})\}\}"#) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for template in templates {
            let range = NSRange(template.startIndex..<template.endIndex, in: template)
            for match in expression.matches(in: template, range: range) {
                guard let matchRange = Range(match.range(at: 1), in: template) else { continue }
                let name = String(template[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                result.append(name)
            }
        }
        return result
    }
}
