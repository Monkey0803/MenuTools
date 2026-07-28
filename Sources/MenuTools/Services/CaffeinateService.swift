import Foundation
import IOKit.pwr_mgt

/// 防止锁屏：通过 IOKit 电源断言阻止显示器休眠（进而阻止自动锁屏）
@MainActor
final class CaffeinateService: ObservableObject {
    static let shared = CaffeinateService()

    @Published private(set) var isActive = false
    private var assertionID: IOPMAssertionID = 0

    private init() {}

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MenuTools：防止锁屏" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
        }
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }
}
