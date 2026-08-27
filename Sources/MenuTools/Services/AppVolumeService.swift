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

    func normalized() -> Self {
        var copy = self
        copy.volume = copy.volume.isFinite ? min(max(copy.volume, 0), 1) : 1
        if !copy.lastNonzeroVolume.isFinite || copy.lastNonzeroVolume <= 0 {
            copy.lastNonzeroVolume = copy.volume > 0 ? copy.volume : 1
        }
        copy.lastNonzeroVolume = min(max(copy.lastNonzeroVolume, 0.01), 1)
        copy.audioBundleIDs.remove("")
        return copy
    }
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

    var target: AppVolumeTarget {
        AppVolumeTarget(
            rootBundleID: rootBundleID,
            processObjectIDs: processObjectIDs,
            audioBundleIDs: audioBundleIDs
        )
    }

    static func group(
        candidates: [AppAudioProcessCandidate],
        profiles: [String: AppVolumeProfile]
    ) -> [Self] {
        let grouped = Dictionary(grouping: candidates, by: \AppAudioProcessCandidate.rootBundleID)
        let activeIdentifiers = grouped.compactMap { identifier, processes in
            processes.contains(where: \.isRunningOutput) ? identifier : nil
        }
        let identifiers = Set(activeIdentifiers).union(profiles.keys)

        return identifiers.compactMap { identifier in
            let processes = grouped[identifier] ?? []
            let profile = profiles[identifier]?.normalized()
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
                errorMessage: nil
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
    var deviceName: String
    var volume: Double
    var isMuted: Bool
    var canSetVolume: Bool
    var canSetMute: Bool

    static let unavailable = Self(
        deviceID: kAudioObjectUnknown,
        deviceName: "",
        volume: 1,
        isMuted: false,
        canSetVolume: false,
        canSetMute: false
    )
}

struct AppVolumeBackendSnapshot: Equatable, Sendable {
    var candidates: [AppAudioProcessCandidate]
    var output: SystemOutputVolumeState
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
    func apply(volume: Double, to target: AppVolumeTarget) throws
    func removeRoute(for rootBundleID: String)
    func setMasterVolume(_ volume: Double) throws
    func setMasterMuted(_ muted: Bool) throws
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
    private(set) var permissionState: AppVolumePermissionState = .notRequested
    private(set) var errorMessage: String?
    private(set) var isStarted = false
    private(set) var isEnabled: Bool

    var hasProfiles: Bool { !profiles.isEmpty }

    private let backend: AppVolumeRoutingBackend
    private let userDefaults: UserDefaults
    private var profiles: [String: AppVolumeProfile]
    private var candidates: [AppAudioProcessCandidate] = []

    init(backend: AppVolumeRoutingBackend, userDefaults: UserDefaults) {
        self.backend = backend
        self.userDefaults = userDefaults
        isEnabled = userDefaults.bool(forKey: StorageKey.enabled)
        profiles = Self.loadProfiles(from: userDefaults)
        permissionState = userDefaults.bool(forKey: StorageKey.permissionGranted)
            ? .authorized
            : .notRequested
        backend.onSnapshot = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        rebuildSessions()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        backend.start()
    }

    func stop() {
        guard isStarted else { return }
        sessions.forEach { backend.removeRoute(for: $0.rootBundleID) }
        backend.stop()
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

    func setVolume(_ requestedVolume: Double, for rootBundleID: String) {
        guard let session = session(id: rootBundleID) else { return }
        let previousProfile = profiles[rootBundleID]
        let volume = requestedVolume.isFinite ? min(max(requestedVolume, 0), 1) : 1
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
        profiles[rootBundleID] = profile.normalized()
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
        let volume = requestedVolume.isFinite ? min(max(requestedVolume, 0), 1) : 1
        do {
            try backend.setMasterVolume(volume)
            output.volume = volume
            if volume > 0 { output.isMuted = false }
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
        candidates = snapshot.candidates
        output = snapshot.output
        rebuildSessions()
        if isEnabled { reconcileRoutes() }
    }

    private func rebuildSessions() {
        let previousOrder = Dictionary(uniqueKeysWithValues: sessions.enumerated().map {
            ($0.element.rootBundleID, $0.offset)
        })
        let previousErrors = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.errorMessage.map { (session.rootBundleID, $0) }
        })
        var rebuilt = AppAudioSession.group(candidates: candidates, profiles: profiles)
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

    private func reconcileRoutes() {
        for session in sessions {
            applyCurrentProfile(for: session.rootBundleID)
        }
    }

    @discardableResult
    private func applyCurrentProfile(for rootBundleID: String) -> RouteApplicationResult {
        guard let session = session(id: rootBundleID) else { return .applied }
        guard isEnabled, session.volume < 0.999, !session.processObjectIDs.isEmpty else {
            backend.removeRoute(for: rootBundleID)
            setSessionError(nil, id: rootBundleID)
            refreshErrorMessageFromSessions()
            return .applied
        }

        do {
            try backend.apply(volume: session.volume, to: session.target)
            permissionState = .authorized
            userDefaults.set(true, forKey: StorageKey.permissionGranted)
            setSessionError(nil, id: rootBundleID)
            refreshErrorMessageFromSessions()
            return .applied
        } catch {
            if case AppVolumeRoutingError.permissionDenied = error {
                permissionState = .denied
                userDefaults.set(false, forKey: StorageKey.permissionGranted)
                setSessionError(error.localizedDescription, id: rootBundleID)
                refreshErrorMessageFromSessions()
                return .permissionDenied
            }
            setSessionError(error.localizedDescription, id: rootBundleID)
            refreshErrorMessageFromSessions()
            return .failed
        }
    }

    private func setSessionError(_ message: String?, id: String) {
        guard let index = sessions.firstIndex(where: { $0.rootBundleID == id }) else { return }
        sessions[index].errorMessage = message
    }

    private func refreshErrorMessageFromSessions() {
        errorMessage = sessions.lazy.compactMap(\.errorMessage).first
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: StorageKey.profiles)
    }

    private static func loadProfiles(from userDefaults: UserDefaults) -> [String: AppVolumeProfile] {
        guard let data = userDefaults.data(forKey: StorageKey.profiles),
              let decoded = try? JSONDecoder().decode([String: AppVolumeProfile].self, from: data) else {
            return [:]
        }
        return decoded.mapValues { $0.normalized() }
    }

    enum StorageKey {
        static let enabled = "appVolume.enabled"
        static let profiles = "appVolume.profiles.v1"
        static let permissionGranted = "appVolume.permissionGranted"
    }
}
