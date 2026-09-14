import ApplicationServices
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
    /// 只在窗口标题包含该字符串时应用；nil 表示不限制标题。
    var windowTitleContains: String?
    /// 只作用于该应用的首个（主）窗口：焦点在工具面板/次窗口上时不套用。
    var firstWindowOnly: Bool

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        applicationName: String,
        layout: WindowLayout,
        isEnabled: Bool = true,
        windowTitleContains: String? = nil,
        firstWindowOnly: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.layout = layout
        self.isEnabled = isEnabled
        self.windowTitleContains = windowTitleContains
        self.firstWindowOnly = firstWindowOnly
    }

    func settingEnabled(_ enabled: Bool) -> WindowApplicationRule {
        var copy = self
        copy.isEnabled = enabled
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case applicationName
        case layout
        case isEnabled
        case windowTitleContains
        case firstWindowOnly
    }

    /// 逐字段解码：旧版本规则没有标题过滤字段，不能因此让整份配置失效。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            applicationName: try container.decode(String.self, forKey: .applicationName),
            layout: try container.decode(WindowLayout.self, forKey: .layout),
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            windowTitleContains: try container.decodeIfPresent(String.self, forKey: .windowTitleContains),
            firstWindowOnly: try container.decodeIfPresent(Bool.self, forKey: .firstWindowOnly) ?? false
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(applicationName, forKey: .applicationName)
        try container.encode(layout, forKey: .layout)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(windowTitleContains, forKey: .windowTitleContains)
        try container.encode(firstWindowOnly, forKey: .firstWindowOnly)
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
    /// 吸附到新的落点区域时给出触觉反馈。
    var hapticFeedbackOnSnap: Bool
    /// 把已经吸附的窗口拖出来时，恢复吸附前的尺寸。
    var restoreSizeWhenDraggingOut: Bool
    /// 使用更细的吸附区域（Rectangle 风格）：顶边→最大化、底边三分区、边缘靠上下角→上下半屏。
    var detailedSnapAreas: Bool
    /// 用户自定义的吸附区域动作：只保存与内置默认不同的部分。
    var snapAreaMapping: WindowSnapAreaMapping

    init(
        options: WindowManagerOptions = WindowManagerOptions(),
        presets: [WindowLayoutPreset] = [],
        applicationRules: [WindowApplicationRule] = [],
        excludedBundleIdentifiers: [String] = [],
        automaticApplicationRules: Bool = false,
        edgeSnappingEnabled: Bool = false,
        cycleLayouts: Bool = true,
        showSnapPreview: Bool = true,
        traverseDisplaysOnRepeat: Bool = false,
        hapticFeedbackOnSnap: Bool = true,
        restoreSizeWhenDraggingOut: Bool = true,
        detailedSnapAreas: Bool = false,
        snapAreaMapping: WindowSnapAreaMapping = WindowSnapAreaMapping()
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
        self.hapticFeedbackOnSnap = hapticFeedbackOnSnap
        self.restoreSizeWhenDraggingOut = restoreSizeWhenDraggingOut
        self.detailedSnapAreas = detailedSnapAreas
        self.snapAreaMapping = snapAreaMapping
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
        case hapticFeedbackOnSnap
        case restoreSizeWhenDraggingOut
        case detailedSnapAreas
        case snapAreaMapping
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
            traverseDisplaysOnRepeat: try container.decodeIfPresent(Bool.self, forKey: .traverseDisplaysOnRepeat) ?? fallback.traverseDisplaysOnRepeat,
            hapticFeedbackOnSnap: try container.decodeIfPresent(Bool.self, forKey: .hapticFeedbackOnSnap) ?? fallback.hapticFeedbackOnSnap,
            restoreSizeWhenDraggingOut: try container.decodeIfPresent(Bool.self, forKey: .restoreSizeWhenDraggingOut) ?? fallback.restoreSizeWhenDraggingOut,
            detailedSnapAreas: try container.decodeIfPresent(Bool.self, forKey: .detailedSnapAreas) ?? fallback.detailedSnapAreas,
            snapAreaMapping: try container.decodeIfPresent(WindowSnapAreaMapping.self, forKey: .snapAreaMapping) ?? fallback.snapAreaMapping
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
        try container.encode(hapticFeedbackOnSnap, forKey: .hapticFeedbackOnSnap)
        try container.encode(restoreSizeWhenDraggingOut, forKey: .restoreSizeWhenDraggingOut)
        try container.encode(detailedSnapAreas, forKey: .detailedSnapAreas)
        try container.encode(snapAreaMapping, forKey: .snapAreaMapping)
    }
}

