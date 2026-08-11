import AppKit
import Carbon
import Foundation

/// 快捷键冲突来源。
enum ShortcutConflictSource: Equatable, Sendable {
    case system
    case otherApplication
    case scene(ScenePreset)
    case window(WindowLayout)
}

struct ShortcutConflictContext: Sendable {
    let sceneBindings: [ScenePreset: GlobalShortcut]
    let windowBindings: [WindowLayout: GlobalShortcut]
    let excludingScene: ScenePreset?
    let excludingWindow: WindowLayout?
}

/// 快捷键冲突检测边界，便于测试时替换系统能力。
@MainActor
protocol ShortcutConflictChecking {
    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource?
}

@MainActor
protocol SystemShortcutProviding {
    func contains(_ shortcut: GlobalShortcut) -> Bool
}

@MainActor
protocol ExternalShortcutProbing {
    func contains(_ shortcut: GlobalShortcut) -> Bool
}

/// 在 Cocoa 修饰键和 Carbon 修饰键之间转换。
enum ShortcutModifierMapper {
    static func carbonModifiers(for shortcut: GlobalShortcut) -> UInt32 {
        let modifiers = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func cocoaModifiers(from carbonModifiers: UInt32) -> UInt {
        var result: UInt = 0
        if carbonModifiers & UInt32(cmdKey) != 0 { result |= NSEvent.ModifierFlags.command.rawValue }
        if carbonModifiers & UInt32(optionKey) != 0 { result |= NSEvent.ModifierFlags.option.rawValue }
        if carbonModifiers & UInt32(controlKey) != 0 { result |= NSEvent.ModifierFlags.control.rawValue }
        if carbonModifiers & UInt32(shiftKey) != 0 { result |= NSEvent.ModifierFlags.shift.rawValue }
        return result
    }
}

/// 系统设置中已启用的 symbolic hot keys。
@MainActor
struct DefaultSystemShortcutProvider: SystemShortcutProviding {
    func contains(_ shortcut: GlobalShortcut) -> Bool {
        var unmanagedArray: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanagedArray) == noErr,
              let unmanagedArray else { return false }

        let array = unmanagedArray.takeRetainedValue() as [AnyObject]
        let codeKey = kHISymbolicHotKeyCode as String
        let modifiersKey = kHISymbolicHotKeyModifiers as String
        let enabledKey = kHISymbolicHotKeyEnabled as String

        return array.contains { object in
            guard let dictionary = object as? NSDictionary,
                  let enabled = dictionary[enabledKey] as? NSNumber,
                  enabled.boolValue,
                  let code = dictionary[codeKey] as? NSNumber,
                  let modifiers = dictionary[modifiersKey] as? NSNumber else { return false }
            return UInt16(truncating: code) == shortcut.keyCode
                && ShortcutModifierMapper.cocoaModifiers(from: modifiers.uint32Value) == shortcut.modifiers
        }
    }
}

/// 使用 Carbon 独占注册探测其他进程已注册的全局热键。
///
/// 探测成功后立即注销，不会占用用户的快捷键。Carbon 只能确认其他进程通过
/// RegisterEventHotKey 注册的热键；使用私有事件监听器的应用无法被公开 API 完整枚举。
@MainActor
struct DefaultExternalShortcutProbe: ExternalShortcutProbing {
    private static let signature = OSType(0x4D544F4F) // MTOO

    func contains(_ shortcut: GlobalShortcut) -> Bool {
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: UInt32(shortcut.keyCode))
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            ShortcutModifierMapper.carbonModifiers(for: shortcut),
            id,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        if let reference {
            _ = UnregisterEventHotKey(reference)
        }
        return status == eventHotKeyExistsErr
    }
}

@MainActor
struct DefaultShortcutConflictChecker: ShortcutConflictChecking {
    private let systemProvider: any SystemShortcutProviding
    private let externalProbe: any ExternalShortcutProbing

    init(
        systemProvider: any SystemShortcutProviding = DefaultSystemShortcutProvider(),
        externalProbe: any ExternalShortcutProbing = DefaultExternalShortcutProbe()
    ) {
        self.systemProvider = systemProvider
        self.externalProbe = externalProbe
    }

    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource? {
        if let conflict = context.sceneBindings.first(where: {
            $0.key != context.excludingScene && $0.value == shortcut
        })?.key {
            return .scene(conflict)
        }
        if let conflict = context.windowBindings.first(where: {
            $0.key != context.excludingWindow && $0.value == shortcut
        })?.key {
            return .window(conflict)
        }
        if systemProvider.contains(shortcut) { return .system }
        if externalProbe.contains(shortcut) { return .otherApplication }
        return nil
    }
}

/// MenuTools 内部场景快捷键与窗口快捷键的交叉冲突检测。
enum ShortcutBindingConflictCatalog {
    static func windowConflict(
        for shortcut: GlobalShortcut,
        in bindings: [WindowLayout: GlobalShortcut]
    ) -> WindowLayout? {
        bindings.first { $0.value == shortcut }?.key
    }

    static func sceneConflict(
        for shortcut: GlobalShortcut,
        in bindings: [ScenePreset: GlobalShortcut]
    ) -> ScenePreset? {
        bindings.first { $0.value == shortcut }?.key
    }
}
