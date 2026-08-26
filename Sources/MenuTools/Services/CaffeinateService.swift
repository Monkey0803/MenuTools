import Foundation
import IOKit.pwr_mgt

/// 防止锁屏：通过 IOKit 电源断言阻止显示器休眠（进而阻止自动锁屏）
@MainActor
final class CaffeinateService: ObservableObject {
    static let shared = CaffeinateService()

    @Published private(set) var isActive = false
    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var userActivityAssertionID: IOPMAssertionID = 0
    private var userActivityTimer: Timer?

    private init() {}

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        var displayID = IOPMAssertionID(0)
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MenuTools: Keep Awake" as CFString,
            &displayID
        )
        guard displayResult == kIOReturnSuccess else { return }

        var systemID = IOPMAssertionID(0)
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MenuTools: Prevent Idle Lock" as CFString,
            &systemID
        )
        guard systemResult == kIOReturnSuccess else {
            IOPMAssertionRelease(displayID)
            return
        }

        displayAssertionID = displayID
        systemAssertionID = systemID
        isActive = true
        declareUserActivity()
        userActivityTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.declareUserActivity()
            }
        }
        if let userActivityTimer {
            RunLoop.main.add(userActivityTimer, forMode: .common)
        }
    }

    func stop() {
        guard isActive else { return }
        userActivityTimer?.invalidate()
        userActivityTimer = nil
        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        isActive = false
    }

    private func declareUserActivity() {
        guard isActive else { return }
        var assertionID = userActivityAssertionID
        let result = IOPMAssertionDeclareUserActivity(
            "MenuTools: User Activity" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        if result == kIOReturnSuccess {
            userActivityAssertionID = assertionID
        }
    }
}
