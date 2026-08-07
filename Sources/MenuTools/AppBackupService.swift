import Foundation

/// 备份文件的最小文件读写边界，便于设置页和测试注入实现。
protocol AppBackupFileAccessing: Sendable {
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
}

struct LocalAppBackupFileAccess: AppBackupFileAccessing {
    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

enum AppBackupRestoreError: Error, LocalizedError, @unchecked Sendable {
    case rollbackFailed(original: any Error, rollback: any Error)

    var errorDescription: String? {
        switch self {
        case let .rollbackFailed(original, rollback):
            return "备份恢复失败：\(original.localizedDescription)；回滚失败：\(rollback.localizedDescription)"
        }
    }
}

/// 应用配置备份的快照、JSON 和恢复操作。
enum AppBackupService {
    static func makeDocument(
        userDefaults: UserDefaults,
        rightClick: RightClickConfig,
        appVersion: String,
        createdAt: Date
    ) -> AppBackupDocument {
        func string(_ key: String, _ fallback: String) -> String {
            userDefaults.string(forKey: key) ?? fallback
        }

        func bool(_ key: String, _ fallback: Bool) -> Bool {
            userDefaults.object(forKey: key) == nil ? fallback : userDefaults.bool(forKey: key)
        }

        func double(_ key: String, _ fallback: Double) -> Double {
            userDefaults.object(forKey: key) == nil ? fallback : userDefaults.double(forKey: key)
        }

        func modifier(_ key: String) -> UInt {
            UInt(bitPattern: userDefaults.integer(forKey: key))
        }

        let settings = AppBackupSettings(
            menuBarIcon: string(SettingsKey.menuBarIcon, MenuBarIcon.default.rawValue),
            menuBarShowTitle: bool(SettingsKey.menuBarShowTitle, false),
            togglesShowTitle: bool(SettingsKey.togglesShowTitle, false),
            preferredTerminal: string(SettingsKey.preferredTerminal, TerminalApp.systemDefault.rawValue),
            autoCheckUpdate: bool(SettingsKey.autoCheckUpdate, true),
            appLanguage: string(SettingsKey.appLanguage, AppLanguage.system.rawValue),
            scrollEnabled: bool(SettingsKey.scrollEnabled, false),
            scrollSmoothVertical: bool(SettingsKey.scrollSmoothV, true),
            scrollSmoothHorizontal: bool(SettingsKey.scrollSmoothH, true),
            scrollInvertVertical: bool(SettingsKey.scrollInvertV, false),
            scrollInvertHorizontal: bool(SettingsKey.scrollInvertH, false),
            scrollGain: double(SettingsKey.scrollGain, 1.0),
            scrollDuration: double(SettingsKey.scrollDuration, 0.35),
            scrollMinStep: double(SettingsKey.scrollMinStep, 8),
            scrollTouchpadEmulation: bool(SettingsKey.scrollTouchpad, true),
            scrollAccelModifier: modifier(SettingsKey.scrollAccelKey),
            scrollShiftModifier: modifier(SettingsKey.scrollShiftKey),
            scrollDisableModifier: modifier(SettingsKey.scrollDisableKey)
        )

        return AppBackupDocument.current(
            settings: settings,
            rightClick: rightClick,
            appVersion: appVersion,
            createdAt: createdAt
        )
    }

    static func encode(_ document: AppBackupDocument) throws -> Data {
        let validated = try document.validated()
        return try makeEncoder().encode(validated)
    }

    static func decode(_ data: Data) throws -> AppBackupDocument {
        try makeDecoder().decode(AppBackupDocument.self, from: data).validated()
    }

    static func export(
        to url: URL,
        userDefaults: UserDefaults,
        rightClick: RightClickConfig,
        appVersion: String,
        createdAt: Date,
        fileAccess: any AppBackupFileAccessing = LocalAppBackupFileAccess()
    ) throws {
        let document = makeDocument(
            userDefaults: userDefaults,
            rightClick: rightClick,
            appVersion: appVersion,
            createdAt: createdAt
        )
        try fileAccess.write(try encode(document), to: url)
    }

