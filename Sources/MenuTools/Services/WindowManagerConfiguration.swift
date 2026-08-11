import CoreGraphics
import Foundation

/// 窗口布局的几何参数。数值统一使用点（point）。
struct WindowManagerOptions: Codable, Equatable, Sendable {
    var screenPadding: CGFloat
    var windowGap: CGFloat
    var snapDistance: CGFloat
    var defaultWindowWidth: CGFloat
    var defaultWindowHeight: CGFloat

    init(
        screenPadding: CGFloat = 8,
        windowGap: CGFloat = 8,
        snapDistance: CGFloat = 24,
        defaultWindowWidth: CGFloat = 900,
        defaultWindowHeight: CGFloat = 650
    ) {
        self.screenPadding = max(0, screenPadding)
        self.windowGap = max(0, windowGap)
        self.snapDistance = max(1, snapDistance)
        self.defaultWindowWidth = max(1, defaultWindowWidth)
        self.defaultWindowHeight = max(1, defaultWindowHeight)
    }

    var defaultWindowSize: CGSize {
        CGSize(width: defaultWindowWidth, height: defaultWindowHeight)
    }
}

struct WindowLayoutPreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var layout: WindowLayout
    var frame: CGRect?

    init(id: UUID = UUID(), name: String, layout: WindowLayout, frame: CGRect? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.frame = frame
    }
}

struct WindowApplicationRule: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    var applicationName: String
    var layout: WindowLayout
    var isEnabled: Bool

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        applicationName: String,
        layout: WindowLayout,
        isEnabled: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.layout = layout
        self.isEnabled = isEnabled
    }

    func settingEnabled(_ enabled: Bool) -> WindowApplicationRule {
        var copy = self
        copy.isEnabled = enabled
        return copy
    }
}

struct WindowManagerConfiguration: Codable, Equatable, Sendable {
    var options: WindowManagerOptions
    var presets: [WindowLayoutPreset]
    var applicationRules: [WindowApplicationRule]
    var excludedBundleIdentifiers: [String]
    var automaticApplicationRules: Bool
    var edgeSnappingEnabled: Bool

    init(
        options: WindowManagerOptions = WindowManagerOptions(),
        presets: [WindowLayoutPreset] = [],
        applicationRules: [WindowApplicationRule] = [],
        excludedBundleIdentifiers: [String] = [],
        automaticApplicationRules: Bool = false,
        edgeSnappingEnabled: Bool = false
    ) {
        self.options = options
        self.presets = presets
        self.applicationRules = applicationRules
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.automaticApplicationRules = automaticApplicationRules
        self.edgeSnappingEnabled = edgeSnappingEnabled
    }
}

enum WindowSnapResolver {
    static func layout(for point: CGPoint, in screen: CGRect, threshold: CGFloat) -> WindowLayout? {
        guard screen.contains(point) || expanded(screen, by: threshold).contains(point) else { return nil }

        let nearLeft = point.x <= screen.minX + threshold
        let nearRight = point.x >= screen.maxX - threshold
        let nearTop = point.y >= screen.maxY - threshold
        let nearBottom = point.y <= screen.minY + threshold

        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if nearTop { return .topHalf }
        if nearBottom { return .bottomHalf }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        return nil
    }

    private static func expanded(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        rect.insetBy(dx: -amount, dy: -amount)
    }
}

enum WindowArrangementCalculator {
    static func frames(for count: Int, in screen: CGRect, options: WindowManagerOptions) -> [CGRect] {
        guard count > 0 else { return [] }

        let columns: Int
        switch count {
        case 1...3:
            columns = count
        default:
            columns = max(1, Int(ceil(sqrt(Double(count)))))
        }
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let safe = screen.insetBy(dx: options.screenPadding, dy: options.screenPadding)
        let gap = options.windowGap
        let cellWidth = (safe.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (safe.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            return CGRect(
                x: safe.minX + CGFloat(column) * (cellWidth + gap),
                y: safe.maxY - CGFloat(row + 1) * cellHeight - CGFloat(row) * gap,
                width: cellWidth,
                height: cellHeight
            )
        }
    }
}

enum WindowApplicationRuleResolver {
    static func layout(
        for bundleIdentifier: String,
        rules: [WindowApplicationRule],
        excludedBundleIdentifiers: [String]
    ) -> WindowLayout? {
        guard !excludedBundleIdentifiers.contains(bundleIdentifier) else { return nil }
        return rules.first { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled }?.layout
    }
}
