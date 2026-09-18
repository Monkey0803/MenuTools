import SwiftUI

/// 点击与拖动共用落点规则；越界时停在首尾，取消手势时由视图恢复原选中位置。
enum MenuPanelCategoryDragLayout {
    static let inset: CGFloat = 4

    static func segmentWidth(in width: CGFloat) -> CGFloat {
        max(width - inset * 2, 0) / CGFloat(MenuPanelCategory.allCases.count)
    }

    static func center(for category: MenuPanelCategory, width: CGFloat) -> CGFloat {
        let index = MenuPanelCategory.allCases.firstIndex(of: category) ?? 0
        return inset + segmentWidth(in: width) * (CGFloat(index) + 0.5)
    }

    static func clampedCenter(_ position: CGFloat, width: CGFloat) -> CGFloat {
        let half = segmentWidth(in: width) / 2
        return min(max(position, inset + half), max(inset + half, width - inset - half))
    }

    static func category(at position: CGFloat, width: CGFloat) -> MenuPanelCategory {
        let itemWidth = segmentWidth(in: width)
        guard position.isFinite, itemWidth.isFinite, itemWidth > 0 else { return .favorites }
        let location = clampedCenter(position, width: width)
        let index = min(max(Int((location - inset) / itemWidth), 0), MenuPanelCategory.allCases.count - 1)
        return MenuPanelCategory.allCases[index]
    }
}

/// 主面板专用的玻璃分类栏。只移动选中块，松手后才切换页面内容。
struct MenuPanelCategoryBar: View {
    @Binding var selection: MenuPanelCategory
    let glassNamespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @GestureState private var dragLocation: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let itemWidth = MenuPanelCategoryDragLayout.segmentWidth(in: width)
            let restingCenter = MenuPanelCategoryDragLayout.center(for: selection, width: width)
            let center = dragLocation.map {
                MenuPanelCategoryDragLayout.clampedCenter($0, width: width)
            } ?? restingCenter
            let highlighted = dragLocation.map {
                MenuPanelCategoryDragLayout.category(at: $0, width: width)
            } ?? selection

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary.opacity(0.45))

                HStack(spacing: 0) {
                    Color.clear.frame(width: center - itemWidth / 2)
                    selectionLens(width: itemWidth, category: highlighted)
                    Spacer(minLength: 0)
                }
                    .animation(
                        reduceMotion || dragLocation != nil ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                        value: center
                    )
                    // 父级冻结页面布局的事务不能吞掉玻璃块自己的吸附动画。
                    .transaction { $0.disablesAnimations = false }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                HStack(spacing: 0) {
                    ForEach(MenuPanelCategory.allCases) { category in
                        Button {
                            selection = category
                        } label: {
                            Text(L(category.titleKey))
                                .font(.system(size: 12, weight: highlighted == category ? .semibold : .medium))
                                .foregroundStyle(highlighted == category ? .primary : .secondary)
                                .opacity(highlighted == category ? 0 : 1)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L(category.titleKey))
                        .accessibilityAddTraits(selection == category ? .isSelected : [])
                    }
                }
                .padding(.horizontal, MenuPanelCategoryDragLayout.inset)
            }
            .contentShape(.capsule)
            .highPriorityGesture(
                DragGesture(minimumDistance: 3)
                    .updating($dragLocation) { value, location, transaction in
                        transaction.animation = nil
                        location = value.location.x
                    }
                    .onEnded { value in
                        selection = MenuPanelCategoryDragLayout.category(at: value.location.x, width: width)
                    }
            )
        }
        .frame(height: 42)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: moveSelection(by: -1)
            case .right: moveSelection(by: 1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("panel.navigation"))
    }

    @ViewBuilder
    private func selectionLens(width: CGFloat, category: MenuPanelCategory) -> some View {
        let label = Text(L(category.titleKey))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: width, height: 34)

        if reduceTransparency {
            label
                .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
                .overlay { Capsule().stroke(.separator, lineWidth: 1) }
        } else {
            label
                .scaleEffect(dragLocation != nil && !reduceMotion ? 1.045 : 1)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)).interactive(), in: .capsule)
                .glassEffectID("panel.category.selection", in: glassNamespace)
                .overlay {
                    if contrast == .increased {
                        Capsule().stroke(.primary.opacity(0.5), lineWidth: 1)
                    }
                }
        }
    }

    private func moveSelection(by offset: Int) {
        let categories = MenuPanelCategory.allCases
        let index = categories.firstIndex(of: selection) ?? 0
        selection = categories[min(max(index + offset, 0), categories.count - 1)]
    }
}
