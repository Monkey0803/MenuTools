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
            outputDeviceUID: target.outputDeviceUID
        ) else {
            removeRoute(for: target.rootBundleID)
            return
        }
        if let failure = failedRoutes[target.rootBundleID] {
            if failure.target == target { throw failure.error }
            failedRoutes.removeValue(forKey: target.rootBundleID)
        }

        let output = try outputDevice(uid: target.outputDeviceUID) ?? readDefaultOutputDevice()
        if let route = routes[target.rootBundleID], route.matches(target: target, outputDevice: output.id) {
            route.setProcessing(gain: volume, equalizer: target.equalizer)
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
            let failed = routes.compactMap { identifier, route in
                route.consumePendingFailure().map { (identifier, $0) }
            }
            for (identifier, target) in failed {
                failedRoutes[identifier] = FailedRoute(target: target, error: .unsupportedFormat)
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
            throw AppVolumeRoutingError.operationFailed(
                L("volume.output.unavailable"),
                kAudioHardwareBadDeviceError
            )
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

private struct AppVolumeBiquad: Sendable {
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

private final class AppVolumeEqualizerConfiguration: @unchecked Sendable {
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

private final class AppVolumeEqualizerProcessor: @unchecked Sendable {
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

    func setProcessing(gain: Double, equalizer: AppVolumeEqualizer) {
        state.targetGain.store(
            Float(min(max(gain, 0), AppVolumeSafetyPolicy.maximumGain(boostEnabled: true))),
            ordering: .relaxed
        )
        state.setEqualizer(equalizer, sampleRate: sampleRate)
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
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        guard inputs.count == outputs.count, !outputs.isEmpty else { return false }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let target = state.targetGain.load(ordering: .relaxed)
        let equalizerConfiguration = state.currentEqualizerConfiguration()
        var current = state.currentGain.load(ordering: .relaxed)
        var peak: Float = 0
        var sumSquares: Double = 0
        var sampleCount = 0
        var isClipping = false
        var frames = Int.max
        for buffer in outputs {
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        }
        if frames == Int.max { frames = 0 }
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
                let scaled = source[sample] * gain
                let channel = outputs.count == 1
                    ? sample % max(Int(outputBuffer.mNumberChannels), 1)
                    : index
                let processed = state.equalizerProcessor.process(
                    scaled,
                    channel: channel,
                    configuration: equalizerConfiguration
                )
                peak = max(peak, abs(processed))
                sumSquares += Double(processed * processed)
                sampleCount += 1
                isClipping = isClipping || abs(processed) > 1
                destination[sample] = min(max(processed, -1), 1)
            }
        }
        current = target
        state.currentGain.store(current, ordering: .relaxed)
        state.peakLevel.store(max(state.peakLevel.load(ordering: .relaxed), min(peak, 1)), ordering: .relaxed)
        let rms = sampleCount == 0 ? 0 : Float(sqrt(sumSquares / Double(sampleCount)))
        state.rmsLevel.store(max(state.rmsLevel.load(ordering: .relaxed), min(rms, 1)), ordering: .relaxed)
        if isClipping { state.clipping.store(1, ordering: .relaxed) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
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
