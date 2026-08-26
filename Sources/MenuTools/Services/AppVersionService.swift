import Foundation

/// 应用版本信息；更新检查和安装由 Sparkle 负责。
enum AppVersionService {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
