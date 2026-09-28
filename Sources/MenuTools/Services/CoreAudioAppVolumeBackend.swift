import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

@MainActor
final class CoreAudioAppVolumeBackend: AppVolumeRoutingBackend {
    private struct FailedRoute {
        var target: AppVolumeTarget
        var error: AppVolumeRoutingError
        var attempts: Int
        var lastAttempt: TimeInterval
    }

    var onSnapshot: ((AppVolumeBackendSnapshot) -> Void)?

    private var routes: [String: CoreAudioAppVolumeRoute] = [:]
    private var failedRoutes: [String: FailedRoute] = [:]
    private var refreshTimer: Timer?
    private var currentOutputDevice = kAudioObjectUnknown
    private var currentOutputUID = ""
    private let inputLevelMonitor = InputLevelMonitor()

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        routes.values.forEach { $0.stop() }
        routes.removeAll()
        failedRoutes.removeAll()
        inputLevelMonitor.stop()
    }

    func startInputLevelMonitoring() {
        inputLevelMonitor.start()
    }

    func stopInputLevelMonitoring() {
        inputLevelMonitor.stop()
    }

    func apply(volume: Double, to target: AppVolumeTarget) throws {
        guard AppVolumeSafetyPolicy.requiresRoute(
            for: volume,
            equalizer: target.equalizer,
            outputDeviceUID: target.outputDeviceUID,
            pan: target.pan,
            isMono: target.isMono
        ) else {
            removeRoute(for: target.rootBundleID)
            return
        }
        // 同一个目标失败过：没到退避时间就复用错误，避免每秒重建一次 tap。
        // 目标变了（换了输出设备、EQ、平衡或单声道）说明条件不同，立即重建；
        // 允许重试时保留旧的 attempts，让下一次失败继续退避，成功时会统一清掉。
        if let failure = failedRoutes[target.rootBundleID], AppVolumeRouteRetryPolicy.shouldReuseFailure(
            error: failure.error,
            consecutiveFailures: failure.attempts,
            elapsed: Self.monotonicSeconds() - failure.lastAttempt,
            targetChanged: failure.target != target
        ) {
            throw failure.error
        }

        let output = try outputDevice(uid: target.outputDeviceUID) ?? readDefaultOutputDevice()
        if let route = routes[target.rootBundleID], route.matches(target: target, outputDevice: output.id) {
            route.setProcessing(
                gain: volume,
                equalizer: target.equalizer,
                pan: target.pan,
                isMono: target.isMono
            )
            failedRoutes.removeValue(forKey: target.rootBundleID)
            return
        }

        removeRoute(for: target.rootBundleID)
        do {
            let route = try CoreAudioAppVolumeRoute(
                target: target,
                gain: volume,
                equalizer: target.equalizer,
                outputDeviceID: output.id,
                outputUID: output.uid
            )
            routes[target.rootBundleID] = route
            failedRoutes.removeValue(forKey: target.rootBundleID)
        } catch let error as AppVolumeRoutingError {
            recordFailure(error, for: target)
            throw error
        }
    }

    /// 记录一次建路由失败，并累计连续失败次数供退避重试使用。
    private func recordFailure(_ error: AppVolumeRoutingError, for target: AppVolumeTarget) {
        let previous = failedRoutes[target.rootBundleID]
        let attempts = (previous?.target == target ? previous?.attempts ?? 0 : 0) + 1
        failedRoutes[target.rootBundleID] = FailedRoute(
            target: target,
            error: error,
            attempts: attempts,
            lastAttempt: Self.monotonicSeconds()
        )
    }

    /// 单调时钟：退避间隔不受系统时间调整影响。
    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func removeRoute(for rootBundleID: String) {
        failedRoutes.removeValue(forKey: rootBundleID)
        stopRoute(for: rootBundleID)
    }

    private func stopRoute(for rootBundleID: String) {
        routes.removeValue(forKey: rootBundleID)?.stop()
    }

    func setMasterVolume(_ volume: Double) throws {
        let output = try readDefaultOutputDevice()
        let value = Float32(min(max(volume, 0), 1))
        guard try setFirstSupported(
            object: output.id,
            selector: kAudioDevicePropertyVolumeScalar,
            value: value
        ) else {
            throw AppVolumeRoutingError.operationFailed(L("volume.master"), kAudioHardwareUnsupportedOperationError)
        }
        if value > 0 {
            _ = try? setFirstSupported(
                object: output.id,
                selector: kAudioDevicePropertyMute,
                value: UInt32(0)
            )
        }
        refresh()
    }

    func setMasterMuted(_ muted: Bool) throws {
        let output = try readDefaultOutputDevice()
        guard try setFirstSupported(
            object: output.id,
            selector: kAudioDevicePropertyMute,
            value: UInt32(muted ? 1 : 0)
        ) else {
            throw AppVolumeRoutingError.operationFailed(L("volume.mute"), kAudioHardwareUnsupportedOperationError)
        }
        refresh()
    }

    func availableOutputDevices() throws -> [AudioOutputDevice] {
        let currentOutput = try readDefaultOutputDevice()
        return try CoreAudioProperty.deviceList().compactMap { deviceID in
            guard hasStreams(deviceID, scope: kAudioDevicePropertyScopeOutput) else { return nil }
            let uid = try CoreAudioProperty.readString(object: deviceID, selector: kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !uid.hasPrefix("com.qoder.menutools.app-volume.") else { return nil }
            let name = (try? CoreAudioProperty.readString(object: deviceID, selector: kAudioObjectPropertyName))
                ?? L("volume.output.unknown")
            return AudioOutputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isDefault: deviceID == currentOutput.id
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func selectOutputDevice(_ device: AudioOutputDevice) throws {
        try CoreAudioProperty.writeScalar(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: device.id
        )
        refresh()
    }

    func availableInputDevices() throws -> [AudioInputDevice] {
        let currentInput = try readDefaultInputDevice()
        return try CoreAudioProperty.deviceList().compactMap { deviceID in
            guard hasStreams(deviceID, scope: kAudioDevicePropertyScopeInput) else { return nil }
            let uid = try CoreAudioProperty.readString(object: deviceID, selector: kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !uid.hasPrefix("com.qoder.menutools.app-volume.") else { return nil }
            let name = (try? CoreAudioProperty.readString(object: deviceID, selector: kAudioObjectPropertyName))
                ?? L("volume.input.unknown")
            return AudioInputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isDefault: deviceID == currentInput.id
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func selectInputDevice(_ device: AudioInputDevice) throws {
        try CoreAudioProperty.writeScalar(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: device.id
        )
        inputLevelMonitor.restartIfRunning()
        refresh()
    }

    func setInputVolume(_ volume: Double) throws {
        let input = try readDefaultInputDevice()
        guard try setFirstSupported(
            object: input.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeInput,
            value: Float32(min(max(volume, 0), 1))
        ) else {
            throw AppVolumeRoutingError.operationFailed(L("volume.input"), kAudioHardwareUnsupportedOperationError)
        }
        refresh()
    }

    func setInputMuted(_ muted: Bool) throws {
        let input = try readDefaultInputDevice()
        guard try setFirstSupported(
            object: input.id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput,
            value: UInt32(muted ? 1 : 0)
        ) else {
            throw AppVolumeRoutingError.operationFailed(L("volume.muteInput"), kAudioHardwareUnsupportedOperationError)
        }
        refresh()
    }

    private func refresh() {
        do {
            let failed = routes.compactMap { identifier, route -> (String, AppVolumeTarget, AppVolumeRoutingError)? in
                guard let target = route.consumePendingFailure() else { return nil }
                if let mismatch = route.consumeLayoutMismatch() {
                    return (identifier, target, .channelLayoutMismatch(input: mismatch.input, output: mismatch.output))
                }
                return (identifier, target, .unsupportedFormat)
            }
            for (identifier, target, error) in failed {
                recordFailure(error, for: target)
                stopRoute(for: identifier)
            }
            let outputDevice = try readDefaultOutputDevice()
            if currentOutputDevice != outputDevice.id || currentOutputUID != outputDevice.uid {
                routes.values.forEach { $0.stop() }
                routes.removeAll()
                failedRoutes.removeAll()
                currentOutputDevice = outputDevice.id
                currentOutputUID = outputDevice.uid
            }
            onSnapshot?(
                AppVolumeBackendSnapshot(
                    candidates: try readProcessCandidates(),
                    output: try readOutputState(device: outputDevice.id),
                    input: (try? readInputState()) ?? .unavailable,
                    levels: Dictionary(uniqueKeysWithValues: routes.map {
                        ($0.key, $0.value.consumeMeter())
                    })
                )
            )
        } catch {
            onSnapshot?(
                AppVolumeBackendSnapshot(candidates: [], output: .unavailable)
            )
        }
    }

    private func readProcessCandidates() throws -> [AppAudioProcessCandidate] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return try CoreAudioProperty.processObjectList().compactMap { objectID in
            guard let pid: pid_t = try? CoreAudioProperty.readScalar(
                object: objectID,
                selector: kAudioProcessPropertyPID
            ),
            pid != ownPID,
            let audioBundleID = try? CoreAudioProperty.readString(
                object: objectID,
                selector: kAudioProcessPropertyBundleID
            ),
            !audioBundleID.isEmpty,
            let app = Self.rootApplication(for: pid) else {
                return nil
            }
            let running: UInt32 = (try? CoreAudioProperty.readScalar(
                object: objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            )) ?? 0
            return AppAudioProcessCandidate(
                processObjectID: objectID,
                processID: pid,
                audioBundleID: audioBundleID,
                rootBundleID: app.bundleID,
                displayName: app.name,
                bundleURL: app.url,
                isRunningOutput: running != 0
            )
        }
    }

    private func readOutputState(device: AudioDeviceID) throws -> SystemOutputVolumeState {
        let name = (try? CoreAudioProperty.readString(
            object: device,
            selector: kAudioObjectPropertyName
        )) ?? L("volume.output.unknown")
        let volume: Float32? = try firstReadable(
            object: device,
            selector: kAudioDevicePropertyVolumeScalar
        )
        let muted: UInt32? = try firstReadable(
            object: device,
            selector: kAudioDevicePropertyMute
        )
        return SystemOutputVolumeState(
            deviceID: device,
            deviceUID: (try? CoreAudioProperty.readString(object: device, selector: kAudioDevicePropertyDeviceUID)) ?? "",
            deviceName: name,
            volume: Double(volume ?? 1),
            isMuted: muted == 1,
            canSetVolume: isAnySettable(object: device, selector: kAudioDevicePropertyVolumeScalar),
            canSetMute: isAnySettable(object: device, selector: kAudioDevicePropertyMute)
        )
    }

    private func readDefaultOutputDevice() throws -> (id: AudioDeviceID, uid: String) {
        let device: AudioDeviceID = try CoreAudioProperty.readScalar(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        guard device != kAudioObjectUnknown else {
            throw AppVolumeRoutingError.operationFailed("default output", kAudioHardwareBadDeviceError)
        }
        let uid = try CoreAudioProperty.readString(
            object: device,
            selector: kAudioDevicePropertyDeviceUID
        )
        return (device, uid)
    }

    private func outputDevice(uid: String?) throws -> (id: AudioDeviceID, uid: String)? {
        guard let uid, !uid.isEmpty else { return nil }
        guard let device = try CoreAudioProperty.deviceList().first(where: { deviceID in
            hasStreams(deviceID, scope: kAudioDevicePropertyScopeOutput)
                && (try? CoreAudioProperty.readString(
                    object: deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                )) == uid
        }) else {
            // 抛出可识别的错误：上层会清掉失效指定并回退到系统默认设备。
            throw AppVolumeRoutingError.outputDeviceMissing(uid: uid)
        }
        return (device, uid)
    }

    private func readDefaultInputDevice() throws -> (id: AudioDeviceID, uid: String) {
        let device: AudioDeviceID = try CoreAudioProperty.readScalar(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        guard device != kAudioObjectUnknown else {
            throw AppVolumeRoutingError.operationFailed("default input", kAudioHardwareBadDeviceError)
        }
        let uid = try CoreAudioProperty.readString(
            object: device,
            selector: kAudioDevicePropertyDeviceUID
        )
        return (device, uid)
    }

    private func readInputState() throws -> SystemInputVolumeState {
        let input = try readDefaultInputDevice()
        let name = (try? CoreAudioProperty.readString(
            object: input.id,
            selector: kAudioObjectPropertyName
        )) ?? L("volume.input.unknown")
        let volume: Float32? = try firstReadable(
            object: input.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeInput
        )
        let muted: UInt32? = try firstReadable(
            object: input.id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput
        )
        return SystemInputVolumeState(
            deviceID: input.id,
            deviceUID: input.uid,
            deviceName: name,
            volume: Double(volume ?? 1),
            isMuted: muted == 1,
            canSetVolume: isAnySettable(
                object: input.id,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeInput
            ),
            canSetMute: isAnySettable(
                object: input.id,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeInput
            ),
            peakLevel: inputLevelMonitor.consumePeakLevel()
        )
    }

    private func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        guard CoreAudioProperty.has(
            object: device,
            selector: kAudioDevicePropertyStreams,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) else { return false }
        guard let streams = try? CoreAudioProperty.readObjectIDs(
            object: device,
            selector: kAudioDevicePropertyStreams,
            scope: scope
        ) else { return false }
        return !streams.isEmpty
    }

    private func firstReadable<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) throws -> T? {
        for element in Self.volumeElements where CoreAudioProperty.has(
            object: object,
            selector: selector,
            scope: scope,
            element: element
        ) {
            return try CoreAudioProperty.readScalar(
                object: object,
                selector: selector,
                scope: scope,
                element: element
            )
        }
        return nil
    }

    private func setFirstSupported<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        value: T
    ) throws -> Bool {
        var wrote = false
        for element in Self.volumeElements where CoreAudioProperty.isSettable(
            object: object,
            selector: selector,
            scope: scope,
            element: element
        ) {
            try CoreAudioProperty.writeScalar(
                object: object,
                selector: selector,
                scope: scope,
                element: element,
                value: value
            )
            wrote = true
            if element == kAudioObjectPropertyElementMain { break }
        }
        return wrote
    }

    private func isAnySettable(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) -> Bool {
        Self.volumeElements.contains {
            CoreAudioProperty.isSettable(
                object: object,
                selector: selector,
                scope: scope,
                element: $0
            )
        }
    }

    private static let volumeElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2
    ]

    private static func rootApplication(for pid: pid_t) -> (bundleID: String, name: String, url: URL)? {
        var currentPID = pid
        var visited: Set<pid_t> = []
        for _ in 0..<16 where currentPID > 1 && visited.insert(currentPID).inserted {
            if let executablePath = processPath(pid: currentPID),
               let appURL = outermostApplicationURL(in: executablePath),
               let bundle = Bundle(url: appURL),
               let bundleID = bundle.bundleIdentifier {
                guard bundleID != Bundle.main.bundleIdentifier else { return nil }
                let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent
                return (bundleID, name, appURL)
            }
            guard let parent = parentProcessID(of: currentPID), parent != currentPID else { break }
            currentPID = parent
        }
        return nil
    }

    private static func processPath(pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard actualSize == Int32(expectedSize) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func outermostApplicationURL(in executablePath: String) -> URL? {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let path = NSString.path(withComponents: Array(components.prefix(index + 1)))
        return URL(fileURLWithPath: path)
    }
}

enum AppVolumeRouteFailurePolicy {
    static let consecutiveFailureLimit = 8

    static func shouldAbort(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= consecutiveFailureLimit
    }
}

/// 建路由失败后的重试节奏。
///
/// 布局与格式类失败取决于输出设备**当前**的流格式：蓝牙耳机在音乐模式（A2DP，2 声道）
/// 与通话模式（HFP，1 声道）之间切换时，同样的代码会时而成功时而失败。这类失败必须
/// 允许退避重试，否则一次失败就让这台 App 永久停在失败状态。权限被拒、设备指定失效等
/// 需要用户或上层处理的问题不自动重试（失效设备由服务层清掉后立即重试）。
enum AppVolumeRouteRetryPolicy {
    static let initialInterval: TimeInterval = 2
    static let maximumInterval: TimeInterval = 30

    static func isRetryable(_ error: AppVolumeRoutingError) -> Bool {
        switch error {
        case .permissionDenied, .outputDeviceMissing:
            return false
        case .unsupportedFormat, .channelLayoutMismatch, .operationFailed:
            return true
        }
    }

    /// 连续失败次数越多等得越久，封顶 `maximumInterval`。
    static func interval(consecutiveFailures: Int) -> TimeInterval {
        let exponent = min(max(consecutiveFailures - 1, 0), 5)
        return min(initialInterval * pow(2, Double(exponent)), maximumInterval)
    }

    static func shouldRetry(
        error: AppVolumeRoutingError,
        consecutiveFailures: Int,
        elapsed: TimeInterval
    ) -> Bool {
        guard isRetryable(error) else { return false }
        return elapsed >= interval(consecutiveFailures: consecutiveFailures)
    }

    /// 复用上次的错误（不去重建路由）还是重新尝试。
    ///
    /// 目标变了说明条件不同（换了输出设备、EQ、平衡或单声道），必须立刻重建；
    /// 目标没变才看退避间隔，避免每秒重建一次 tap。
    static func shouldReuseFailure(
        error: AppVolumeRoutingError,
        consecutiveFailures: Int,
        elapsed: TimeInterval,
        targetChanged: Bool
    ) -> Bool {
        guard !targetChanged else { return false }
        return !shouldRetry(error: error, consecutiveFailures: consecutiveFailures, elapsed: elapsed)
    }
}

/// 音频缓冲列表的声道布局。
///
/// 进程 tap 给出的是**交错**缓冲（一个缓冲装多声道），而聚合设备的输出常是**非交错**的
/// （每声道一个缓冲）。按声道映射才能兼容两者，不能要求两边缓冲数一致。
enum AppVolumeBufferLayout {
    /// 声道总数（把交错缓冲里的多声道拆开计数）。
    static func totalChannels(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        buffers.reduce(0) { $0 + max(Int($1.mNumberChannels), 1) }
    }

    /// 第 `channel` 个声道的读取方式：缓冲下标、缓冲内偏移（以 Float 计）与步长。
    static func accessor(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        channel: Int
    ) -> (index: Int, offset: Int, stride: Int)? {
        guard channel >= 0 else { return nil }
        var remaining = channel
        for index in buffers.indices {
            let channels = max(Int(buffers[index].mNumberChannels), 1)
            if remaining < channels {
                return (index, remaining, channels)
            }
            remaining -= channels
        }
        return nil
    }

    /// 可处理的帧数：按每个缓冲的声道数换算后取最小值。
    static func frames(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var frames = Int.max
        for buffer in buffers {
            let channels = max(Int(buffer.mNumberChannels), 1)
            let bufferFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            frames = min(frames, bufferFrames)
        }
        return frames == Int.max ? 0 : frames
    }
}

/// 输入声道到输出声道的映射规则。
///
/// 进程 tap 固定给立体声混音，而输出设备的声道数取决于**当前**硬件与协议：
/// 蓝牙耳机从音乐模式（A2DP，2 声道）切到通话模式（HFP）后输出只剩 1 个声道。
/// 因此渲染不能要求两边声道数相同，而要按需下混或复制；两种方向都不得判定为不支持。
struct AppVolumeChannelMap: Equatable, Sendable {
    let inputChannels: Int
    let outputChannels: Int

    /// 输出声道 `channel` 的来源声道区间；空区间表示该声道没有来源，保持静音。
    ///
    /// - 声道数相同：一一对应。
    /// - 输出更少：按下混分组，多出来的输入声道求和取平均（输入 2 / 输出 1 即左右平均）。
    /// - 输出更多：单声道来源复制到每个输出声道；更宽的输出只占前几个声道，其余静音。
    func sourceRange(forOutputChannel channel: Int) -> Range<Int> {
        guard inputChannels > 0, outputChannels > 0, channel >= 0, channel < outputChannels else {
            return 0..<0
        }
        if inputChannels == outputChannels {
            return channel..<(channel + 1)
        }
        if inputChannels > outputChannels {
            let start = channel * inputChannels / outputChannels
            let end = max((channel + 1) * inputChannels / outputChannels, start + 1)
            return start..<min(end, inputChannels)
        }
        guard inputChannels == 1 || channel < inputChannels else { return 0..<0 }
        return inputChannels == 1 ? 0..<1 : channel..<(channel + 1)
    }
}

/// 一次 IOProc 渲染的统计结果，供电平表、削波提示与 CPU 占用使用。
struct AppVolumeRenderStats: Equatable {
    var peak: Float = 0
    var sumSquares: Double = 0
    var sampleCount: Int = 0
    var isClipping = false

    var rms: Float {
        sampleCount == 0 ? 0 : Float(sqrt(sumSquares / Double(sampleCount)))
    }
}

/// IOProc 的逐帧渲染核心：按声道映射把输入搬到输出，并施加增益渐变、左右平衡、
/// 单声道下混与均衡。
///
/// 单独拆出来是为了能脱机测试：真实设备会出现「输入 2 声道 / 输出 1 声道」这类组合，
/// 必须下混而不是连续失败。调用方需**先把输出缓冲清零**，没有来源的输出声道才会保持静音。
enum AppVolumeRenderCore {
    /// 一个来源声道的读取方式（缓冲内的起点指针、以 Float 计的偏移与步长）。
    private struct SourceChannel {
        let pointer: UnsafeMutablePointer<Float>
        let offset: Int
        let stride: Int
    }

    /// 返回 nil 表示缓冲布局不可用（缺数据指针或没有可渲染的帧），调用方按连续失败计数降级。
    static func render(
        inputs: UnsafeMutableAudioBufferListPointer,
        outputs: UnsafeMutableAudioBufferListPointer,
        currentGain: Float,
        targetGain: Float,
        pan: Double,
        isMono: Bool,
        equalizer: AppVolumeEqualizerProcessor?,
        equalizerConfiguration: AppVolumeEqualizerConfiguration?
    ) -> AppVolumeRenderStats? {
        let inputChannels = AppVolumeBufferLayout.totalChannels(inputs)
        let outputChannels = AppVolumeBufferLayout.totalChannels(outputs)
        guard inputChannels > 0, outputChannels > 0 else { return nil }
        let frames = min(AppVolumeBufferLayout.frames(inputs), AppVolumeBufferLayout.frames(outputs))
        guard frames > 0 else { return nil }

        let map = AppVolumeChannelMap(inputChannels: inputChannels, outputChannels: outputChannels)
        let step = AppVolumeGainRamp.step(from: currentGain, to: targetGain, frames: frames)
        return withUnsafeTemporaryAllocation(of: SourceChannel.self, capacity: inputChannels) { scratch in
            var stats = AppVolumeRenderStats()
            for channel in 0..<outputChannels {
                guard let destination = AppVolumeBufferLayout.accessor(outputs, channel: channel),
                      let destinationPointer = outputs[destination.index].mData?.assumingMemoryBound(to: Float.self) else {
                    return nil
                }
                let mapped = map.sourceRange(forOutputChannel: channel)
                // 没有来源的输出声道（例如 5.1 的中置与低频）保持调用方清零后的静音。
                guard !mapped.isEmpty else { continue }
                // 用户开启单声道下混时，所有输出声道都用输入侧全部声道求平均（双单声道）。
                let sources = (isMono && inputChannels > 1) ? 0..<inputChannels : mapped
                var sourceCount = 0
                for source in sources {
                    guard let accessor = AppVolumeBufferLayout.accessor(inputs, channel: source),
                          let pointer = inputs[accessor.index].mData?.assumingMemoryBound(to: Float.self) else {
                        return nil
                    }
                    scratch[sourceCount] = SourceChannel(
                        pointer: pointer,
                        offset: accessor.offset,
                        stride: accessor.stride
                    )
                    sourceCount += 1
                }
                guard sourceCount > 0 else { continue }

                let channelGain = AppVolumeChannelMix.channelGain(
                    pan: pan,
                    channel: channel,
                    outputChannels: outputChannels
                )
                var gain = currentGain
                for frame in 0..<frames {
                    gain = AppVolumeGainRamp.advanced(gain, by: step)
                    var sum: Float = 0
                    for index in 0..<sourceCount {
                        let source = scratch[index]
                        sum += source.pointer[source.offset + frame * source.stride]
                    }
                    let value = AppVolumeChannelMix.monoSample(sum, channelCount: sourceCount)
                    let processed = equalizer?.process(
                        value * gain * channelGain,
                        channel: channel,
                        configuration: equalizerConfiguration
                    ) ?? (value * gain * channelGain)
                    stats.peak = max(stats.peak, abs(processed))
                    stats.sumSquares += Double(processed * processed)
                    stats.sampleCount += 1
                    stats.isClipping = stats.isClipping || abs(processed) > 1
                    destinationPointer[destination.offset + frame * destination.stride] =
                        AppVolumeGainRamp.clamped(processed)
                }
            }
            return stats
        }
    }
}

private final class AppVolumeRouteState: @unchecked Sendable {
    let targetGain: Atomic<Float>
    let currentGain: Atomic<Float>
    let peakLevel: Atomic<Float>
    let rmsLevel: Atomic<Float>
    let clipping: Atomic<UInt32>
    let cpuLoad: Atomic<Float>
    let failurePending = Atomic(false)
    let invalidCallbackCount = Atomic(0)
    let failureSignaled = Atomic(false)
    private let layoutMismatch = Atomic(false)
    private let lastInputChannels = Atomic(0)
    private let lastOutputChannels = Atomic(0)
    private let pan = Atomic<Float>(0)
    private let mono = Atomic(false)
    private let equalizerConfiguration = Atomic<UnsafeRawPointer?>(nil)
    let equalizerProcessor = AppVolumeEqualizerProcessor()
    private var currentEqualizer = AppVolumeEqualizer.flat
    private var sampleRate = 48_000.0
    private var retainedEqualizerConfigurations: [AppVolumeEqualizerConfiguration] = []

    init(gain: Float) {
        targetGain = Atomic(gain)
        currentGain = Atomic(gain)
        peakLevel = Atomic(0)
        rmsLevel = Atomic(0)
        clipping = Atomic(0)
        cpuLoad = Atomic(0)
    }

    /// 记录一次「输入输出声道数不一致」，供诊断使用。
    func noteLayoutMismatch(input: Int, output: Int) {
        lastInputChannels.store(input, ordering: .relaxed)
        lastOutputChannels.store(output, ordering: .relaxed)
        layoutMismatch.store(true, ordering: .relaxed)
    }

    func consumeLayoutMismatch() -> (input: Int, output: Int)? {
        guard layoutMismatch.exchange(false, ordering: .relaxed) else { return nil }
        return (
            lastInputChannels.load(ordering: .relaxed),
            lastOutputChannels.load(ordering: .relaxed)
        )
    }

    /// 更新左右平衡与单声道下混（IOProc 每个缓冲区读取一次）。
    func setChannelMix(pan value: Double, isMono: Bool) {
        pan.store(Float(AppVolumeChannelMix.normalizedPan(value)), ordering: .relaxed)
        mono.store(isMono, ordering: .relaxed)
    }

    func currentPan() -> Double {
        Double(pan.load(ordering: .relaxed))
    }

    func isMonoRequested() -> Bool {
        mono.load(ordering: .relaxed)
    }

    func setEqualizer(_ equalizer: AppVolumeEqualizer, sampleRate: Double) {
        let normalizedEqualizer = equalizer.normalized()
        guard currentEqualizer != normalizedEqualizer || self.sampleRate != sampleRate else { return }
        currentEqualizer = normalizedEqualizer
        self.sampleRate = sampleRate
        guard normalizedEqualizer.requiresProcessing else {
            equalizerConfiguration.store(nil, ordering: .releasing)
            return
        }
        let configuration = AppVolumeEqualizerConfiguration(
            equalizer: normalizedEqualizer,
            sampleRate: sampleRate
        )
        retainedEqualizerConfigurations.append(configuration)
        equalizerConfiguration.store(
            Unmanaged.passUnretained(configuration).toOpaque(),
            ordering: .releasing
        )
    }

    func currentEqualizerConfiguration() -> AppVolumeEqualizerConfiguration? {
        guard let pointer = equalizerConfiguration.load(ordering: .acquiring) else { return nil }
        return Unmanaged<AppVolumeEqualizerConfiguration>
            .fromOpaque(pointer)
            .takeUnretainedValue()
    }
}

/// 单个峰值滤波器的系数（均衡器快照的一部分）。
struct AppVolumeBiquad: Sendable {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    static func peaking(frequency: Double, gain: Double, sampleRate: Double) -> Self {
        let safeSampleRate = max(sampleRate, 1)
        let normalizedFrequency = min(max(frequency, 1), safeSampleRate * 0.45)
        let amplitude = pow(10, gain / 40)
        let omega = 2 * Double.pi * normalizedFrequency / safeSampleRate
        let alpha = sin(omega) / (2 * 1.2)
        let cosine = cos(omega)
        let a0 = 1 + alpha / amplitude
        return Self(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosine) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha / amplitude) / a0)
        )
    }
}

