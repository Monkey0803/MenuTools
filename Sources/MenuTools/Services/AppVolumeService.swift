import AppKit
import CoreAudio
import Foundation
import Observation

struct AppVolumeProfile: Codable, Equatable, Sendable {
    var rootBundleID: String
    var displayName: String
    var bundleURL: URL? = nil
    var volume: Double
    var lastNonzeroVolume: Double
    var audioBundleIDs: Set<String>
    var lastAdjustedAt: Date
    var isFavorite = false
    var appGroup: AppVolumeAppGroup? = nil
    var equalizer: AppVolumeEqualizer = .flat
    var outputDeviceUID: String? = nil

    func normalized(maximumGain: Double = 1) -> Self {
        var copy = self
        let limit = AppVolumeSafetyPolicy.normalizedMaximumGain(maximumGain)
        copy.volume = copy.volume.isFinite ? min(max(copy.volume, 0), limit) : 1
        if !copy.lastNonzeroVolume.isFinite || copy.lastNonzeroVolume <= 0 {
            copy.lastNonzeroVolume = copy.volume > 0 ? copy.volume : 1
        }
        copy.lastNonzeroVolume = min(max(copy.lastNonzeroVolume, 0.01), limit)
        copy.audioBundleIDs.remove("")
        copy.equalizer = copy.equalizer.normalized()
        copy.outputDeviceUID = copy.outputDeviceUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.outputDeviceUID?.isEmpty == true { copy.outputDeviceUID = nil }
        return copy
    }
}

extension AppVolumeProfile {
    private enum CodingKeys: String, CodingKey {
        case rootBundleID
        case displayName
        case bundleURL
        case volume
        case lastNonzeroVolume
        case audioBundleIDs
        case lastAdjustedAt
        case isFavorite
        case appGroup
        case equalizer
        case outputDeviceUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootBundleID = try container.decode(String.self, forKey: .rootBundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleURL = try container.decodeIfPresent(URL.self, forKey: .bundleURL)
        volume = try container.decode(Double.self, forKey: .volume)
        lastNonzeroVolume = try container.decode(Double.self, forKey: .lastNonzeroVolume)
        audioBundleIDs = try container.decode(Set<String>.self, forKey: .audioBundleIDs)
        lastAdjustedAt = try container.decode(Date.self, forKey: .lastAdjustedAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        appGroup = try container.decodeIfPresent(AppVolumeAppGroup.self, forKey: .appGroup)
        equalizer = try container.decodeIfPresent(AppVolumeEqualizer.self, forKey: .equalizer) ?? .flat
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
    }
}

enum AppVolumeSafetyPolicy {
    static func maximumGain(boostEnabled: Bool) -> Double {
        boostEnabled ? 1.5 : 1
    }

    static func normalizedMaximumGain(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 1, 1), 1.5)
    }

    static func clamp(_ value: Double, boostEnabled: Bool) -> Double {
        min(max(value.isFinite ? value : 1, 0), maximumGain(boostEnabled: boostEnabled))
    }

    static func requiresRoute(
        for gain: Double,
        equalizer: AppVolumeEqualizer = .flat,
        outputDeviceUID: String? = nil
    ) -> Bool {
        abs(gain - 1) > 0.001 || equalizer.requiresProcessing || outputDeviceUID != nil
    }
}

enum AppVolumeEqualizerPreset: String, CaseIterable, Codable, Sendable {
    case flat
    case bassBoost
    case bassCut
    case trebleBoost
    case vocalClarity
    case podcast
    case spokenWord
    case loudness
    case lateNight
    case smallSpeakers

    var titleKey: String { "volume.equalizer.preset.\(rawValue)" }

    var gains: [Double] {
        switch self {
        case .flat: Array(repeating: 0, count: AppVolumeEqualizer.bandFrequencies.count)
        case .bassBoost: [8, 7, 5, 3, 1, 0, 0, 0, 0]
        case .bassCut: [-7, -6, -4, -2, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 1, 3, 5, 7, 8]
        case .vocalClarity: [-2, -1, 1, 3, 4, 4, 3, 1, 0]
        case .podcast: [-4, -2, 1, 4, 5, 4, 2, 0, -2]
        case .spokenWord: [-6, -3, 0, 3, 5, 4, 2, 0, -3]
        case .loudness: [5, 4, 2, 0, -1, 0, 2, 4, 5]
        case .lateNight: [3, 2, 1, 0, 0, 1, 2, 2, 1]
        case .smallSpeakers: [-4, -2, 1, 3, 2, 1, 2, 3, 2]
        }
    }
}

struct AppVolumeEqualizer: Codable, Equatable, Sendable {
    static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000]
    static let minimumGain = -12.0
    static let maximumGain = 12.0

    var isEnabled: Bool
    var gains: [Double]

    init(isEnabled: Bool = false, gains: [Double] = Array(repeating: 0, count: bandFrequencies.count)) {
        self.isEnabled = isEnabled
        self.gains = gains
        self = normalized()
    }

    static let flat = AppVolumeEqualizer()

    var requiresProcessing: Bool {
        isEnabled && gains.contains { abs($0) > 0.001 }
    }

    func gain(at index: Int) -> Double {
        guard gains.indices.contains(index) else { return 0 }
        return gains[index]
    }

    var matchingPreset: AppVolumeEqualizerPreset? {
        AppVolumeEqualizerPreset.allCases.first { $0.gains == gains }
    }

    func normalized() -> Self {
        var copy = self
        let normalizedGains = gains.prefix(Self.bandFrequencies.count).map {
            min(max($0.isFinite ? $0 : 0, Self.minimumGain), Self.maximumGain)
        }
        copy.gains = normalizedGains + Array(repeating: 0, count: Self.bandFrequencies.count - normalizedGains.count)
        return copy
    }
}

enum AppVolumeHearingSafetyPolicy {
    static func isHeadphone(deviceName: String) -> Bool {
        let value = deviceName.lowercased()
        return ["airpods", "headphone", "headset", "耳机", "耳機"].contains(where: value.contains)
    }
}

enum AppVolumeAppGroup: String, CaseIterable, Codable, Sendable {
    case browser
    case meeting
    case game
    case other

    var titleKey: String { "volume.group.\(rawValue)" }

    static func inferred(bundleID: String, displayName: String) -> Self {
        let value = "\(bundleID) \(displayName)".lowercased()
        if ["safari", "chrome", "firefox", "edge", "arc", "opera", "brave"].contains(where: value.contains) {
            return .browser
        }
        if ["zoom", "teams", "slack", "discord", "facetime", "webex", "meeting"].contains(where: value.contains) {
            return .meeting
        }
        if ["steam", "game", "epicgames", "minecraft", "leagueoflegends"].contains(where: value.contains) {
            return .game
        }
        return .other
    }
}

enum AppVolumeSessionSort: String, CaseIterable, Codable, Sendable {
    case recent
    case volume
    case name

    var titleKey: String { "volume.sort.\(rawValue)" }
}

struct AppVolumeMeter: Equatable, Sendable {
    var peak: Double = 0
    var rms: Double = 0
    var heldPeak: Double = 0
    var isClipping = false
    var cpuLoad: Double = 0

    static let empty = Self()
}

enum AppVolumeRouteStatus: Hashable, Sendable {
    case bypassed
    case active
    case failed
    case unavailable
}

struct AppAudioProcessCandidate: Equatable, Sendable {
    var processObjectID: AudioObjectID
    var processID: pid_t
    var audioBundleID: String
    var rootBundleID: String
    var displayName: String
    var bundleURL: URL?
    var isRunningOutput: Bool
}

struct AppVolumeTarget: Equatable, Sendable {
    var rootBundleID: String
    var processObjectIDs: [AudioObjectID]
    var audioBundleIDs: Set<String>
    var equalizer: AppVolumeEqualizer = .flat
    var outputDeviceUID: String? = nil
}

