import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Observation

private let clipboardCarbonHotKeySignature = OSType(0x4D54434C)

enum ClipboardShortcutCatalog {
    static func matches(
        keyCode: UInt16,
        modifiers: UInt,
        binding: GlobalShortcut?
    ) -> Bool {
        binding?.keyCode == keyCode && binding?.modifiers == modifiers
    }
}

struct ClipboardShortcutEventGate {
    private(set) var lastEvent: (keyCode: UInt16, modifiers: UInt, timestamp: TimeInterval)?

    mutating func accept(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool
    ) -> Bool {
        guard !isARepeat else { return false }
        defer { lastEvent = (keyCode, modifiers, timestamp) }
        guard let lastEvent else { return true }
        guard lastEvent.keyCode == keyCode,
              lastEvent.modifiers == modifiers else {
            return true
        }
        return timestamp - lastEvent.timestamp > 0.35
    }

    mutating func reset() {
        lastEvent = nil
    }
}

enum ClipboardShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case windowConflict(WindowLayout)
    case windowPresetConflict(String)
    case windowManagementConflict
    case appConflict(String)
    case screenshotConflict
    case appVolumeConflict
    case translationConflict

    var errorDescription: String? {
        switch self {
        case .modifierRequired:
            return L("shortcut.error.modifierRequired")
        case .systemConflict:
            return L("shortcut.error.systemConflict")
        case .otherApplicationConflict:
            return L("shortcut.error.otherApplicationConflict")
        case let .sceneConflict(scene):
            return L("shortcut.error.conflict", L(scene.titleKey))
        case let .windowConflict(layout):
            return L("shortcut.error.conflict", L(layout.titleKey))
        case let .windowPresetConflict(name):
            return L("shortcut.error.windowPresetConflict", name)
        case .windowManagementConflict:
            return L("shortcut.error.conflict", L("window.title"))
        case let .appConflict(path):
            return L(
                "shortcut.error.conflict",
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        case .screenshotConflict:
            return L("shortcut.error.screenshotConflict")
        case .appVolumeConflict:
            return L("shortcut.error.conflict", L("settings.tab.volume"))
        case .translationConflict:
            return L("shortcut.error.conflict", L("settings.tab.translation"))
        }
    }
}

enum ClipboardShortcutRegistrationMode: Equatable, Sendable, CaseIterable {
    case disabled
    case carbonExclusive
    case monitorFallback

    var localizationKey: String {
        switch self {
        case .disabled: return "clipboard.shortcut.status.disabled"
        case .carbonExclusive: return "clipboard.shortcut.status.exclusive"
        case .monitorFallback: return "clipboard.shortcut.status.fallback"
        }
    }
}

/// 剪贴板历史的全局快捷键，插件停用时不会保留事件监听。
@MainActor
@Observable
final class ClipboardShortcutService {
    static let shared = ClipboardShortcutService()

    private static let bindingKey = "clipboardShortcut.binding"

    private(set) var binding: GlobalShortcut?
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    private(set) var registrationMode: ClipboardShortcutRegistrationMode = .disabled
    private(set) var registrationStatus: OSStatus = noErr

