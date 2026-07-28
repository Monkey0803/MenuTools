import Foundation

/// 本地化取值（主 bundle 的 Localizable.strings；打包后随系统语言解析）
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 带格式参数的本地化取值
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