/// 均衡器系数快照：渲染核心与测试都要用到，因此不再限制为文件私有。
final class AppVolumeEqualizerConfiguration: @unchecked Sendable {
    let coefficients: [AppVolumeBiquad]

    init(equalizer: AppVolumeEqualizer, sampleRate: Double) {
        coefficients = zip(AppVolumeEqualizer.bandFrequencies, equalizer.gains).map {
            AppVolumeBiquad.peaking(frequency: $0.0, gain: $0.1, sampleRate: sampleRate)
        }
    }
}

private struct AppVolumeBiquadDelay {
    var z1: Float = 0
    var z2: Float = 0
}

/// 均衡器滤波器状态：每个声道每条频带各一份延迟，跨 IOProc 回调保活。
final class AppVolumeEqualizerProcessor: @unchecked Sendable {
    private static let maximumChannels = 16
    private var delays = Array(
        repeating: Array(repeating: AppVolumeBiquadDelay(), count: AppVolumeEqualizer.bandFrequencies.count),
        count: maximumChannels
    )
    private var configurationIdentifier: ObjectIdentifier?

    func process(
        _ sample: Float,
        channel: Int,
        configuration: AppVolumeEqualizerConfiguration?
    ) -> Float {
        guard let configuration else { return sample }
        let identifier = ObjectIdentifier(configuration)
        if configurationIdentifier != identifier {
            resetDelays()
            configurationIdentifier = identifier
        }
        let channelIndex = min(max(channel, 0), Self.maximumChannels - 1)
        var value = sample
        for index in configuration.coefficients.indices {
            let coefficients = configuration.coefficients[index]
            let previous = delays[channelIndex][index]
            let output = coefficients.b0 * value + previous.z1
            delays[channelIndex][index] = AppVolumeBiquadDelay(
                z1: coefficients.b1 * value - coefficients.a1 * output + previous.z2,
                z2: coefficients.b2 * value - coefficients.a2 * output
            )
            value = output
        }
        return value
    }

