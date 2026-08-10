import AppKit
import CoreGraphics
import Foundation
import Observation

struct DisplayModeInfo: Identifiable, Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
    let refreshRate: Double
    let isCurrent: Bool

    var id: String {
        "\(width)x\(height)-\(Int(refreshRate.rounded()))"
    }

    var label: String {
        let resolution = "\(width) × \(height)"
        guard refreshRate > 0 else { return resolution }
        return "\(resolution) · \(Int(refreshRate.rounded())) Hz"
    }
}

struct DisplayInfo: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let isBuiltIn: Bool
    let currentMode: DisplayModeInfo
    let modes: [DisplayModeInfo]
}

enum DisplayServiceError: LocalizedError, Equatable {
    case displayUnavailable
    case modeUnavailable
    case changeFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable, .modeUnavailable, .changeFailed:
            return L("display.changeFailed")
        }
    }
}

@MainActor
@Observable
final class DisplayService {
    private(set) var displays: [DisplayInfo] = []

    func refresh() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let current = CGDisplayCopyDisplayMode(displayID) else { return nil }
            let currentInfo = modeInfo(current, isCurrent: true)
            let modes = availableModes(displayID: displayID, current: currentInfo)
            return DisplayInfo(
                id: displayID,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                currentMode: currentInfo,
                modes: modes
            )
        }
    }

    func setMode(displayID: UInt32, mode: DisplayModeInfo) throws {
        let id = CGDirectDisplayID(displayID)
        guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
              let target = modes.first(where: {
                  Int($0.pixelWidth) == mode.width &&
                  Int($0.pixelHeight) == mode.height &&
                  sameRefreshRate($0.refreshRate, mode.refreshRate)
              }) else {
            throw DisplayServiceError.modeUnavailable
        }
        guard CGDisplaySetDisplayMode(id, target, nil) == CGError.success else {
            throw DisplayServiceError.changeFailed
        }
        refresh()
    }

    static func uniqueModes(_ modes: [DisplayModeInfo], current: DisplayModeInfo) -> [DisplayModeInfo] {
        var result: [String: DisplayModeInfo] = [:]
        for mode in modes {
            if let existing = result[mode.id], existing.isCurrent && !mode.isCurrent {
                continue
            }
            result[mode.id] = mode
        }
        if result[current.id] == nil { result[current.id] = current }
        return result.values.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.refreshRate > $1.refreshRate
        }
    }

    private func availableModes(displayID: CGDirectDisplayID, current: DisplayModeInfo) -> [DisplayModeInfo] {
        let all = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? [])
            .map { modeInfo($0, isCurrent: sameMode($0, current)) }
        return Self.uniqueModes(all, current: current)
    }

    private func modeInfo(_ mode: CGDisplayMode, isCurrent: Bool) -> DisplayModeInfo {
        DisplayModeInfo(
            width: Int(mode.pixelWidth),
            height: Int(mode.pixelHeight),
            refreshRate: mode.refreshRate,
            isCurrent: isCurrent
        )
    }

    private func sameMode(_ mode: CGDisplayMode, _ info: DisplayModeInfo) -> Bool {
        Int(mode.pixelWidth) == info.width &&
        Int(mode.pixelHeight) == info.height &&
        sameRefreshRate(mode.refreshRate, info.refreshRate)
    }

    private func sameRefreshRate(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs == 0 && rhs == 0 || abs(lhs - rhs) < 0.5
    }
}
