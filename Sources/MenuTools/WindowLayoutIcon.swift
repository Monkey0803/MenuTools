import SwiftUI

/// 窗口布局的图标语义：固定布局使用与实际分区一致的缩略图，其余操作使用 SF Symbol。
enum WindowLayoutIconDescriptor: Equatable {
    case window(CGRect)
    case systemSymbol(String)

    var isWindowPreview: Bool {
        if case .window = self { return true }
        return false
    }

    var windowFrame: CGRect? {
        if case let .window(frame) = self { return frame }
        return nil
    }

    var systemSymbol: String? {
        if case let .systemSymbol(symbol) = self { return symbol }
        return nil
    }
}

extension WindowLayout {
    var iconDescriptor: WindowLayoutIconDescriptor {
        switch self {
        case .leftHalf: return .window(.init(x: 0, y: 0, width: 0.5, height: 1))
        case .rightHalf: return .window(.init(x: 0.5, y: 0, width: 0.5, height: 1))
        case .maxWidth: return .window(.init(x: 0, y: 0.2, width: 1, height: 0.6))
        case .maxHeight: return .window(.init(x: 0.2, y: 0, width: 0.6, height: 1))
        case .maximize: return .window(.init(x: 0, y: 0, width: 1, height: 1))
        case .almostMaximize: return .window(.init(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
        case .reasonableSize: return .window(.init(x: 0.2, y: 0.15, width: 0.6, height: 0.7))
        case .topHalf: return .window(.init(x: 0, y: 0, width: 1, height: 0.5))
        case .bottomHalf: return .window(.init(x: 0, y: 0.5, width: 1, height: 0.5))
        case .topLeft: return .window(Self.grid(column: 0, columns: 2, row: 0, rows: 2))
        case .topRight: return .window(Self.grid(column: 1, columns: 2, row: 0, rows: 2))
        case .bottomLeft: return .window(Self.grid(column: 0, columns: 2, row: 1, rows: 2))
        case .bottomRight: return .window(Self.grid(column: 1, columns: 2, row: 1, rows: 2))
        case .topLeftSixth: return .window(Self.grid(column: 0, columns: 3, row: 0, rows: 2))
        case .topCenterSixth: return .window(Self.grid(column: 1, columns: 3, row: 0, rows: 2))
        case .topRightSixth: return .window(Self.grid(column: 2, columns: 3, row: 0, rows: 2))
        case .bottomLeftSixth: return .window(Self.grid(column: 0, columns: 3, row: 1, rows: 2))
        case .bottomCenterSixth: return .window(Self.grid(column: 1, columns: 3, row: 1, rows: 2))
        case .bottomRightSixth: return .window(Self.grid(column: 2, columns: 3, row: 1, rows: 2))
        case .firstThird: return .window(Self.grid(column: 0, columns: 3, row: 0, rows: 1))
        case .centerThird: return .window(Self.grid(column: 1, columns: 3, row: 0, rows: 1))
        case .lastThird: return .window(Self.grid(column: 2, columns: 3, row: 0, rows: 1))
        case .firstTwoThirds: return .window(Self.grid(column: 0, columns: 3, row: 0, rows: 1, columnSpan: 2))
        case .centerTwoThirds: return .window(.init(x: 1.0 / 6.0, y: 0, width: 2.0 / 3.0, height: 1))
        case .lastTwoThirds: return .window(Self.grid(column: 1, columns: 3, row: 0, rows: 1, columnSpan: 2))
        case .firstThreeFourths: return .window(Self.grid(column: 0, columns: 4, row: 0, rows: 1, columnSpan: 3))
        case .centerThreeFourths: return .window(.init(x: 0.125, y: 0, width: 0.75, height: 1))
        case .lastThreeFourths: return .window(Self.grid(column: 1, columns: 4, row: 0, rows: 1, columnSpan: 3))
        case .firstFourth: return .window(Self.grid(column: 0, columns: 4, row: 0, rows: 1))
        case .secondFourth: return .window(Self.grid(column: 1, columns: 4, row: 0, rows: 1))
        case .thirdFourth: return .window(Self.grid(column: 2, columns: 4, row: 0, rows: 1))
        case .lastFourth: return .window(Self.grid(column: 3, columns: 4, row: 0, rows: 1))
        case .topThird: return .window(Self.grid(column: 0, columns: 1, row: 0, rows: 3))
        case .middleThird: return .window(Self.grid(column: 0, columns: 1, row: 1, rows: 3))
        case .bottomThird: return .window(Self.grid(column: 0, columns: 1, row: 2, rows: 3))
        case .topTwoThirds: return .window(Self.grid(column: 0, columns: 1, row: 0, rows: 3, rowSpan: 2))
        case .bottomTwoThirds: return .window(Self.grid(column: 0, columns: 1, row: 1, rows: 3, rowSpan: 2))
        case .topThreeFourths: return .window(Self.grid(column: 0, columns: 1, row: 0, rows: 4, rowSpan: 3))
        case .bottomThreeFourths: return .window(Self.grid(column: 0, columns: 1, row: 1, rows: 4, rowSpan: 3))
        case .topFirstFourth: return .window(Self.grid(column: 0, columns: 4, row: 0, rows: 2))
        case .topSecondFourth: return .window(Self.grid(column: 1, columns: 4, row: 0, rows: 2))
        case .topThirdFourth: return .window(Self.grid(column: 2, columns: 4, row: 0, rows: 2))
        case .topLastFourth: return .window(Self.grid(column: 3, columns: 4, row: 0, rows: 2))
        case .topCenterTwoThirds: return .window(.init(x: 1.0 / 6.0, y: 0, width: 2.0 / 3.0, height: 0.5))
        case .bottomCenterTwoThirds: return .window(.init(x: 1.0 / 6.0, y: 0.5, width: 2.0 / 3.0, height: 0.5))
        case .centered: return .window(.init(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        case .toggleFullscreen: return .systemSymbol("arrow.up.left.and.arrow.down.right")
        case .makeLarger: return .systemSymbol("plus")
        case .makeSmaller: return .systemSymbol("minus")
        case .restore: return .systemSymbol("arrow.uturn.backward")
        case .moveNextDisplay, .movePreviousDisplay: return .systemSymbol("rectangle.on.rectangle.angled")
        case .moveNextDesktop, .movePreviousDesktop: return .systemSymbol("rectangle.on.rectangle")
        case .moveLeft: return .systemSymbol("arrow.left")
        case .moveRight: return .systemSymbol("arrow.right")
        case .moveUp: return .systemSymbol("arrow.up")
        case .moveDown: return .systemSymbol("arrow.down")
        // 收纳会把窗口推出屏幕，用符号表达比缩略图更准确（缩略图不会裁剪到图标边界内）。
        case .stashLeft: return .systemSymbol("arrow.left.to.line")
        case .stashRight: return .systemSymbol("arrow.right.to.line")
        }
    }

    private static func grid(
        column: Int,
        columns: Int,
        row: Int,
        rows: Int,
        columnSpan: Int = 1,
        rowSpan: Int = 1
    ) -> CGRect {
        CGRect(
            x: CGFloat(column) / CGFloat(columns),
            y: CGFloat(row) / CGFloat(rows),
            width: CGFloat(columnSpan) / CGFloat(columns),
            height: CGFloat(rowSpan) / CGFloat(rows)
        )
    }
}

struct WindowLayoutIcon: View {
    let layout: WindowLayout

    var body: some View {
        switch layout.iconDescriptor {
        case let .window(target):
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 1, dy: 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(.primary, lineWidth: 1)
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(.primary)
                            .frame(
                                width: max(1, bounds.width * target.width),
                                height: max(1, bounds.height * target.height)
                            )
                            .offset(
                                x: bounds.minX + bounds.width * target.minX,
                                y: bounds.minY + bounds.height * target.minY
                            )
                    }
            }
        case let .systemSymbol(symbol):
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
        }
    }
}