    private func resetDelays() {
        for channel in delays.indices {
            for band in delays[channel].indices {
                delays[channel][band] = AppVolumeBiquadDelay()
            }
        }
    }
}

private final class InputLevelMonitorState: @unchecked Sendable {
    let peakLevel = Atomic<Float>(0)
}

enum InputLevelSampling {
    static func peakLevel(in samples: UnsafeBufferPointer<Float>) -> Float {
        samples.reduce(into: 0) { peakLevel, sample in
            peakLevel = max(peakLevel, abs(sample))
        }
    }
}

private func makeInputLevelTap(state: InputLevelMonitorState) -> AVAudioNodeTapBlock {
    { buffer, _ in
        guard let channels = buffer.floatChannelData else { return }
        var peakLevel: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = UnsafeBufferPointer(
                start: channels[channel],
                count: Int(buffer.frameLength)
            )
            peakLevel = max(peakLevel, InputLevelSampling.peakLevel(in: samples))
        }
        let existing = state.peakLevel.load(ordering: .relaxed)
        state.peakLevel.store(max(existing, min(peakLevel, 1)), ordering: .relaxed)
    }
}

@MainActor
private final class InputLevelMonitor {
    private let engine = AVAudioEngine()
    private let state = InputLevelMonitorState()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: makeInputLevelTap(state: state)
        )
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
        }
    }

    func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        state.peakLevel.store(0, ordering: .relaxed)
    }

    func consumePeakLevel() -> Double {
        Double(min(max(state.peakLevel.exchange(0, ordering: .relaxed), 0), 1))
    }
}