struct AppAudioSession: Identifiable, Equatable, Sendable {
    var id: String { rootBundleID }
    var rootBundleID: String
    var displayName: String
    var bundleURL: URL?
    var processObjectIDs: [AudioObjectID]
    var audioBundleIDs: Set<String>
    var isRunningOutput: Bool
    var volume: Double
    var lastAdjustedAt: Date
    var errorMessage: String?
    var isFavorite = false
    var appGroup: AppVolumeAppGroup = .other
    var meter: AppVolumeMeter = .empty
    var routeStatus: AppVolumeRouteStatus = .bypassed
    var equalizer: AppVolumeEqualizer = .flat
    var outputDeviceUID: String? = nil

    var target: AppVolumeTarget {
        AppVolumeTarget(
            rootBundleID: rootBundleID,
            processObjectIDs: processObjectIDs,
            audioBundleIDs: audioBundleIDs,
            equalizer: equalizer,
            outputDeviceUID: outputDeviceUID
        )
    }

    static func group(
        candidates: [AppAudioProcessCandidate],
        profiles: [String: AppVolumeProfile],
        maximumGain: Double = 1
    ) -> [Self] {
        let grouped = Dictionary(grouping: candidates, by: \AppAudioProcessCandidate.rootBundleID)
        let activeIdentifiers = grouped.compactMap { identifier, processes in
            processes.contains(where: \.isRunningOutput) ? identifier : nil
        }
        let identifiers = Set(activeIdentifiers).union(profiles.keys)

        return identifiers.compactMap { identifier in
            let processes = grouped[identifier] ?? []
            let profile = profiles[identifier]?.normalized(maximumGain: maximumGain)
            guard !processes.isEmpty || profile != nil else { return nil }
            let first = processes.first
            let audioBundleIDs = Set(processes.map(\.audioBundleID))
                .union(profile?.audioBundleIDs ?? [])
            return Self(
                rootBundleID: identifier,
                displayName: first?.displayName ?? profile?.displayName ?? identifier,
                bundleURL: processes.lazy.compactMap(\.bundleURL).first ?? profile?.bundleURL,
                processObjectIDs: processes.map(\.processObjectID).sorted(),
                audioBundleIDs: audioBundleIDs,
                isRunningOutput: processes.contains(where: \.isRunningOutput),
                volume: profile?.volume ?? 1,
                lastAdjustedAt: profile?.lastAdjustedAt ?? .distantPast,
                errorMessage: nil,
                isFavorite: profile?.isFavorite ?? false,
                appGroup: profile?.appGroup ?? AppVolumeAppGroup.inferred(
                    bundleID: identifier,
                    displayName: first?.displayName ?? profile?.displayName ?? identifier
                ),
                equalizer: profile?.equalizer ?? .flat,
                outputDeviceUID: profile?.outputDeviceUID
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            if $0.lastAdjustedAt != $1.lastAdjustedAt { return $0.lastAdjustedAt > $1.lastAdjustedAt }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

struct SystemOutputVolumeState: Equatable, Sendable {
    var deviceID: AudioDeviceID
    var deviceUID = ""
    var deviceName: String
    var volume: Double
    var isMuted: Bool
    var canSetVolume: Bool
    var canSetMute: Bool

    static let unavailable = Self(
        deviceID: kAudioObjectUnknown,
        deviceUID: "",
        deviceName: "",
        volume: 1,
        isMuted: false,
        canSetVolume: false,
        canSetMute: false
    )
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var isDefault: Bool
}

struct SystemInputVolumeState: Equatable, Sendable {
    var deviceID: AudioDeviceID
    var deviceUID = ""
    var deviceName: String
    var volume: Double
    var isMuted: Bool
    var canSetVolume: Bool
    var canSetMute: Bool
    var peakLevel = 0.0

    static let unavailable = Self(
        deviceID: kAudioObjectUnknown,
        deviceUID: "",
        deviceName: "",
        volume: 1,
        isMuted: false,
        canSetVolume: false,
        canSetMute: false
    )
}

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var isDefault: Bool
}

enum AppVolumeSessionFilter: String, CaseIterable, Codable, Sendable {
    case all
    case active
    case favorites
}

struct AppVolumePreset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var masterVolume: Double
    var appVolumes: [String: Double]
    var createdAt: Date
    var updatedAt: Date? = nil
}

struct AppVolumeAutomationRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var presetID: UUID
    var outputDeviceUID: String?
    var isEnabled: Bool
    var startMinute: Int? = nil
    var endMinute: Int? = nil
    var requiresFocusMode: Bool? = nil
    var launchBundleID: String? = nil
    var wifiName: String? = nil

    func matches(outputDeviceUID: String) -> Bool {
        isEnabled && (self.outputDeviceUID == nil || self.outputDeviceUID == outputDeviceUID)
    }

    func matches(_ context: AppVolumeAutomationContext) -> Bool {
        guard matches(outputDeviceUID: context.outputDeviceUID) else { return false }
        if let requiresFocusMode, context.isFocusModeEnabled != requiresFocusMode { return false }
        if let launchBundleID, context.frontmostBundleID != launchBundleID { return false }
        if let wifiName, context.wifiName != wifiName { return false }
        guard let startMinute, let endMinute else { return true }
        let minute = context.minuteOfDay
        if startMinute <= endMinute {
            return minute >= startMinute && minute <= endMinute
        }
        return minute >= startMinute || minute <= endMinute
    }
}

struct AppVolumeAutomationContext: Equatable, Sendable {
    var date: Date
    var outputDeviceUID: String
    var isFocusModeEnabled: Bool?
    var frontmostBundleID: String?
    var wifiName: String?

    var minuteOfDay: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

struct AppVolumePresetArchive: Codable, Equatable, Sendable {
    var version: Int
    var presets: [AppVolumePreset]
    var automationRules: [AppVolumeAutomationRule]
}

struct AppVolumeConfigurationSnapshot: Codable, Equatable, Sendable {
    var masterVolume: Double
    var appVolumes: [String: Double]
}

private struct AppVolumeDuckingState: Codable, Equatable, Sendable {
    var originalVolume: Double
    var duckedVolume: Double
    var needsDucking: Bool
}

struct AppVolumeAutomationExecution: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var ruleID: UUID
    var presetID: UUID
    var presetName: String
    var outputDeviceName: String
    var outputDeviceUID: String? = nil
    var executedAt: Date
    var revertedAt: Date? = nil
}

enum AppVolumePresetTransferError: LocalizedError, Equatable {
    case invalidArchive

    var errorDescription: String? { L("volume.error.presetArchive") }
}

struct AppVolumeMeetingCheck: Equatable, Sendable {
    var outputReady: Bool
    var inputReady: Bool
    var inputMuted: Bool
    var inputLevelAvailable: Bool

    var isReady: Bool { outputReady && inputReady && !inputMuted }
}

struct AppVolumeBackendSnapshot: Equatable, Sendable {
    var candidates: [AppAudioProcessCandidate]
    var output: SystemOutputVolumeState
    var input: SystemInputVolumeState = .unavailable
    var levels: [String: AppVolumeMeter] = [:]
}

enum AppVolumePermissionState: Equatable, Sendable {
    case notRequested
    case authorized
    case denied
}

enum AppVolumeRoutingError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case unsupportedFormat
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L("volume.error.permission")
        case .unsupportedFormat:
            return L("volume.error.format")
        case .operationFailed(let operation, let status):
            return L("volume.error.operation", operation, status)
        }
    }
}

@MainActor
protocol AppVolumeRoutingBackend: AnyObject {
    var onSnapshot: ((AppVolumeBackendSnapshot) -> Void)? { get set }
    func start()
    func stop()
    func startInputLevelMonitoring()
    func stopInputLevelMonitoring()
    func apply(volume: Double, to target: AppVolumeTarget) throws
    func removeRoute(for rootBundleID: String)
    func setMasterVolume(_ volume: Double) throws
    func setMasterMuted(_ muted: Bool) throws
    func availableOutputDevices() throws -> [AudioOutputDevice]
    func selectOutputDevice(_ device: AudioOutputDevice) throws
    func availableInputDevices() throws -> [AudioInputDevice]
    func selectInputDevice(_ device: AudioInputDevice) throws
    func setInputVolume(_ volume: Double) throws
    func setInputMuted(_ muted: Bool) throws
}