enum WindowSnapResolver {
    /// 光标落在哪个吸附区域；不在任何吸附区域内时返回 nil。
    static func area(
        for point: CGPoint,
        in screen: CGRect,
        threshold: CGFloat,
        detailed: Bool = false
    ) -> WindowSnapArea? {
        guard screen.contains(point) || expanded(screen, by: threshold).contains(point) else { return nil }

        let nearLeft = point.x <= screen.minX + threshold
        let nearRight = point.x >= screen.maxX - threshold
        let nearTop = point.y >= screen.maxY - threshold
        let nearBottom = point.y <= screen.minY + threshold

        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }

        guard detailed else {
            if nearTop { return .top }
            if nearBottom { return .bottom }
            if nearLeft { return .left }
            if nearRight { return .right }
            return nil
        }

        // 精细模型（Rectangle 风格）：顶边给最大化，底边按左/中/右三分区，
        // 上下半屏改由左右边缘的上/下三分之一区域提供。
        if nearTop { return .top }
        if nearBottom {
            let third = screen.width / 3
            if point.x <= screen.minX + third { return .bottomLeftThird }
            if point.x >= screen.maxX - third { return .bottomRightThird }
            return .bottomCenterThird
        }
        if nearLeft || nearRight {
            let band = screen.height / 3
            if point.y >= screen.maxY - band { return nearLeft ? .leftUpperThird : .rightUpperThird }
            if point.y <= screen.minY + band { return nearLeft ? .leftLowerThird : .rightLowerThird }
            return nearLeft ? .left : .right
        }
        return nil
    }

    /// 窗口边缘贴住屏幕时落在哪个吸附区域。
    static func area(
        pressedWindowFrame frame: CGRect,
        in screen: CGRect,
        threshold: CGFloat,
        detailed: Bool = false
    ) -> WindowSnapArea? {
        guard screen.width > 0, screen.height > 0 else { return nil }

        // 用 2 倍阈值判断“几乎占满某个轴”：半屏窗口的高度其实已经接近屏幕高度
        //（只差屏幕边距），如果不排除，它的下边缘会被误判成“贴住屏幕下边缘”。
        let spansWidth = frame.width >= screen.width - threshold * 2
        let spansHeight = frame.height >= screen.height - threshold * 2
        guard !(spansWidth && spansHeight) else { return nil }

        let nearLeft = !spansWidth && frame.minX <= screen.minX + threshold
        let nearRight = !spansWidth && frame.maxX >= screen.maxX - threshold
        let nearTop = !spansHeight && frame.maxY >= screen.maxY - threshold
        let nearBottom = !spansHeight && frame.minY <= screen.minY + threshold

        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }

        guard detailed else {
            if nearTop { return .top }
            if nearBottom { return .bottom }
            if nearLeft { return .left }
            if nearRight { return .right }
            return nil
        }

        // 与光标版同一套精细模型，只是用窗口中心判断落在哪一列/哪一行。
        if nearTop { return .top }
        if nearBottom {
            let third = screen.width / 3
            if frame.midX <= screen.minX + third { return .bottomLeftThird }
            if frame.midX >= screen.maxX - third { return .bottomRightThird }
            return .bottomCenterThird
        }
        if nearLeft || nearRight {
            let band = screen.height / 3
            if frame.midY >= screen.maxY - band { return nearLeft ? .leftUpperThird : .rightUpperThird }
            if frame.midY <= screen.minY + band { return nearLeft ? .leftLowerThird : .rightLowerThird }
            return nearLeft ? .left : .right
        }
        return nil
    }

    /// 按吸附区域对应的布局动作求解；用户可以自定义每个区域的动作用的是哪个布局。
    static func layout(
        for point: CGPoint,
        in screen: CGRect,
        threshold: CGFloat,
        detailed: Bool = false,
        mapping: WindowSnapAreaMapping = WindowSnapAreaMapping()
    ) -> WindowLayout? {
        area(for: point, in: screen, threshold: threshold, detailed: detailed)
            .map { mapping.action(for: $0, detailed: detailed) }
    }

    static func layout(
        pressedWindowFrame frame: CGRect,
        in screen: CGRect,
        threshold: CGFloat,
        detailed: Bool = false,
        mapping: WindowSnapAreaMapping = WindowSnapAreaMapping()
    ) -> WindowLayout? {
        area(pressedWindowFrame: frame, in: screen, threshold: threshold, detailed: detailed)
            .map { mapping.action(for: $0, detailed: detailed) }
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

/// 吸附区域方向。与具体布局解耦：用户可以把任意区域改成任意布局。
enum WindowSnapArea: String, CaseIterable, Codable, Sendable {
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case bottomLeftThird
    case bottomCenterThird
    case bottomRightThird
    case leftUpperThird
    case leftLowerThird
    case rightUpperThird
    case rightLowerThird

    /// 设置页里可自定义的区域。精细模型独有的分区沿用内置动作，避免设置页过长。
    static let customizable: [WindowSnapArea] = [
        .left, .right, .top, .bottom,
        .topLeft, .topRight, .bottomLeft, .bottomRight
    ]

    var titleKey: String { "window.snapArea.\(rawValue)" }

    /// 默认模型下该区域的内置动作。
    var builtInLayout: WindowLayout {
        switch self {
        case .left: return .leftHalf
        case .right: return .rightHalf
        case .top: return .topHalf
        case .bottom, .bottomCenterThird: return .bottomHalf
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .bottomLeftThird: return .firstThird
        case .bottomRightThird: return .lastThird
        case .leftUpperThird, .rightUpperThird: return .topHalf
        case .leftLowerThird, .rightLowerThird: return .bottomHalf
        }
    }

    /// 精细模型下该区域的内置动作（只有顶边与默认模型不同）。
    var detailedBuiltInLayout: WindowLayout {
        self == .top ? .maximize : builtInLayout
    }
}

/// 用户对吸附区域的覆盖：只保存与内置默认不同的部分。
struct WindowSnapAreaMapping: Equatable, Sendable {
    private(set) var overrides: [WindowSnapArea: WindowLayout]

    init(overrides: [WindowSnapArea: WindowLayout] = [:]) {
        self.overrides = overrides
    }

    var isEmpty: Bool { overrides.isEmpty }

    func override(for area: WindowSnapArea) -> WindowLayout? { overrides[area] }

    func action(for area: WindowSnapArea, detailed: Bool) -> WindowLayout {
        if let override = overrides[area] { return override }
        return detailed ? area.detailedBuiltInLayout : area.builtInLayout
    }

    mutating func setOverride(_ layout: WindowLayout?, for area: WindowSnapArea) {
        if let layout {
            overrides[area] = layout
        } else {
            overrides[area] = nil
        }
    }

    mutating func removeAll() { overrides.removeAll() }
}

extension WindowSnapAreaMapping: Codable {
    /// 宽容解码：认不出的区域或布局直接忽略，不让整份配置失效。
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: String].self)) ?? [:]
        var overrides: [WindowSnapArea: WindowLayout] = [:]
        for (areaName, layoutName) in raw {
            guard let area = WindowSnapArea(rawValue: areaName),
                  let layout = WindowLayout(rawValue: layoutName) else { continue }
            overrides[area] = layout
        }
        self.init(overrides: overrides)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.rawValue) })
        try container.encode(raw)
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
        windowTitle: String? = nil,
        rules: [WindowApplicationRule],
        excludedBundleIdentifiers: [String]
    ) -> WindowLayout? {
        guard !excludedBundleIdentifiers.contains(bundleIdentifier) else { return nil }
        return rules.first { rule in
            guard rule.bundleIdentifier == bundleIdentifier, rule.isEnabled else { return false }
            guard let filter = rule.windowTitleContains, !filter.isEmpty else { return true }
            guard let windowTitle else { return false }
            return windowTitle.localizedCaseInsensitiveContains(filter)
        }?.layout
    }

    /// 「只作用于首个（主）窗口」的判定。
    ///
    /// 取不到主窗口信息时按「是主窗口」处理：宁可多套用一次，也不要让规则静默失效。
    static func shouldApplyToFocusedWindow(isMainWindow: Bool, firstWindowOnly: Bool) -> Bool {
        !firstWindowOnly || isMainWindow
    }

    /// 自动应用规则时跳过弹窗、系统对话框和表单。
    ///
    /// 这些窗口的「窗口」语义很弱，把保存对话框拉成半屏只会碍事。
    static func shouldSkipAutomaticLayout(role: String?, subrole: String?) -> Bool {
        if role == kAXSheetRole { return true }
        switch subrole {
        case kAXDialogSubrole, kAXSystemDialogSubrole: return true
        default: return false
        }
    }
}