private final class CoreAudioAppVolumeRoute: @unchecked Sendable {
    private let target: AppVolumeTarget
    private let outputDeviceID: AudioDeviceID
    private let state: AppVolumeRouteState
    private let queue: DispatchQueue
    private var tapID = kAudioObjectUnknown
    private var aggregateDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var stopped = false

    init(
        target: AppVolumeTarget,
        gain: Double,
        equalizer: AppVolumeEqualizer,
        outputDeviceID: AudioDeviceID,
        outputUID: String
    ) throws {
        self.target = target
        self.outputDeviceID = outputDeviceID
        state = AppVolumeRouteState(gain: Float(gain))
        queue = DispatchQueue(
            label: "com.qoder.menutools.app-volume.\(target.rootBundleID)",
            qos: .userInteractive
        )
        do {
            try prepare(outputUID: outputUID, equalizer: equalizer)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func matches(target: AppVolumeTarget, outputDevice: AudioDeviceID) -> Bool {
        self.target.processObjectIDs == target.processObjectIDs && outputDeviceID == outputDevice
    }

    func setProcessing(
        gain: Double,
        equalizer: AppVolumeEqualizer,
        pan: Double,
        isMono: Bool
    ) {
        state.targetGain.store(
            Float(min(max(gain, 0), AppVolumeSafetyPolicy.maximumGain(boostEnabled: true))),
            ordering: .relaxed
        )
        state.setEqualizer(equalizer, sampleRate: sampleRate)
        state.setChannelMix(pan: pan, isMono: isMono)
    }

    func consumeMeter() -> AppVolumeMeter {
        AppVolumeMeter(
            peak: Double(min(max(state.peakLevel.exchange(0, ordering: .relaxed), 0), 1)),
            rms: Double(min(max(state.rmsLevel.exchange(0, ordering: .relaxed), 0), 1)),
            isClipping: state.clipping.exchange(0, ordering: .relaxed) != 0,
            cpuLoad: Double(min(max(state.cpuLoad.exchange(0, ordering: .relaxed), 0), 1))
        )
    }

    func consumePendingFailure() -> AppVolumeTarget? {
        state.failurePending.exchange(false, ordering: .relaxed) ? target : nil
    }

    /// 上次失败是否因为输入输出声道数不一致。
    func consumeLayoutMismatch() -> (input: Int, output: Int)? {
        state.consumeLayoutMismatch()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private var sampleRate = 48_000.0

    private func prepare(outputUID: String, equalizer: AppVolumeEqualizer) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs)
        description.uuid = UUID()
        description.name = "MenuTools · \(target.rootBundleID)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        description.bundleIDs = Array(target.audioBundleIDs)
        guard description.isProcessRestoreEnabled,
              Set(description.bundleIDs) == target.audioBundleIDs else {
            throw AppVolumeRoutingError.operationFailed(
                "CATapDescription configuration",
                kAudioHardwareIllegalOperationError
            )
        }

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            if status == kAudioDevicePermissionsError {
                throw AppVolumeRoutingError.permissionDenied
            }
            throw AppVolumeRoutingError.operationFailed("AudioHardwareCreateProcessTap", status)
        }

        let format: AudioStreamBasicDescription = try CoreAudioProperty.readScalar(
            object: tapID,
            selector: kAudioTapPropertyFormat
        )
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AppVolumeRoutingError.unsupportedFormat
        }
        sampleRate = format.mSampleRate
        state.setEqualizer(equalizer, sampleRate: sampleRate)
        state.setChannelMix(pan: target.pan, isMono: target.isMono)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MenuTools · \(target.rootBundleID)",
            kAudioAggregateDeviceUIDKey: "com.qoder.menutools.app-volume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        var status2 = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status2 == noErr else {
            throw AppVolumeRoutingError.operationFailed("AudioHardwareCreateAggregateDevice", status2)
        }

        let state = self.state
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            if Self.copyAndScale(input: inputData, output: outputData, state: state) {
                state.invalidCallbackCount.store(0, ordering: .relaxed)
                return
            }
            let failures = state.invalidCallbackCount.load(ordering: .relaxed) + 1
            state.invalidCallbackCount.store(failures, ordering: .relaxed)
            guard AppVolumeRouteFailurePolicy.shouldAbort(consecutiveFailures: failures),
                  !state.failureSignaled.exchange(true, ordering: .relaxed) else { return }
            state.failurePending.store(true, ordering: .relaxed)
        }
        status2 = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            queue,
            block
        )
        guard status2 == noErr else {
            throw AppVolumeRoutingError.operationFailed("AudioDeviceCreateIOProcIDWithBlock", status2)
        }
        status2 = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status2 == noErr else {
            throw AppVolumeRoutingError.operationFailed("AudioDeviceStart", status2)
        }
    }

    private static func copyAndScale(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: AppVolumeRouteState
    ) -> Bool {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // 先清零：没有来源的输出声道要靠这个保持静音。
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        guard !outputs.isEmpty else { return false }

        let inputChannels = AppVolumeBufferLayout.totalChannels(inputs)
        let outputChannels = AppVolumeBufferLayout.totalChannels(outputs)
        // tap 一个声道都没给出：这是拿不到数据，不是声道数不一致，报出来供诊断。
        // 声道数不同则由 AppVolumeChannelMap 下混/复制，不再算失败。
        guard inputChannels > 0 else {
            state.noteLayoutMismatch(input: inputChannels, output: outputChannels)
            return false
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let target = state.targetGain.load(ordering: .relaxed)
        guard let stats = AppVolumeRenderCore.render(
            inputs: inputs,
            outputs: outputs,
            currentGain: state.currentGain.load(ordering: .relaxed),
            targetGain: target,
            pan: state.currentPan(),
            isMono: state.isMonoRequested(),
            equalizer: state.equalizerProcessor,
            equalizerConfiguration: state.currentEqualizerConfiguration()
        ) else {
            return false
        }

        state.currentGain.store(target, ordering: .relaxed)
        state.peakLevel.store(
            max(state.peakLevel.load(ordering: .relaxed), min(stats.peak, 1)),
            ordering: .relaxed
        )
        state.rmsLevel.store(
            max(state.rmsLevel.load(ordering: .relaxed), min(stats.rms, 1)),
            ordering: .relaxed
        )
        if stats.isClipping { state.clipping.store(1, ordering: .relaxed) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let frames = min(AppVolumeBufferLayout.frames(inputs), AppVolumeBufferLayout.frames(outputs))
        let bufferDuration = Double(frames) / 48_000
        let load = Float(min(max(elapsed / max(bufferDuration, 0.000_1), 0), 1))
        state.cpuLoad.store(max(state.cpuLoad.load(ordering: .relaxed), load), ordering: .relaxed)
        return true
    }
}

private enum CoreAudioProperty {
    static func deviceList() throws -> [AudioDeviceID] {
        try readObjectIDs(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
    }

    static func readObjectIDs(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try require(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size \(selector)")
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try require(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values),
            "read objects \(selector)"
        )
        return values
    }

    static func processObjectList() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try require(
            AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size),
            "kAudioHardwarePropertyProcessObjectList"
        )
        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        try require(
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, &values),
            "kAudioHardwarePropertyProcessObjectList"
        )
        return values
    }

    static func readScalar<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        try require(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer),
            "read \(selector)"
        )
        return pointer.load(as: T.self)
    }

    static func readString(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try require(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
            "read string \(selector)"
        )
        return value?.takeUnretainedValue() as String? ?? ""
    }

    static func writeScalar<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: T
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = value
        try withUnsafeBytes(of: &value) { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw AppVolumeRoutingError.operationFailed(
                    "write \(selector)",
                    kAudioHardwareIllegalOperationError
                )
            }
            try require(
                AudioObjectSetPropertyData(
                    object,
                    &address,
                    0,
                    nil,
                    UInt32(bytes.count),
                    baseAddress
                ),
                "write \(selector)"
            )
        }
    }

    static func has(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func require(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AppVolumeRoutingError.operationFailed(operation, status)
        }
    }
}