extension AppVolumeRoutingBackend {
    func startInputLevelMonitoring() {}
    func stopInputLevelMonitoring() {}

    func availableOutputDevices() throws -> [AudioOutputDevice] { [] }

    func selectOutputDevice(_ device: AudioOutputDevice) throws {
        throw AppVolumeRoutingError.operationFailed("select output", kAudioHardwareUnsupportedOperationError)
    }

    func availableInputDevices() throws -> [AudioInputDevice] { [] }

    func selectInputDevice(_ device: AudioInputDevice) throws {
        throw AppVolumeRoutingError.operationFailed("select input", kAudioHardwareUnsupportedOperationError)
    }

    func setInputVolume(_ volume: Double) throws {
        throw AppVolumeRoutingError.operationFailed("set input volume", kAudioHardwareUnsupportedOperationError)
    }

    func setInputMuted(_ muted: Bool) throws {
        throw AppVolumeRoutingError.operationFailed("set input mute", kAudioHardwareUnsupportedOperationError)
    }
}

enum AppVolumeDSP {
    @discardableResult
    static func applyGain(to samples: inout [Float], from start: Float, to target: Float) -> Float {
        guard !samples.isEmpty else { return target }
        let step = (target - start) / Float(samples.count)
        var gain = start
        for index in samples.indices {
            gain += step
            samples[index] = min(max(samples[index] * gain, -1), 1)
        }
        return target
    }
}

@MainActor
@Observable
final class AppVolumeService {
    private enum RouteApplicationResult {
        case applied
        case permissionDenied
        case failed
    }

    static let shared = AppVolumeService(
        backend: CoreAudioAppVolumeBackend(),
        userDefaults: .standard
    )

    private(set) var sessions: [AppAudioSession] = []
    private(set) var output: SystemOutputVolumeState = .unavailable
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var input: SystemInputVolumeState = .unavailable
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var permissionState: AppVolumePermissionState = .notRequested
    private(set) var errorMessage: String?
    private(set) var isStarted = false
    private(set) var isEnabled: Bool
    private(set) var volumeStep: Double
    private(set) var sessionFilter: AppVolumeSessionFilter
    private(set) var isBoostEnabled: Bool
    private(set) var presets: [AppVolumePreset]
    private(set) var automationRules: [AppVolumeAutomationRule]
    private(set) var appGroupFilter: AppVolumeAppGroup?
    private(set) var sessionSort: AppVolumeSessionSort
    private(set) var searchQuery: String
    private(set) var masterVolumeLimit: Double
    private(set) var limitsHeadphoneVolume: Bool
    private(set) var hearingWarningMessage: String? = nil
    private(set) var meetingCheck: AppVolumeMeetingCheck? = nil
    private(set) var automationExecutions: [AppVolumeAutomationExecution]
    private(set) var meetingDuckingEnabled: Bool
    private(set) var meetingDuckingFactor: Double
    private(set) var isMeetingDuckingActive = false
    private(set) var devicePresetBindings: [String: UUID]

    var canUndoLatestAutomation: Bool { latestAutomationUndo != nil }

    var hasProfiles: Bool { !profiles.isEmpty }
    var maximumAppGain: Double { AppVolumeSafetyPolicy.maximumGain(boostEnabled: isBoostEnabled) }
    var filteredSessions: [AppAudioSession] {
        var result = switch sessionFilter {
        case .all: sessions
        case .active: sessions.filter(\.isRunningOutput)
        case .favorites: sessions.filter(\.isFavorite)
        }
        if let appGroupFilter {
            result = result.filter { $0.appGroup == appGroupFilter }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.rootBundleID.localizedCaseInsensitiveContains(query)
            }
        }
        switch sessionSort {
        case .recent:
            return result.sorted { $0.lastAdjustedAt > $1.lastAdjustedAt }
        case .volume:
            return result.sorted { $0.volume > $1.volume }
        case .name:
            return result.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    private let backend: AppVolumeRoutingBackend
    private let userDefaults: UserDefaults
    private let networkStatusService: NetworkStatusService
    private var profiles: [String: AppVolumeProfile]
    private var candidates: [AppAudioProcessCandidate] = []
    private var outputVolumeMemory: [String: Double]
    private var pendingOutputDeviceUID: String?
    private var appliedAutomationKeys: Set<String> = []
    private var isApplyingPreset = false
    private var automationTimer: Timer?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastExposureDate: Date?
    private var highVolumeExposure: TimeInterval = 0
    private var isApplyingHearingLimit = false
    private var latestAutomationUndo: (executionID: UUID, snapshot: AppVolumeConfigurationSnapshot)?
    private var duckedVolumes: [String: AppVolumeDuckingState] = [:]
    private var isApplyingMeetingDucking = false

    init(backend: AppVolumeRoutingBackend, userDefaults: UserDefaults) {
        self.backend = backend
        self.userDefaults = userDefaults
        networkStatusService = NetworkStatusService()
        isEnabled = userDefaults.bool(forKey: StorageKey.enabled)
        let boostEnabled = userDefaults.bool(forKey: StorageKey.boostEnabled)
        isBoostEnabled = boostEnabled
        profiles = Self.loadProfiles(
            from: userDefaults,
            maximumGain: AppVolumeSafetyPolicy.maximumGain(boostEnabled: boostEnabled)
        )
        outputVolumeMemory = Self.loadOutputVolumeMemory(from: userDefaults)
        volumeStep = Self.loadVolumeStep(from: userDefaults)
        sessionFilter = Self.loadSessionFilter(from: userDefaults)
        presets = Self.loadPresets(from: userDefaults)
        automationRules = Self.loadAutomationRules(from: userDefaults)
        appGroupFilter = Self.loadAppGroupFilter(from: userDefaults)
        sessionSort = Self.loadSessionSort(from: userDefaults)
        searchQuery = userDefaults.string(forKey: StorageKey.searchQuery) ?? ""
        masterVolumeLimit = Self.loadMasterVolumeLimit(from: userDefaults)
        limitsHeadphoneVolume = userDefaults.object(forKey: StorageKey.limitsHeadphoneVolume) as? Bool ?? true
        let loadedAutomationExecutions = Self.loadAutomationExecutions(from: userDefaults)
        let loadedDuckedVolumes = Self.loadDuckedVolumes(
            from: userDefaults,
            maximumGain: AppVolumeSafetyPolicy.maximumGain(boostEnabled: boostEnabled)
        )
        automationExecutions = loadedAutomationExecutions
        appliedAutomationKeys = Self.automationApplicationKeys(from: loadedAutomationExecutions)
        meetingDuckingEnabled = userDefaults.object(forKey: StorageKey.meetingDuckingEnabled) as? Bool ?? true
        meetingDuckingFactor = Self.loadMeetingDuckingFactor(from: userDefaults)
        duckedVolumes = loadedDuckedVolumes
        isMeetingDuckingActive = !loadedDuckedVolumes.isEmpty
        devicePresetBindings = Self.loadDevicePresetBindings(from: userDefaults)
        permissionState = userDefaults.bool(forKey: StorageKey.permissionGranted)
            ? .authorized
            : .notRequested
        backend.onSnapshot = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        rebuildSessions()
        refreshOutputDevices()
        refreshInputDevices()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        backend.start()
        refreshOutputDevices()
        refreshInputDevices()
        startAutomationMonitoring()
    }

    func startInputLevelMonitoring() {
        guard isStarted else { return }
        backend.startInputLevelMonitoring()
    }

    func stopInputLevelMonitoring() {
        backend.stopInputLevelMonitoring()
    }

    func stop() {
        guard isStarted else { return }
        sessions.forEach { backend.removeRoute(for: $0.rootBundleID) }
        backend.stop()
        stopAutomationMonitoring()
        isStarted = false
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKey.enabled)
        errorMessage = nil
        if enabled {
            reconcileRoutes()
        } else {
            sessions.forEach { backend.removeRoute(for: $0.rootBundleID) }
            for index in sessions.indices {
                sessions[index].errorMessage = nil
            }
        }
    }

