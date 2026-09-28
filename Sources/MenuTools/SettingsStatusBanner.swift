import SwiftUI

/// 设置页统一的「操作结果」提示。
///
/// 此前各页各写各的：翻译页只有一行红字、存储页把成功与失败都染成灰色（出错看起来像成功）、
/// 截图页弹模态对话框、网络监控页是自己一套 banner。面板侧早已有 `statusMessage` + `flashStatus`，
/// 设置侧缺同一套最小抽象。
struct SettingsStatusMessage: Equatable {
    enum Kind: String, CaseIterable, Equatable {
        case success
        case failure
        case info
    }

    var kind: Kind
    var text: String

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    init(success text: String) {
        self.init(kind: .success, text: text)
    }

    init(info text: String) {
        self.init(kind: .info, text: text)
    }

    init(failure error: Error) {
        self.init(kind: .failure, text: error.localizedDescription)
    }

    var isError: Bool { kind == .failure }

    var symbolName: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }
}

/// 统一的设置页状态行：成功绿色、失败红色、普通信息灰色。
struct SettingsStatusBanner: View {
    let message: SettingsStatusMessage

    var body: some View {
        Label(message.text, systemImage: message.symbolName)
            .font(.caption)
            .foregroundStyle(style)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var style: AnyShapeStyle {
        switch message.kind {
        case .success: return AnyShapeStyle(.green)
        case .failure: return AnyShapeStyle(.red)
        case .info: return AnyShapeStyle(.secondary)
        }
    }
}
