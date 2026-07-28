import AppKit

/// 剪贴板：查询项数与一键清空
@MainActor
enum ClipboardService {

    /// 当前剪贴板中的条目数
    static var itemCount: Int {
        NSPasteboard.general.pasteboardItems?.count ?? 0
    }

    static func clear() {
        NSPasteboard.general.clearContents()
    }
}
