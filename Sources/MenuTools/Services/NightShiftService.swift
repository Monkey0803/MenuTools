import Foundation

/// 夜览（Night Shift）开关
/// 系统未提供公开 API，这里通过 CoreBrightness 私有框架的 CBBlueLightClient 控制，
/// 结构体布局与 setEnabled: 行为已在本机通过往返测试验证（Scripts/test_nightshift_toggle.swift）
@MainActor
enum NightShiftService {

    enum NightShiftError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "此设备不支持夜览（Night Shift）"
            }
        }
    }

    /// 与私有头文件 CBBlueLightClient.h 中 Status 结构体保持一致的内存布局
    private struct BlueLightStatus {
        var active: ObjCBool = false
        var enabled: ObjCBool = false
        var sunSchedulePermitted: ObjCBool = false
        var mode: Int32 = 0
        var schedule: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
        var disableFlags: UInt64 = 0
        var available: ObjCBool = false
    }

    private typealias GetStatusFunc = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabledFunc = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private static let getStatusSelector = Selector(("getBlueLightStatus:"))
    private static let setEnabledSelector = Selector(("setEnabled:"))

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            return nil
        }
        let instance = cls.init()
        guard instance.responds(to: getStatusSelector), instance.responds(to: setEnabledSelector) else {
            return nil
        }
        return instance
    }()

    static var isSupported: Bool { client != nil }

    /// 夜览当前是否开启
    static var isEnabled: Bool {
        guard let client else { return false }
        let fn = unsafeBitCast(client.method(for: getStatusSelector), to: GetStatusFunc.self)
        var status = BlueLightStatus()
        let ok = withUnsafeMutablePointer(to: &status) {
            fn(client, getStatusSelector, UnsafeMutableRawPointer($0))
        }
        return ok && status.enabled.boolValue
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard let client else { throw NightShiftError.unavailable }
        let fn = unsafeBitCast(client.method(for: setEnabledSelector), to: SetEnabledFunc.self)
        guard fn(client, setEnabledSelector, enabled) else {
            throw NightShiftError.unavailable
        }
    }
}
