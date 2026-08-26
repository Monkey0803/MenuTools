import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

@MainActor
final class CoreAudioAppVolumeBackend: AppVolumeRoutingBackend {
    private struct FailedRoute {
        var target: AppVolumeTarget
        var error: AppVolumeRoutingError
    }

    var onSnapshot: ((AppVolumeBackendSnapshot) -> Void)?

    private var routes: [String: CoreAudioAppVolumeRoute] = [:]
    private var failedRoutes: [String: FailedRoute] = [:]
    private var refreshTimer: Timer?
    private var currentOutputDevice = kAudioObjectUnknown
    private var currentOutputUID = ""

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
    }

    func apply(volume: Double, to target: AppVolumeTarget) throws {
        guard volume < 0.999 else {
            removeRoute(for: target.rootBundleID)
            return
        }
        if let failure = failedRoutes[target.rootBundleID] {
            if failure.target == target { throw failure.error }
            failedRoutes.removeValue(forKey: target.rootBundleID)
        }

        let output = try readDefaultOutputDevice()
        if let route = routes[target.rootBundleID], route.matches(target: target, outputDevice: output.id) {
            route.setGain(volume)
            return
        }

        removeRoute(for: target.rootBundleID)
        do {
            let route = try CoreAudioAppVolumeRoute(
                target: target,
                gain: volume,
                outputDeviceID: output.id,
                outputUID: output.uid
            ) { [weak self] identifier, error in
                Task { @MainActor [weak self] in
                    self?.handleRouteFailure(identifier: identifier, target: target, error: error)
                }
            }
            routes[target.rootBundleID] = route
        } catch let error as AppVolumeRoutingError {
            failedRoutes[target.rootBundleID] = FailedRoute(target: target, error: error)
            throw error
        }
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

    private func refresh() {
        do {
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
                    output: try readOutputState(device: outputDevice.id)
                )
            )
        } catch {
            onSnapshot?(
                AppVolumeBackendSnapshot(candidates: [], output: .unavailable)
            )
        }
    }

    private func handleRouteFailure(
        identifier: String,
        target: AppVolumeTarget,
        error: AppVolumeRoutingError
    ) {
        failedRoutes[identifier] = FailedRoute(target: target, error: error)
        stopRoute(for: identifier)
        refresh()
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

    private func firstReadable<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> T? {
        for element in Self.volumeElements where CoreAudioProperty.has(
            object: object,
            selector: selector,
            scope: kAudioDevicePropertyScopeOutput,
            element: element
        ) {
            return try CoreAudioProperty.readScalar(
                object: object,
                selector: selector,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            )
        }
        return nil
    }

    private func setFirstSupported<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        value: T
    ) throws -> Bool {
        var wrote = false
        for element in Self.volumeElements where CoreAudioProperty.isSettable(
            object: object,
            selector: selector,
            scope: kAudioDevicePropertyScopeOutput,
            element: element
        ) {
            try CoreAudioProperty.writeScalar(
                object: object,
                selector: selector,
                scope: kAudioDevicePropertyScopeOutput,
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
        selector: AudioObjectPropertySelector
    ) -> Bool {
        Self.volumeElements.contains {
            CoreAudioProperty.isSettable(
                object: object,
                selector: selector,
                scope: kAudioDevicePropertyScopeOutput,
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

private final class AppVolumeRouteState: @unchecked Sendable {
    let targetGain: Atomic<Float>
    let currentGain: Atomic<Float>
    let invalidCallbackCount = Atomic(0)
    let failureSignaled = Atomic(false)

    init(gain: Float) {
        targetGain = Atomic(gain)
        currentGain = Atomic(gain)
    }
}

private final class CoreAudioAppVolumeRoute: @unchecked Sendable {
    private let target: AppVolumeTarget
    private let outputDeviceID: AudioDeviceID
    private let failureHandler: @Sendable (String, AppVolumeRoutingError) -> Void
    private let state: AppVolumeRouteState
    private let queue: DispatchQueue
    private var tapID = kAudioObjectUnknown
    private var aggregateDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var stopped = false

    init(
        target: AppVolumeTarget,
        gain: Double,
        outputDeviceID: AudioDeviceID,
        outputUID: String,
        failureHandler: @escaping @Sendable (String, AppVolumeRoutingError) -> Void
    ) throws {
        self.target = target
        self.outputDeviceID = outputDeviceID
        self.failureHandler = failureHandler
        state = AppVolumeRouteState(gain: Float(gain))
        queue = DispatchQueue(
            label: "com.qoder.menutools.app-volume.\(target.rootBundleID)",
            qos: .userInteractive
        )
        do {
            try prepare(outputUID: outputUID)
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

    func setGain(_ gain: Double) {
        state.targetGain.store(Float(min(max(gain, 0), 1)), ordering: .relaxed)
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

    private func prepare(outputUID: String) throws {
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
        let identifier = target.rootBundleID
        let failureHandler = self.failureHandler
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            if Self.copyAndScale(input: inputData, output: outputData, state: state) {
                state.invalidCallbackCount.store(0, ordering: .relaxed)
                return
            }
            let failures = state.invalidCallbackCount.load(ordering: .relaxed) + 1
            state.invalidCallbackCount.store(failures, ordering: .relaxed)
            guard AppVolumeRouteFailurePolicy.shouldAbort(consecutiveFailures: failures),
                  !state.failureSignaled.exchange(true, ordering: .relaxed) else { return }
            failureHandler(identifier, .unsupportedFormat)
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
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        guard inputs.count == outputs.count, !outputs.isEmpty else { return false }

        let target = state.targetGain.load(ordering: .relaxed)
        var current = state.currentGain.load(ordering: .relaxed)
        let frames = outputs.map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }.min() ?? 0
        guard frames > 0 else { return false }
        let step = (target - current) / Float(frames)

        for index in inputs.indices {
            let inputBuffer = inputs[index]
            let outputBuffer = outputs[index]
            guard inputBuffer.mDataByteSize == outputBuffer.mDataByteSize,
                  let source = inputBuffer.mData?.assumingMemoryBound(to: Float.self),
                  let destination = outputBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                return false
            }
            var gain = current
            let count = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for sample in 0..<count {
                gain += step
                destination[sample] = min(max(source[sample] * gain, -1), 1)
            }
        }
        current = target
        state.currentGain.store(current, ordering: .relaxed)
        return true
    }
}

private enum CoreAudioProperty {
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