    private let defaults: UserDefaults
    private let conflictChecker: any ShortcutConflictChecking
    private let sceneBindingsProvider: @MainActor () -> [ScenePreset: GlobalShortcut]
    private let windowBindingsProvider: @MainActor () -> [WindowLayout: GlobalShortcut]
    private let appBindingsProvider: @MainActor () -> [String: GlobalShortcut]
    private let screenshotBindingsProvider: @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut]
    private let appVolumeBindingProvider: @MainActor () -> GlobalShortcut?
    private let onTrigger: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private var eventGate = ClipboardShortcutEventGate()

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings },
        windowBindingsProvider: @escaping @MainActor () -> [WindowLayout: GlobalShortcut] = { WindowShortcutService.shared.bindings },
        appBindingsProvider: @escaping @MainActor () -> [String: GlobalShortcut] = { AppShortcutService.shared.bindings },
        screenshotBindingsProvider: @escaping @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut] = { ScreenshotShortcutService.shared.bindings },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding },
        onTrigger: @escaping @MainActor () -> Void = { MenuBarStatusItemController.shared.showClipboardHistory() }
    ) {
        self.defaults = defaults
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
        self.windowBindingsProvider = windowBindingsProvider
        self.appBindingsProvider = appBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.appVolumeBindingProvider = appVolumeBindingProvider
        self.onTrigger = onTrigger
        binding = Self.loadBinding(from: defaults)
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil && carbonHotKey == nil else { return }
        isAccessibilityTrusted = AXIsProcessTrusted()
        if registerCarbonHotKey() {
            registrationMode = .carbonExclusive
            isRunning = true
            return
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            let timestamp = event.timestamp
            let isARepeat = event.isARepeat
            Task { @MainActor [weak self] in
                self?.handle(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    timestamp: timestamp,
                    isARepeat: isARepeat
                )
            }
        }
        let localBinding = binding
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            let timestamp = event.timestamp
            let isARepeat = event.isARepeat
            Task { @MainActor [weak self] in
                self?.handle(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    timestamp: timestamp,
                    isARepeat: isARepeat
                )
            }
            // 本地事件必须被消费，否则 Ctrl/Option+V 会在目标输入框中留下控制字符，
            // 随后自动粘贴又会追加一次真实内容。
            return ClipboardShortcutCatalog.matches(
                keyCode: keyCode,
                modifiers: modifiers,
                binding: localBinding
            ) ? nil : event
        }
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: clipboardShortcutEventTapCallback,
            userInfo: nil
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            eventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        isRunning = globalMonitor != nil || localMonitor != nil
        registrationMode = isRunning ? .monitorFallback : .disabled
    }

    func stop() {
        if let carbonHotKey { UnregisterEventHotKey(carbonHotKey) }
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHotKey = nil
        carbonHandler = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
        eventGate.reset()
        isRunning = false
        registrationMode = .disabled
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    private func registerCarbonHotKey() -> Bool {
        guard let binding else { return false }
        let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(
            GetEventDispatcherTarget(),
            clipboardCarbonHotKeyHandler,
            1,
            [eventType],
            nil,
            &carbonHandler
        ) == noErr else { return false }
        let hotKeyID = EventHotKeyID(signature: clipboardCarbonHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            ShortcutModifierMapper.carbonModifiers(for: binding),
            hotKeyID,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &carbonHotKey
        )
        registrationStatus = status
        NSLog("[ClipboardShortcut] Carbon RegisterEventHotKey status=%d keyCode=%u modifiers=%u", status, binding.keyCode, ShortcutModifierMapper.carbonModifiers(for: binding))
        guard status == noErr else {
            if let carbonHandler { RemoveEventHandler(carbonHandler) }
            carbonHandler = nil
            return false
        }
        return true
    }

    func setBinding(_ newBinding: GlobalShortcut) throws {
        guard newBinding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw ClipboardShortcutError.modifierRequired
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: binding,
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: true,
            excludingAppVolume: false
        )
        switch conflictChecker.conflict(for: newBinding, context: context) {
        case .system:
            throw ClipboardShortcutError.systemConflict
        case .otherApplication:
            throw ClipboardShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw ClipboardShortcutError.sceneConflict(scene)
        case let .window(layout):
            throw ClipboardShortcutError.windowConflict(layout)
        case let .windowPreset(name):
            throw ClipboardShortcutError.windowPresetConflict(name)
        case .windowManagement:
            throw ClipboardShortcutError.windowManagementConflict
        case let .app(path):
            throw ClipboardShortcutError.appConflict(path)
        case .screenshot:
            throw ClipboardShortcutError.screenshotConflict
        case .appVolume:
            throw ClipboardShortcutError.appVolumeConflict
        case .translation:
            throw ClipboardShortcutError.translationConflict
        case .clipboard, nil:
            break
        }
        binding = newBinding
        lastError = nil
        saveBinding()
        restartRegistration()
    }

    func clearBinding() {
        binding = nil
        lastError = nil
        defaults.removeObject(forKey: Self.bindingKey)
        restartRegistration()
    }

    private func restartRegistration() {
        guard isRunning else { return }
        stop()
        start()
    }

    fileprivate func handle(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool
    ) {
        guard ClipboardShortcutCatalog.matches(keyCode: keyCode, modifiers: modifiers, binding: binding) else {
            return
        }
        guard eventGate.accept(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isARepeat: isARepeat
        ) else { return }
        onTrigger()
    }

    private func saveBinding() {
        guard let binding, let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: Self.bindingKey)
    }

    private static func loadBinding(from defaults: UserDefaults) -> GlobalShortcut? {
        guard let data = defaults.data(forKey: bindingKey) else { return nil }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }
}

private func clipboardShortcutEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let defaults = UserDefaults.standard
    let binding: GlobalShortcut? = defaults.data(forKey: "clipboardShortcut.binding")
        .flatMap { try? JSONDecoder().decode(GlobalShortcut.self, from: $0) }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = GlobalShortcutCatalog.normalizedModifiers(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
    guard ClipboardShortcutCatalog.matches(keyCode: keyCode, modifiers: modifiers, binding: binding) else {
        return Unmanaged.passUnretained(event)
    }
    let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
    let isARepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    Task { @MainActor in
        ClipboardShortcutService.shared.handle(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isARepeat: isARepeat
        )
    }
    return nil
}

private func clipboardCarbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == clipboardCarbonHotKeySignature,
          hotKeyID.id == 1 else { return noErr }
    Task { @MainActor in
        guard let binding = ClipboardShortcutService.shared.binding else { return }
        ClipboardShortcutService.shared.handle(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers,
            timestamp: Date().timeIntervalSince1970,
            isARepeat: false
        )
    }
    return noErr
}
