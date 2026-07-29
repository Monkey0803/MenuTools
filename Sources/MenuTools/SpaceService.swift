import Foundation
import CoreGraphics

/// 通过私有 SkyLight 框架直接切换桌面空间（绕过合成按键被系统硬化拦截的问题）。
/// 用 dlopen/dlsym 运行时加载，避免链接私有框架；接口随系统版本可能变化，取值均做健壮性判空。
enum SpaceService {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// 切换到相邻空间（next=true 右，false 左）；到边界不循环。
    static func move(next: Bool) -> Bool {
        guard let mainConn = symbol("SLSMainConnectionID", as: MainConnFn.self),
              let copySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopySpacesFn.self),
              let setSpace = symbol("SLSManagedDisplaySetCurrentSpace", as: SetSpaceFn.self) else {
            return false
        }
        let cid = mainConn()
        guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return false }

        // 找到当前活跃空间所在的显示器（其 Current Space 存在于自身 Spaces 列表中）
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = (current["id64"] as? NSNumber)?.uint64Value else { continue }
            let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard let idx = ids.firstIndex(of: currentID) else { continue }
            let target = next ? idx + 1 : idx - 1
            guard ids.indices.contains(target) else { return false } // 已在边界
            setSpace(cid, identifier as CFString, ids[target])
            return true
        }
        return false
    }
}
