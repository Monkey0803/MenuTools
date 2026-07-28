import AppKit
import Carbon.HIToolbox

/// 全局快捷键管理：用 Carbon RegisterEventHotKey 注册系统级热键，
/// 触发时执行对应 ShortcutAction。绑定持久化于 UserDefaults。
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    /// action.rawValue -> 组合
    @Published private(set) var bindings: [String: KeyCombo]

    private static let storeKey = "shortcutBindings"

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: ShortcutAction] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            bindings = decoded
        } else {
            bindings = [:]
        }
    }

    /// App 启动时调用：安装事件处理并注册已保存的热键
    func activate() {
        installHandlerIfNeeded()
        for (raw, combo) in bindings {
            if let action = ShortcutAction(rawValue: raw) {
                registerHotKey(action, combo)
            }
        }
    }

    func combo(for action: ShortcutAction) -> KeyCombo? {
        bindings[action.rawValue]
    }

    /// 设置（或以 nil 清除）某动作的快捷键
    func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        unregisterHotKey(for: action)
        if let combo {
            bindings[action.rawValue] = combo
            installHandlerIfNeeded()
            registerHotKey(action, combo)
        } else {
            bindings.removeValue(forKey: action.rawValue)
        }
        persist()
    }

    // MARK: - Carbon 注册

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async {
                ShortcutManager.shared.handleHotKey(id: id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func registerHotKey(_ action: ShortcutAction, _ combo: KeyCombo) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4D544c53), id: id) // 'MTLS'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            idToAction[id] = action
        }
    }

    private func unregisterHotKey(for action: ShortcutAction) {
        guard let id = idToAction.first(where: { $0.value == action })?.key else { return }
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeValue(forKey: id)
        idToAction.removeValue(forKey: id)
    }

    private func handleHotKey(id: UInt32) {
        idToAction[id]?.perform()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