    static func importDocument(
        from url: URL,
        fileAccess: any AppBackupFileAccessing = LocalAppBackupFileAccess()
    ) throws -> AppBackupDocument {
        try decode(fileAccess.read(from: url))
    }

    static func restore(
        _ document: AppBackupDocument,
        userDefaults: UserDefaults,
        rightClickStore: any RightClickConfigPersisting
    ) throws {
        let document = try document.validated()
        let previousDefaults = Self.allowlistedKeys.map { ($0, userDefaults.object(forKey: $0)) }
        let previousRightClick = rightClickStore.load()

        do {
            apply(document.settings, to: userDefaults)
            try rightClickStore.replace(document.rightClick)
        } catch let originalError {
            restore(previousDefaults, to: userDefaults)
            do {
                try rightClickStore.replace(previousRightClick)
            } catch let rollbackError {
                throw AppBackupRestoreError.rollbackFailed(
                    original: originalError,
                    rollback: rollbackError
                )
            }
            throw originalError
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let allowlistedKeys = [
        SettingsKey.menuBarIcon,
        SettingsKey.menuBarShowTitle,
        SettingsKey.togglesShowTitle,
        SettingsKey.preferredTerminal,
        SettingsKey.autoCheckUpdate,
        SettingsKey.appLanguage,
        SettingsKey.scrollEnabled,
        SettingsKey.scrollSmoothV,
        SettingsKey.scrollSmoothH,
        SettingsKey.scrollInvertV,
        SettingsKey.scrollInvertH,
        SettingsKey.scrollGain,
        SettingsKey.scrollDuration,
        SettingsKey.scrollMinStep,
        SettingsKey.scrollTouchpad,
        SettingsKey.scrollAccelKey,
        SettingsKey.scrollShiftKey,
        SettingsKey.scrollDisableKey
    ]

    private static func apply(_ settings: AppBackupSettings, to userDefaults: UserDefaults) {
        userDefaults.set(settings.menuBarIcon, forKey: SettingsKey.menuBarIcon)
        userDefaults.set(settings.menuBarShowTitle, forKey: SettingsKey.menuBarShowTitle)
        userDefaults.set(settings.togglesShowTitle, forKey: SettingsKey.togglesShowTitle)
        userDefaults.set(settings.preferredTerminal, forKey: SettingsKey.preferredTerminal)
        userDefaults.set(settings.autoCheckUpdate, forKey: SettingsKey.autoCheckUpdate)
        userDefaults.set(settings.appLanguage, forKey: SettingsKey.appLanguage)
        userDefaults.set(settings.scrollEnabled, forKey: SettingsKey.scrollEnabled)
        userDefaults.set(settings.scrollSmoothVertical, forKey: SettingsKey.scrollSmoothV)
        userDefaults.set(settings.scrollSmoothHorizontal, forKey: SettingsKey.scrollSmoothH)
        userDefaults.set(settings.scrollInvertVertical, forKey: SettingsKey.scrollInvertV)
        userDefaults.set(settings.scrollInvertHorizontal, forKey: SettingsKey.scrollInvertH)
        userDefaults.set(settings.scrollGain, forKey: SettingsKey.scrollGain)
        userDefaults.set(settings.scrollDuration, forKey: SettingsKey.scrollDuration)
        userDefaults.set(settings.scrollMinStep, forKey: SettingsKey.scrollMinStep)
        userDefaults.set(settings.scrollTouchpadEmulation, forKey: SettingsKey.scrollTouchpad)
        userDefaults.set(Int(bitPattern: settings.scrollAccelModifier), forKey: SettingsKey.scrollAccelKey)
        userDefaults.set(Int(bitPattern: settings.scrollShiftModifier), forKey: SettingsKey.scrollShiftKey)
        userDefaults.set(Int(bitPattern: settings.scrollDisableModifier), forKey: SettingsKey.scrollDisableKey)
    }

    private static func restore(_ values: [(String, Any?)], to userDefaults: UserDefaults) {
        for (key, value) in values {
            if let value {
                userDefaults.set(value, forKey: key)
            } else {
                userDefaults.removeObject(forKey: key)
            }
        }
    }
}
