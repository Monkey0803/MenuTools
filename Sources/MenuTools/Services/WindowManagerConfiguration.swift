import CoreGraphics
import Foundation

/// 窗口布局的几何参数。数值统一使用点（point）。
struct WindowManagerOptions: Codable, Equatable, Sendable {
    var screenPadding: CGFloat
    var windowGap: CGFloat
    var snapDistance: CGFloat
    var defaultWindowWidth: CGFloat
    var defaultWindowHeight: CGFloat
    /// 方向键挪动窗口的步长；按住 Option 时按 `WindowNudge` 的规则精调。
    var nudgeStep: CGFloat

    init(
        screenPadding: CGFloat = 8,
        windowGap: CGFloat = 8,
        snapDistance: CGFloat = 24,
        defaultWindowWidth: CGFloat = 900,
        defaultWindowHeight: CGFloat = 650,
        nudgeStep: CGFloat = 20
    ) {
        self.screenPadding = max(0, screenPadding)
        self.windowGap = max(0, windowGap)
        self.snapDistance = max(1, snapDistance)
        self.defaultWindowWidth = max(1, defaultWindowWidth)
        self.defaultWindowHeight = max(1, defaultWindowHeight)
        self.nudgeStep = max(1, nudgeStep)
    }

    var defaultWindowSize: CGSize {
        CGSize(width: defaultWindowWidth, height: defaultWindowHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case screenPadding
        case windowGap
        case snapDistance
        case defaultWindowWidth
        case defaultWindowHeight
        case nudgeStep
    }

    /// 逐字段解码：旧版本写入的配置缺少新增字段时回落到默认值，而不是让整份配置失效。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WindowManagerOptions()
        self.init(
            screenPadding: try container.decodeIfPresent(CGFloat.self, forKey: .screenPadding) ?? fallback.screenPadding,
            windowGap: try container.decodeIfPresent(CGFloat.self, forKey: .windowGap) ?? fallback.windowGap,
            snapDistance: try container.decodeIfPresent(CGFloat.self, forKey: .snapDistance) ?? fallback.snapDistance,
            defaultWindowWidth: try container.decodeIfPresent(CGFloat.self, forKey: .defaultWindowWidth) ?? fallback.defaultWindowWidth,
            defaultWindowHeight: try container.decodeIfPresent(CGFloat.self, forKey: .defaultWindowHeight) ?? fallback.defaultWindowHeight,
            nudgeStep: try container.decodeIfPresent(CGFloat.self, forKey: .nudgeStep) ?? fallback.nudgeStep
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screenPadding, forKey: .screenPadding)
        try container.encode(windowGap, forKey: .windowGap)
        try container.encode(snapDistance, forKey: .snapDistance)
        try container.encode(defaultWindowWidth, forKey: .defaultWindowWidth)
        try container.encode(defaultWindowHeight, forKey: .defaultWindowHeight)
        try container.encode(nudgeStep, forKey: .nudgeStep)
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

    /// 是否记录了固定尺寸（而不是只引用某个布局）。
    var hasCustomFrame: Bool { frame != nil }
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
    /// 连按同一快捷键时在同一分数族内循环（对齐 Rectangle 的三分循环）。
    var cycleLayouts: Bool
    /// 拖动窗口靠近屏幕边缘时显示落点预览。
    var showSnapPreview: Bool
    /// 连按半屏布局时把窗口带到相邻显示器。
    var traverseDisplaysOnRepeat: Bool

    init(
        options: WindowManagerOptions = WindowManagerOptions(),
        presets: [WindowLayoutPreset] = [],
        applicationRules: [WindowApplicationRule] = [],
        excludedBundleIdentifiers: [String] = [],
        automaticApplicationRules: Bool = false,
        edgeSnappingEnabled: Bool = false,
        cycleLayouts: Bool = true,
        showSnapPreview: Bool = true,
        traverseDisplaysOnRepeat: Bool = false
    ) {
        self.options = options
        self.presets = presets
        self.applicationRules = applicationRules
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.automaticApplicationRules = automaticApplicationRules
        self.edgeSnappingEnabled = edgeSnappingEnabled
        self.cycleLayouts = cycleLayouts
        self.showSnapPreview = showSnapPreview
        self.traverseDisplaysOnRepeat = traverseDisplaysOnRepeat
    }

    private enum CodingKeys: String, CodingKey {
        case options
        case presets
        case applicationRules
        case excludedBundleIdentifiers
        case automaticApplicationRules
        case edgeSnappingEnabled
        case cycleLayouts
        case showSnapPreview
        case traverseDisplaysOnRepeat
    }

    /// 顶层同样逐字段解码：新增开关不会让旧配置整份丢失。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WindowManagerConfiguration()
        self.init(
            options: try container.decodeIfPresent(WindowManagerOptions.self, forKey: .options) ?? fallback.options,
            presets: try container.decodeIfPresent([WindowLayoutPreset].self, forKey: .presets) ?? fallback.presets,
            applicationRules: try container.decodeIfPresent([WindowApplicationRule].self, forKey: .applicationRules) ?? fallback.applicationRules,
            excludedBundleIdentifiers: try container.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? fallback.excludedBundleIdentifiers,
            automaticApplicationRules: try container.decodeIfPresent(Bool.self, forKey: .automaticApplicationRules) ?? fallback.automaticApplicationRules,
            edgeSnappingEnabled: try container.decodeIfPresent(Bool.self, forKey: .edgeSnappingEnabled) ?? fallback.edgeSnappingEnabled,
            cycleLayouts: try container.decodeIfPresent(Bool.self, forKey: .cycleLayouts) ?? fallback.cycleLayouts,
            showSnapPreview: try container.decodeIfPresent(Bool.self, forKey: .showSnapPreview) ?? fallback.showSnapPreview,
            traverseDisplaysOnRepeat: try container.decodeIfPresent(Bool.self, forKey: .traverseDisplaysOnRepeat) ?? fallback.traverseDisplaysOnRepeat
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(options, forKey: .options)
        try container.encode(presets, forKey: .presets)
        try container.encode(applicationRules, forKey: .applicationRules)
        try container.encode(excludedBundleIdentifiers, forKey: .excludedBundleIdentifiers)
        try container.encode(automaticApplicationRules, forKey: .automaticApplicationRules)
        try container.encode(edgeSnappingEnabled, forKey: .edgeSnappingEnabled)
        try container.encode(cycleLayouts, forKey: .cycleLayouts)
        try container.encode(showSnapPreview, forKey: .showSnapPreview)
        try container.encode(traverseDisplaysOnRepeat, forKey: .traverseDisplaysOnRepeat)
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

    /// 按鼠标位置定位显示器。
    ///
    /// 判定顺序：先用完整屏幕范围（含 1pt 容差，否则 `CGRect.contains` 的半开区间会漏掉
    /// 顶边/右边这类常见释放点），再对显示器之间的死区回落到最近的显示器。
    static func screenIndex(
        for point: CGPoint,
        screens: [CGRect],
        edgeTolerance: CGFloat = 1,
        nearestLimit: CGFloat = 200
    ) -> Int? {
        guard !screens.isEmpty else { return nil }

        for (index, screen) in screens.enumerated()
        where expanded(screen, by: edgeTolerance).contains(point) {
            return index
        }

        let nearest = screens.enumerated()
            .map { (index: $0.offset, distance: distance(from: point, to: $0.element)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= nearestLimit else { return nil }
        return nearest.index
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
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