    func session(id: String) -> AppAudioSession? {
        sessions.first { $0.rootBundleID == id }
    }

    func refreshOutputDevices() {
        do {
            outputDevices = try backend.availableOutputDevices()
        } catch {
            outputDevices = []
        }
    }

    func refreshInputDevices() {
        do {
            inputDevices = try backend.availableInputDevices()
        } catch {
            inputDevices = []
        }
    }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        do {
            pendingOutputDeviceUID = device.uid
            try backend.selectOutputDevice(device)
            refreshOutputDevices()
            errorMessage = nil
        } catch {
            pendingOutputDeviceUID = nil
            errorMessage = error.localizedDescription
        }
    }

    func selectInputDevice(_ device: AudioInputDevice) {
        do {
            try backend.selectInputDevice(device)
            refreshInputDevices()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setVolumeStep(_ requestedStep: Double) {
        volumeStep = min(max(requestedStep.isFinite ? requestedStep : 0.05, 0.01), 0.25)
        userDefaults.set(volumeStep, forKey: StorageKey.volumeStep)
    }

    func adjustMasterVolume(increase: Bool) {
        let direction = increase ? 1.0 : -1.0
        setMasterVolume(output.volume + direction * volumeStep)
    }

    func setSessionFilter(_ filter: AppVolumeSessionFilter) {
        sessionFilter = filter
        userDefaults.set(filter.rawValue, forKey: StorageKey.sessionFilter)
    }

    func setAppGroupFilter(_ group: AppVolumeAppGroup?) {
        appGroupFilter = group
        userDefaults.set(group?.rawValue, forKey: StorageKey.appGroupFilter)
    }

    func setSessionSort(_ sort: AppVolumeSessionSort) {
        sessionSort = sort
        userDefaults.set(sort.rawValue, forKey: StorageKey.sessionSort)
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
        userDefaults.set(query, forKey: StorageKey.searchQuery)
    }

    func setAppGroup(_ group: AppVolumeAppGroup, for rootBundleID: String) {
        guard let session = session(id: rootBundleID) else { return }
        var profile = profiles[rootBundleID] ?? AppVolumeProfile(
            rootBundleID: rootBundleID,
            displayName: session.displayName,
            bundleURL: session.bundleURL,
            volume: session.volume,
            lastNonzeroVolume: session.volume > 0 ? session.volume : 1,
            audioBundleIDs: session.audioBundleIDs,
            lastAdjustedAt: session.lastAdjustedAt
        )
        profile.appGroup = group
        profiles[rootBundleID] = profile.normalized(maximumGain: maximumAppGain)
        persistProfiles()
        rebuildSessions()
    }

    func setEqualizerEnabled(_ enabled: Bool, for rootBundleID: String) {
        updateAudioProcessingProfile(for: rootBundleID) { profile in
            profile.equalizer.isEnabled = enabled
        }
    }

    func setEqualizerGain(_ requestedGain: Double, at index: Int, for rootBundleID: String) {
        guard AppVolumeEqualizer.bandFrequencies.indices.contains(index) else { return }
        updateAudioProcessingProfile(for: rootBundleID) { profile in
            var equalizer = profile.equalizer.normalized()
            equalizer.gains[index] = min(max(
                requestedGain.isFinite ? requestedGain : 0,
                AppVolumeEqualizer.minimumGain
            ), AppVolumeEqualizer.maximumGain)
            profile.equalizer = equalizer
        }
    }

    func setEqualizerPreset(_ preset: AppVolumeEqualizerPreset, for rootBundleID: String) {
        updateAudioProcessingProfile(for: rootBundleID) { profile in
            profile.equalizer = AppVolumeEqualizer(
                isEnabled: preset != .flat,
                gains: preset.gains
            )
        }
    }

    func setOutputDevice(_ device: AudioOutputDevice?, for rootBundleID: String) {
        updateAudioProcessingProfile(for: rootBundleID) { profile in
            profile.outputDeviceUID = device?.uid
        }
    }

    func muteFilteredSessions() {
        let identifiers = filteredSessions.map(\.rootBundleID)
        identifiers.forEach { setVolume(0, for: $0) }
    }

    private func updateAudioProcessingProfile(
        for rootBundleID: String,
        update: (inout AppVolumeProfile) -> Void
    ) {
        guard let session = session(id: rootBundleID) else { return }
        let previousProfile = profiles[rootBundleID]
        var profile = profiles[rootBundleID] ?? AppVolumeProfile(
            rootBundleID: rootBundleID,
            displayName: session.displayName,
            bundleURL: session.bundleURL,
            volume: session.volume,
            lastNonzeroVolume: session.volume > 0 ? session.volume : 1,
            audioBundleIDs: session.audioBundleIDs,
            lastAdjustedAt: session.lastAdjustedAt
        )
        profile.displayName = session.displayName
        profile.bundleURL = session.bundleURL ?? profile.bundleURL
        profile.audioBundleIDs.formUnion(session.audioBundleIDs)
        update(&profile)
        profiles[rootBundleID] = profile.normalized(maximumGain: maximumAppGain)
        persistProfiles()
        rebuildSessions()
        guard applyCurrentProfile(for: rootBundleID) == .permissionDenied else { return }

        if let previousProfile {
            profiles[rootBundleID] = previousProfile
        } else {
            profiles.removeValue(forKey: rootBundleID)
        }
        persistProfiles()
        rebuildSessions()
    }

    func restoreFilteredSessions() {
        let identifiers = filteredSessions.map(\.rootBundleID)
        identifiers.forEach { identifier in
            guard session(id: identifier)?.volume == 0 else { return }
            setVolume(profiles[identifier]?.lastNonzeroVolume ?? 1, for: identifier)
        }
    }

    func toggleFavorite(for rootBundleID: String) {
        guard let session = session(id: rootBundleID) else { return }
        var profile = profiles[rootBundleID] ?? AppVolumeProfile(
            rootBundleID: rootBundleID,
            displayName: session.displayName,
            bundleURL: session.bundleURL,
            volume: session.volume,
            lastNonzeroVolume: session.volume > 0 ? session.volume : 1,
            audioBundleIDs: session.audioBundleIDs,
            lastAdjustedAt: session.lastAdjustedAt
        )
        profile.isFavorite.toggle()
        profiles[rootBundleID] = profile.normalized(maximumGain: maximumAppGain)
        persistProfiles()
        rebuildSessions()
    }

    func renamePreset(id: UUID, to requestedName: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        presets[index].name = name.isEmpty ? L("volume.preset.unnamed") : name
        presets[index].updatedAt = Date()
        persistPresets()
    }

    func overwritePreset(
        id: UUID,
        named name: String? = nil,
        masterVolume: Double? = nil,
        appVolumes: [String: Double]? = nil
    ) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if let name { renamePreset(id: id, to: name) }
        presets[index].masterVolume = min(max(masterVolume ?? output.volume, 0), masterVolumeLimit)
        presets[index].appVolumes = (appVolumes ?? Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.rootBundleID, $0.volume)
        })).mapValues { AppVolumeSafetyPolicy.clamp($0, boostEnabled: isBoostEnabled) }
        presets[index].updatedAt = Date()
        persistPresets()
    }

    func exportPresets() -> Data? {
        try? JSONEncoder().encode(AppVolumePresetArchive(
            version: 1,
            presets: presets,
            automationRules: automationRules
        ))
    }

    func importPresets(from data: Data) throws {
        guard let archive = try? JSONDecoder().decode(AppVolumePresetArchive.self, from: data),
              archive.version == 1 else {
            throw AppVolumePresetTransferError.invalidArchive
        }
        let existingIDs = Set(presets.map(\.id))
        let importedPresets = archive.presets.filter { !existingIDs.contains($0.id) }
        presets.append(contentsOf: importedPresets)
        let presetIDs = Set(presets.map(\.id))
        let existingRuleIDs = Set(automationRules.map(\.id))
        automationRules.append(contentsOf: archive.automationRules.filter {
            presetIDs.contains($0.presetID) && !existingRuleIDs.contains($0.id)
        })
        persistPresets()
        persistAutomationRules()
    }

    func setMasterVolumeLimit(_ requestedLimit: Double) {
        masterVolumeLimit = min(max(requestedLimit.isFinite ? requestedLimit : 1, 0.1), 1)
        userDefaults.set(masterVolumeLimit, forKey: StorageKey.masterVolumeLimit)
        if output.volume > masterVolumeLimit { setMasterVolume(masterVolumeLimit) }
    }

    func setLimitsHeadphoneVolume(_ enabled: Bool) {
        limitsHeadphoneVolume = enabled
        userDefaults.set(enabled, forKey: StorageKey.limitsHeadphoneVolume)
        enforceHeadphoneVolumeLimitIfNeeded()
    }

    func recordHearingExposure(now: Date = .now) {
        defer { lastExposureDate = now }
        guard !output.isMuted, output.volume >= 0.8 else {
            highVolumeExposure = 0
            hearingWarningMessage = nil
            return
        }
        guard let lastExposureDate else { return }
        highVolumeExposure += min(max(now.timeIntervalSince(lastExposureDate), 0), 5)
        if highVolumeExposure >= 60 * 60 {
            hearingWarningMessage = L("volume.hearing.warning")
        }
    }

    func dismissHearingWarning() {
        hearingWarningMessage = nil
        highVolumeExposure = 0
    }

    @discardableResult
    func runMeetingAudioCheck() -> AppVolumeMeetingCheck {
        let result = AppVolumeMeetingCheck(
            outputReady: output.deviceID != kAudioObjectUnknown,
            inputReady: input.deviceID != kAudioObjectUnknown && input.canSetVolume,
            inputMuted: input.isMuted,
            inputLevelAvailable: input.peakLevel > 0
        )
        meetingCheck = result
        return result
    }

    func diagnosticReport() -> String {
        let routeCounts = Dictionary(grouping: sessions, by: \.routeStatus).mapValues(\.count)
        let errorSessions = sessions.compactMap { session in
            session.errorMessage.map { "\(session.displayName): \($0)" }
        }
        return [
            "MenuTools App Volume Diagnostic",
            "date=\(ISO8601DateFormatter().string(from: Date()))",
            "permission=\(permissionState)",
            "output=\(output.deviceName) [\(output.deviceUID)] volume=\(Int((output.volume * 100).rounded())) muted=\(output.isMuted) settable=\(output.canSetVolume)",
            "input=\(input.deviceName) [\(input.deviceUID)] volume=\(Int((input.volume * 100).rounded())) muted=\(input.isMuted) meter=\(Int((input.peakLevel * 100).rounded()))",
            "routes=\(routeCounts)",
            "errors=\(errorSessions.isEmpty ? "none" : errorSessions.joined(separator: " | "))",
            "note=DRM 或不支持 Process Tap 的音源将保持系统原始音量。"
        ].joined(separator: "\n")
    }

    @discardableResult
    func copyDiagnosticReport() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(diagnosticReport(), forType: .string)
    }

    func retryRoute(for rootBundleID: String) {
        backend.removeRoute(for: rootBundleID)
        setSessionError(nil, id: rootBundleID)
        refreshErrorMessageFromSessions()
        _ = applyCurrentProfile(for: rootBundleID)
    }

    func bypassRoute(for rootBundleID: String) {
        setVolume(1, for: rootBundleID)
        backend.removeRoute(for: rootBundleID)
        setSessionError(nil, id: rootBundleID)
        refreshErrorMessageFromSessions()
    }

    func setBoostEnabled(_ enabled: Bool) {
        guard isBoostEnabled != enabled else { return }
        isBoostEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKey.boostEnabled)
        let maximumGain = maximumAppGain
        profiles = profiles.mapValues { $0.normalized(maximumGain: maximumGain) }
        persistProfiles()
        rebuildSessions()
        reconcileRoutes()
    }

    @discardableResult
    func savePreset(
        named name: String,
        masterVolume: Double? = nil,
        appVolumes: [String: Double]? = nil
    ) -> AppVolumePreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedAppVolumes = appVolumes ?? Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.rootBundleID, $0.volume)
        })
        for session in sessions where capturedAppVolumes[session.rootBundleID] != nil && profiles[session.rootBundleID] == nil {
            profiles[session.rootBundleID] = AppVolumeProfile(
                rootBundleID: session.rootBundleID,
                displayName: session.displayName,
                bundleURL: session.bundleURL,
                volume: session.volume,
                lastNonzeroVolume: session.volume > 0 ? session.volume : 1,
                audioBundleIDs: session.audioBundleIDs,
                lastAdjustedAt: session.lastAdjustedAt
            ).normalized(maximumGain: maximumAppGain)
        }
        persistProfiles()
        let preset = AppVolumePreset(
            id: UUID(),
            name: trimmedName.isEmpty ? L("volume.preset.unnamed") : trimmedName,
            masterVolume: min(max(masterVolume ?? output.volume, 0), 1),
            appVolumes: capturedAppVolumes.mapValues {
                AppVolumeSafetyPolicy.clamp($0, boostEnabled: isBoostEnabled)
            },
            createdAt: Date()
        )
        presets.append(preset)
        persistPresets()
        return preset
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        automationRules.removeAll { $0.presetID == id }
        devicePresetBindings = devicePresetBindings.filter { $0.value != id }
        persistPresets()
        persistAutomationRules()
        persistDevicePresetBindings()
    }

    func applyPreset(id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        applyConfiguration(AppVolumeConfigurationSnapshot(masterVolume: preset.masterVolume, appVolumes: preset.appVolumes))
    }

    func bindPreset(_ presetID: UUID?, toOutputDeviceUID outputDeviceUID: String) {
        guard !outputDeviceUID.isEmpty else { return }
        if let presetID, presets.contains(where: { $0.id == presetID }) {
            devicePresetBindings[outputDeviceUID] = presetID
        } else {
            devicePresetBindings.removeValue(forKey: outputDeviceUID)
        }
        persistDevicePresetBindings()
    }

    func boundPresetID(forOutputDeviceUID outputDeviceUID: String) -> UUID? {
        devicePresetBindings[outputDeviceUID]
    }

    func setMeetingDuckingEnabled(_ enabled: Bool) {
        meetingDuckingEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKey.meetingDuckingEnabled)
        updateMeetingDucking()
    }

    func setMeetingDuckingFactor(_ factor: Double) {
        meetingDuckingFactor = min(max(factor.isFinite ? factor : 0.4, 0.1), 0.8)
        userDefaults.set(meetingDuckingFactor, forKey: StorageKey.meetingDuckingFactor)
        if isMeetingDuckingActive {
            isMeetingDuckingActive = false
            restoreDuckedVolumes()
            updateMeetingDucking()
        }
    }

    func undoLatestAutomation() {
        guard let undo = latestAutomationUndo else { return }
        applyConfiguration(undo.snapshot)
        if let index = automationExecutions.firstIndex(where: { $0.id == undo.executionID }) {
            automationExecutions[index].revertedAt = Date()
            persistAutomationExecutions()
        }
        latestAutomationUndo = nil
    }

    private func applyConfiguration(_ configuration: AppVolumeConfigurationSnapshot) {
        guard !isApplyingPreset else { return }
        isApplyingPreset = true
        defer { isApplyingPreset = false }
        setMasterVolume(configuration.masterVolume)
        for (rootBundleID, volume) in configuration.appVolumes {
            if session(id: rootBundleID) != nil {
                setVolume(volume, for: rootBundleID)
            } else if var profile = profiles[rootBundleID] {
                profile.volume = AppVolumeSafetyPolicy.clamp(volume, boostEnabled: isBoostEnabled)
                if profile.volume > 0 { profile.lastNonzeroVolume = profile.volume }
                profile.lastAdjustedAt = Date()
                profiles[rootBundleID] = profile.normalized(maximumGain: maximumAppGain)
            }
        }
        persistProfiles()
        rebuildSessions()
    }

    func addAutomationRule(presetID: UUID, outputDeviceUID: String?) {
        guard presets.contains(where: { $0.id == presetID }) else { return }
        automationRules.append(AppVolumeAutomationRule(
            id: UUID(),
            presetID: presetID,
            outputDeviceUID: outputDeviceUID,
            isEnabled: true
        ))
        persistAutomationRules()
    }

    func updateAutomationRule(_ requestedRule: AppVolumeAutomationRule) {
        guard let index = automationRules.firstIndex(where: { $0.id == requestedRule.id }),
              presets.contains(where: { $0.id == requestedRule.presetID }) else { return }
        var rule = requestedRule
        rule.outputDeviceUID = rule.outputDeviceUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.launchBundleID = rule.launchBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.wifiName = rule.wifiName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.outputDeviceUID?.isEmpty == true { rule.outputDeviceUID = nil }
        if rule.launchBundleID?.isEmpty == true { rule.launchBundleID = nil }
        if rule.wifiName?.isEmpty == true { rule.wifiName = nil }
        if rule.startMinute == nil || rule.endMinute == nil {
            rule.startMinute = nil
            rule.endMinute = nil
        } else {
            rule.startMinute = min(max(rule.startMinute ?? 0, 0), 1_439)
            rule.endMinute = min(max(rule.endMinute ?? 0, 0), 1_439)
        }
        automationRules[index] = rule
        appliedAutomationKeys.removeAll()
        persistAutomationRules()
    }

    func setAutomationRuleEnabled(_ enabled: Bool, id: UUID) {
        guard let index = automationRules.firstIndex(where: { $0.id == id }) else { return }
        automationRules[index].isEnabled = enabled
        persistAutomationRules()
    }

    func deleteAutomationRule(id: UUID) {
        automationRules.removeAll { $0.id == id }
        persistAutomationRules()
    }

    func evaluateAutomation(
        now: Date = .now,
        context providedContext: AppVolumeAutomationContext? = nil
    ) {
        guard !isApplyingPreset else { return }
        guard !output.deviceUID.isEmpty else { return }
        let context = providedContext ?? currentAutomationContext(at: now)
        for rule in automationRules where rule.matches(context) {
            let applicationKey = Self.automationApplicationKey(
                ruleID: rule.id,
                outputDeviceUID: context.outputDeviceUID,
                date: now
            )
            if let legacyExecutionIndex = Self.legacyAutomationExecutionIndex(
                ruleID: rule.id,
                outputDeviceName: output.deviceName,
                date: now,
                executions: automationExecutions
            ) {
                appliedAutomationKeys.insert(applicationKey)
                automationExecutions[legacyExecutionIndex].outputDeviceUID = context.outputDeviceUID
                persistAutomationExecutions()
                continue
            }
            guard appliedAutomationKeys.insert(applicationKey).inserted else { continue }
            guard let preset = presets.first(where: { $0.id == rule.presetID }) else { continue }
            let snapshot = currentConfigurationSnapshot()
            applyConfiguration(AppVolumeConfigurationSnapshot(masterVolume: preset.masterVolume, appVolumes: preset.appVolumes))
            let execution = AppVolumeAutomationExecution(
                id: UUID(), ruleID: rule.id, presetID: preset.id, presetName: preset.name,
                outputDeviceName: output.deviceName, outputDeviceUID: context.outputDeviceUID, executedAt: now
            )
            automationExecutions.insert(execution, at: 0)
            automationExecutions = Array(automationExecutions.prefix(20))
            latestAutomationUndo = (execution.id, snapshot)
            persistAutomationExecutions()
        }
    }

    func setInputVolume(_ requestedVolume: Double) {
        let volume = min(max(requestedVolume.isFinite ? requestedVolume : 1, 0), 1)
        do {
            try backend.setInputVolume(volume)
            input.volume = volume
            if volume > 0 { input.isMuted = false }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setInputMuted(_ muted: Bool) {
        do {
            try backend.setInputMuted(muted)
            input.isMuted = muted
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setVolume(_ requestedVolume: Double, for rootBundleID: String) {
        guard let session = session(id: rootBundleID) else { return }
        let previousProfile = profiles[rootBundleID]
        let volume = AppVolumeSafetyPolicy.clamp(requestedVolume, boostEnabled: isBoostEnabled)
        if isMeetingDuckingActive, !isApplyingMeetingDucking, var duckingState = duckedVolumes[rootBundleID] {
            duckingState.originalVolume = volume
            duckingState.needsDucking = false
            duckedVolumes[rootBundleID] = duckingState
            persistDuckedVolumes()
        }
        var profile = profiles[rootBundleID] ?? AppVolumeProfile(
            rootBundleID: rootBundleID,
            displayName: session.displayName,
            bundleURL: session.bundleURL,
            volume: 1,
            lastNonzeroVolume: 1,
            audioBundleIDs: session.audioBundleIDs,
            lastAdjustedAt: .distantPast
        )
        profile.displayName = session.displayName
        profile.bundleURL = session.bundleURL ?? profile.bundleURL
        profile.volume = volume
        if volume > 0 { profile.lastNonzeroVolume = volume }
        profile.audioBundleIDs.formUnion(session.audioBundleIDs)
        profile.lastAdjustedAt = Date()
        profiles[rootBundleID] = profile.normalized(maximumGain: maximumAppGain)
        persistProfiles()
        rebuildSessions()
        if !isApplyingMeetingDucking { updateMeetingDucking() }
        guard applyCurrentProfile(for: rootBundleID) == .permissionDenied else { return }

        if let previousProfile {
            profiles[rootBundleID] = previousProfile
        } else {
            profiles.removeValue(forKey: rootBundleID)
        }
        persistProfiles()
        rebuildSessions()
    }

    func toggleMute(for rootBundleID: String) {
        guard let session = session(id: rootBundleID) else { return }
        if session.volume > 0 {
            setVolume(0, for: rootBundleID)
        } else {
            setVolume(profiles[rootBundleID]?.lastNonzeroVolume ?? 1, for: rootBundleID)
        }
    }

    func resetProfile(for rootBundleID: String) {
        profiles.removeValue(forKey: rootBundleID)
        persistProfiles()
        backend.removeRoute(for: rootBundleID)
        setSessionError(nil, id: rootBundleID)
        refreshErrorMessageFromSessions()
        rebuildSessions()
    }

    func resetAllProfiles() {
        let identifiers = profiles.keys
        profiles.removeAll()
        persistProfiles()
        identifiers.forEach { backend.removeRoute(for: $0) }
        for index in sessions.indices {
            sessions[index].errorMessage = nil
        }
        errorMessage = nil
        rebuildSessions()
    }

    func setMasterVolume(_ requestedVolume: Double) {
        let volume = min(max(requestedVolume.isFinite ? requestedVolume : 1, 0), masterVolumeLimit)
        do {
            try backend.setMasterVolume(volume)
            output.volume = volume
            if volume > 0 { output.isMuted = false }
            rememberOutputVolume()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setMasterMuted(_ muted: Bool) {
        do {
            try backend.setMasterMuted(muted)
            output.isMuted = muted
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receive(_ snapshot: AppVolumeBackendSnapshot) {
        let previousOutputUID = output.deviceUID
        candidates = snapshot.candidates
        output = snapshot.output
        input = snapshot.input
        let restorePendingOutput = pendingOutputDeviceUID == output.deviceUID
        pendingOutputDeviceUID = nil
        if restorePendingOutput, let rememberedVolume = outputVolumeMemory[output.deviceUID] {
            setMasterVolume(rememberedVolume)
        } else {
            rememberOutputVolume()
        }
        if previousOutputUID != output.deviceUID {
            refreshOutputDevices()
            enforceHeadphoneVolumeLimitIfNeeded()
            applyBoundPreset(forOutputDeviceUID: output.deviceUID)
        }
        rebuildSessions()
        applyLevels(snapshot.levels)
        updateMeetingDucking()
        if isEnabled { reconcileRoutes() }
        evaluateAutomation()
        recordHearingExposure()
    }

    private func rebuildSessions() {
        let previousOrder = Dictionary(uniqueKeysWithValues: sessions.enumerated().map {
            ($0.element.rootBundleID, $0.offset)
        })
        let previousErrors = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.errorMessage.map { (session.rootBundleID, $0) }
        })
        var rebuilt = AppAudioSession.group(
            candidates: candidates,
            profiles: profiles,
            maximumGain: maximumAppGain
        )
        let fallbackOrder = Dictionary(uniqueKeysWithValues: rebuilt.enumerated().map {
            ($0.element.rootBundleID, $0.offset)
        })
        rebuilt.sort { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput
            }
            switch (previousOrder[lhs.rootBundleID], previousOrder[rhs.rootBundleID]) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return (fallbackOrder[lhs.rootBundleID] ?? .max)
                    < (fallbackOrder[rhs.rootBundleID] ?? .max)
            }
        }
        sessions = rebuilt
        for index in sessions.indices {
            sessions[index].errorMessage = previousErrors[sessions[index].rootBundleID]
        }
    }

    private func currentConfigurationSnapshot() -> AppVolumeConfigurationSnapshot {
        AppVolumeConfigurationSnapshot(
            masterVolume: output.volume,
            appVolumes: Dictionary(uniqueKeysWithValues: sessions.map { ($0.rootBundleID, $0.volume) })
        )
    }

    private func applyBoundPreset(forOutputDeviceUID outputDeviceUID: String) {
        guard let presetID = devicePresetBindings[outputDeviceUID] else { return }
        applyPreset(id: presetID)
    }

    private func updateMeetingDucking() {
        let meetingIsActive = meetingDuckingEnabled && sessions.contains {
            $0.isRunningOutput && $0.appGroup == .meeting && $0.volume > 0
        }
        if meetingIsActive {
            isMeetingDuckingActive = true
            let newTargets = sessions.filter {
                $0.isRunningOutput
                    && $0.appGroup != .meeting
                    && $0.volume > 0
                    && duckedVolumes[$0.rootBundleID] == nil
            }
            for target in newTargets {
                duckedVolumes[target.rootBundleID] = AppVolumeDuckingState(
                    originalVolume: target.volume,
                    duckedVolume: target.volume * meetingDuckingFactor,
                    needsDucking: true
                )
            }
            persistDuckedVolumes()
            let pendingTargets = sessions.filter {
                $0.isRunningOutput
                    && $0.appGroup != .meeting
                    && duckedVolumes[$0.rootBundleID]?.needsDucking == true
            }
            guard !pendingTargets.isEmpty else { return }
            isApplyingMeetingDucking = true
            for target in pendingTargets {
                guard var duckingState = duckedVolumes[target.rootBundleID] else { continue }
                setVolume(duckingState.duckedVolume, for: target.rootBundleID)
                duckingState.needsDucking = false
                duckedVolumes[target.rootBundleID] = duckingState
                persistDuckedVolumes()
            }
            isApplyingMeetingDucking = false
        } else if !meetingIsActive, isMeetingDuckingActive {
            isMeetingDuckingActive = false
            restoreDuckedVolumes()
        }
    }

    private func restoreDuckedVolumes() {
        let originals = duckedVolumes
        isApplyingMeetingDucking = true
        originals.forEach { identifier, state in
            if session(id: identifier) != nil { setVolume(state.originalVolume, for: identifier) }
        }
        isApplyingMeetingDucking = false
        duckedVolumes.removeAll()
        persistDuckedVolumes()
    }

    private func reconcileRoutes() {
        for session in sessions {
            applyCurrentProfile(for: session.rootBundleID)
        }
    }

    @discardableResult
    private func applyCurrentProfile(for rootBundleID: String) -> RouteApplicationResult {
        guard let session = session(id: rootBundleID) else { return .applied }
        guard isEnabled,
              AppVolumeSafetyPolicy.requiresRoute(
                  for: session.volume,
                  equalizer: session.equalizer,
                  outputDeviceUID: session.outputDeviceUID
              ),
              !session.processObjectIDs.isEmpty else {
            backend.removeRoute(for: rootBundleID)
            setSessionError(nil, id: rootBundleID)
            setRouteStatus(.bypassed, id: rootBundleID)
            refreshErrorMessageFromSessions()
            return .applied
        }

        do {
            try backend.apply(volume: session.volume, to: session.target)
            permissionState = .authorized
            userDefaults.set(true, forKey: StorageKey.permissionGranted)
            setSessionError(nil, id: rootBundleID)
            setRouteStatus(.active, id: rootBundleID)
            refreshErrorMessageFromSessions()
            return .applied
        } catch {
            if case AppVolumeRoutingError.permissionDenied = error {
                permissionState = .denied
                userDefaults.set(false, forKey: StorageKey.permissionGranted)
                setSessionError(error.localizedDescription, id: rootBundleID)
                setRouteStatus(.failed, id: rootBundleID)
                refreshErrorMessageFromSessions()
                return .permissionDenied
            }
            setSessionError(error.localizedDescription, id: rootBundleID)
            setRouteStatus(.failed, id: rootBundleID)
            refreshErrorMessageFromSessions()
            return .failed
        }
    }

    private func setSessionError(_ message: String?, id: String) {
        guard let index = sessions.firstIndex(where: { $0.rootBundleID == id }) else { return }
        sessions[index].errorMessage = message
    }

    private func setRouteStatus(_ status: AppVolumeRouteStatus, id: String) {
        guard let index = sessions.firstIndex(where: { $0.rootBundleID == id }) else { return }
        sessions[index].routeStatus = status
    }

    private func refreshErrorMessageFromSessions() {
        errorMessage = sessions.lazy.compactMap(\.errorMessage).first
    }

    private func applyLevels(_ levels: [String: AppVolumeMeter]) {
        for index in sessions.indices {
            let incoming = levels[sessions[index].rootBundleID] ?? .empty
            let previous = sessions[index].meter
            let peak = min(max(incoming.peak.isFinite ? incoming.peak : 0, 0), 1)
            sessions[index].meter = AppVolumeMeter(
                peak: peak,
                rms: min(max(incoming.rms.isFinite ? incoming.rms : 0, 0), 1),
                heldPeak: max(peak, previous.heldPeak * 0.86),
                isClipping: incoming.isClipping,
                cpuLoad: min(max(incoming.cpuLoad.isFinite ? incoming.cpuLoad : 0, 0), 1)
            )
        }
        input.peakLevel = min(max(input.peakLevel.isFinite ? input.peakLevel : 0, 0), 1)
    }

    private func enforceHeadphoneVolumeLimitIfNeeded() {
        guard limitsHeadphoneVolume,
              !isApplyingHearingLimit,
              AppVolumeHearingSafetyPolicy.isHeadphone(deviceName: output.deviceName),
              output.volume > masterVolumeLimit else { return }
        isApplyingHearingLimit = true
        defer { isApplyingHearingLimit = false }
        setMasterVolume(masterVolumeLimit)
    }

    private func currentAutomationContext(at date: Date) -> AppVolumeAutomationContext {
        AppVolumeAutomationContext(
            date: date,
            outputDeviceUID: output.deviceUID,
            isFocusModeEnabled: FocusModeService.shared.isEnabled,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            wifiName: networkStatusService.snapshot.wifiName
        )
    }

    private func startAutomationMonitoring() {
        guard automationTimer == nil else { return }
        FocusModeService.shared.refresh(trigger: .automation)
        networkStatusService.refresh()
        automationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                FocusModeService.shared.refresh(trigger: .automation)
                self?.networkStatusService.refresh()
                self?.evaluateAutomation()
            }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAutomation()
            }
        }
    }

    private func stopAutomationMonitoring() {
        automationTimer?.invalidate()
        automationTimer = nil
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }

    private func rememberOutputVolume() {
        guard !output.deviceUID.isEmpty, output.volume.isFinite else { return }
        outputVolumeMemory[output.deviceUID] = min(max(output.volume, 0), 1)
        guard let data = try? JSONEncoder().encode(outputVolumeMemory) else { return }
        userDefaults.set(data, forKey: StorageKey.outputVolumeMemory)
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: StorageKey.profiles)
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        userDefaults.set(data, forKey: StorageKey.presets)
    }

    private func persistAutomationRules() {
        guard let data = try? JSONEncoder().encode(automationRules) else { return }
        userDefaults.set(data, forKey: StorageKey.automationRules)
    }

    private func persistAutomationExecutions() {
        guard let data = try? JSONEncoder().encode(automationExecutions) else { return }
        userDefaults.set(data, forKey: StorageKey.automationExecutions)
    }

    private func persistDuckedVolumes() {
        guard let data = try? JSONEncoder().encode(duckedVolumes) else { return }
        userDefaults.set(data, forKey: StorageKey.duckedVolumes)
    }

    private func persistDevicePresetBindings() {
        guard let data = try? JSONEncoder().encode(devicePresetBindings) else { return }
        userDefaults.set(data, forKey: StorageKey.devicePresetBindings)
    }

    private static func loadProfiles(
        from userDefaults: UserDefaults,
        maximumGain: Double
    ) -> [String: AppVolumeProfile] {
        guard let data = userDefaults.data(forKey: StorageKey.profiles),
              let decoded = try? JSONDecoder().decode([String: AppVolumeProfile].self, from: data) else {
            return [:]
        }
        return decoded.mapValues { $0.normalized(maximumGain: maximumGain) }
    }

    private static func loadOutputVolumeMemory(from userDefaults: UserDefaults) -> [String: Double] {
        guard let data = userDefaults.data(forKey: StorageKey.outputVolumeMemory),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded.mapValues { min(max($0.isFinite ? $0 : 1, 0), 1) }
    }

    private static func loadVolumeStep(from userDefaults: UserDefaults) -> Double {
        let value = userDefaults.object(forKey: StorageKey.volumeStep) as? Double ?? 0.05
        return min(max(value.isFinite ? value : 0.05, 0.01), 0.25)
    }

    private static func loadSessionFilter(from userDefaults: UserDefaults) -> AppVolumeSessionFilter {
        guard let rawValue = userDefaults.string(forKey: StorageKey.sessionFilter),
              let filter = AppVolumeSessionFilter(rawValue: rawValue) else {
            return .all
        }
        return filter
    }

    private static func loadAppGroupFilter(from userDefaults: UserDefaults) -> AppVolumeAppGroup? {
        guard let rawValue = userDefaults.string(forKey: StorageKey.appGroupFilter) else { return nil }
        return AppVolumeAppGroup(rawValue: rawValue)
    }

    private static func loadSessionSort(from userDefaults: UserDefaults) -> AppVolumeSessionSort {
        guard let rawValue = userDefaults.string(forKey: StorageKey.sessionSort),
              let sort = AppVolumeSessionSort(rawValue: rawValue) else {
            return .recent
        }
        return sort
    }

    private static func loadMasterVolumeLimit(from userDefaults: UserDefaults) -> Double {
        let value = userDefaults.object(forKey: StorageKey.masterVolumeLimit) as? Double ?? 1
        return min(max(value.isFinite ? value : 1, 0.1), 1)
    }

    private static func loadPresets(from userDefaults: UserDefaults) -> [AppVolumePreset] {
        guard let data = userDefaults.data(forKey: StorageKey.presets),
              let decoded = try? JSONDecoder().decode([AppVolumePreset].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func loadAutomationRules(from userDefaults: UserDefaults) -> [AppVolumeAutomationRule] {
        guard let data = userDefaults.data(forKey: StorageKey.automationRules),
              let decoded = try? JSONDecoder().decode([AppVolumeAutomationRule].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func loadAutomationExecutions(from userDefaults: UserDefaults) -> [AppVolumeAutomationExecution] {
        guard let data = userDefaults.data(forKey: StorageKey.automationExecutions),
              let entries = try? JSONDecoder().decode([AppVolumeAutomationExecution].self, from: data) else { return [] }
        return Array(entries.prefix(20))
    }

    private static func automationApplicationKeys(
        from executions: [AppVolumeAutomationExecution]
    ) -> Set<String> {
        Set(executions.compactMap { execution in
            guard let outputDeviceUID = execution.outputDeviceUID, !outputDeviceUID.isEmpty else {
                return nil
            }
            return automationApplicationKey(
                ruleID: execution.ruleID,
                outputDeviceUID: outputDeviceUID,
                date: execution.executedAt
            )
        })
    }

    private static func legacyAutomationExecutionIndex(
        ruleID: UUID,
        outputDeviceName: String,
        date: Date,
        executions: [AppVolumeAutomationExecution]
    ) -> Int? {
        executions.firstIndex { execution in
            execution.ruleID == ruleID
                && execution.outputDeviceUID == nil
                && execution.outputDeviceName == outputDeviceName
                && Calendar.current.isDate(execution.executedAt, inSameDayAs: date)
        }
    }

    private static func automationApplicationKey(
        ruleID: UUID,
        outputDeviceUID: String,
        date: Date
    ) -> String {
        let dayKey = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return "\(ruleID.uuidString)|\(outputDeviceUID)|\(dayKey)"
    }

    private static func loadMeetingDuckingFactor(from userDefaults: UserDefaults) -> Double {
        let factor = userDefaults.object(forKey: StorageKey.meetingDuckingFactor) as? Double ?? 0.4
        return min(max(factor.isFinite ? factor : 0.4, 0.1), 0.8)
    }

    private static func loadDuckedVolumes(
        from userDefaults: UserDefaults,
        maximumGain: Double
    ) -> [String: AppVolumeDuckingState] {
        guard let data = userDefaults.data(forKey: StorageKey.duckedVolumes) else { return [:] }
        if let values = try? JSONDecoder().decode([String: AppVolumeDuckingState].self, from: data) {
            return values.mapValues { state in
                AppVolumeDuckingState(
                    originalVolume: min(max(state.originalVolume.isFinite ? state.originalVolume : 1, 0), maximumGain),
                    duckedVolume: min(max(state.duckedVolume.isFinite ? state.duckedVolume : 1, 0), maximumGain),
                    needsDucking: state.needsDucking
                )
            }
        }
        guard let legacyValues = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return legacyValues.mapValues { value in
            let normalizedVolume = min(max(value.isFinite ? value : 1, 0), maximumGain)
            return AppVolumeDuckingState(
                originalVolume: normalizedVolume,
                duckedVolume: normalizedVolume,
                needsDucking: false
            )
        }
    }

    private static func loadDevicePresetBindings(from userDefaults: UserDefaults) -> [String: UUID] {
        guard let data = userDefaults.data(forKey: StorageKey.devicePresetBindings),
              let values = try? JSONDecoder().decode([String: UUID].self, from: data) else { return [:] }
        return values
    }

    enum StorageKey {
        static let enabled = "appVolume.enabled"
        static let profiles = "appVolume.profiles.v1"
        static let permissionGranted = "appVolume.permissionGranted"
        static let outputVolumeMemory = "appVolume.outputVolumeMemory.v1"
        static let volumeStep = "appVolume.volumeStep.v1"
        static let sessionFilter = "appVolume.sessionFilter.v1"
        static let boostEnabled = "appVolume.boostEnabled.v1"
        static let presets = "appVolume.presets.v1"
        static let automationRules = "appVolume.automationRules.v1"
        static let appGroupFilter = "appVolume.appGroupFilter.v1"
        static let sessionSort = "appVolume.sessionSort.v1"
        static let searchQuery = "appVolume.searchQuery.v1"
        static let masterVolumeLimit = "appVolume.masterVolumeLimit.v1"
        static let limitsHeadphoneVolume = "appVolume.limitsHeadphoneVolume.v1"
        static let automationExecutions = "appVolume.automationExecutions.v1"
        static let meetingDuckingEnabled = "appVolume.meetingDuckingEnabled.v1"
        static let meetingDuckingFactor = "appVolume.meetingDuckingFactor.v1"
        static let duckedVolumes = "appVolume.duckedVolumes.v1"
        static let devicePresetBindings = "appVolume.devicePresetBindings.v1"
    }
}
