import Foundation
import ServiceManagement

/// 开机启动（登录项）管理，基于 SMAppService.mainApp
@MainActor
enum LoginItemService {

    /// 当前是否已注册为登录项
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 设置开机启动开关；失败时抛出（如用户在系统设置中禁用了该项）
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
