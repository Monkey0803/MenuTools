import Foundation
import Testing
@testable import MenuTools

@MainActor
private struct ClipboardShortcutConflictChecker: ShortcutConflictChecking {
    func conflict(
        for shortcut: GlobalShortcut,
        context: ShortcutConflictContext
    ) -> ShortcutConflictSource? {
        nil
    }
}

@Test("剪贴板快捷键可精确匹配")
func clipboardShortcutMatchesBinding() {
    let shortcut = GlobalShortcut(keyCode: 8, modifiers: GlobalShortcutModifier.controlOption)

    #expect(ClipboardShortcutCatalog.matches(
        keyCode: shortcut.keyCode,
        modifiers: shortcut.modifiers,
        binding: shortcut
    ))
    #expect(!ClipboardShortcutCatalog.matches(
        keyCode: 9,
        modifiers: shortcut.modifiers,
        binding: shortcut
    ))
}

@Test("简洁快捷键控件保留保存和清除条件")
func compactClipboardShortcutControlKeepsRequiredActions() {
    #expect(ClipboardShortcutControlPolicy.shouldShowSave(hasCapturedShortcut: true))
    #expect(!ClipboardShortcutControlPolicy.shouldShowSave(hasCapturedShortcut: false))
    #expect(ClipboardShortcutControlPolicy.shouldShowClear(hasBinding: true, isRecording: false))
    #expect(!ClipboardShortcutControlPolicy.shouldShowClear(hasBinding: false, isRecording: false))
    #expect(!ClipboardShortcutControlPolicy.shouldShowClear(hasBinding: true, isRecording: true))
}

@Test("剪贴板快捷键会持久化且可清除")
@MainActor
func clipboardShortcutPersistsAndClearsBinding() throws {
    let suiteName = "MenuTools-ClipboardShortcutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let shortcut = GlobalShortcut(keyCode: 8, modifiers: GlobalShortcutModifier.controlOption)
    let service = ClipboardShortcutService(
        defaults: defaults,
        conflictChecker: ClipboardShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        onTrigger: {}
    )

    try service.setBinding(shortcut)
    #expect(service.binding == shortcut)

    let restored = ClipboardShortcutService(
        defaults: defaults,
        conflictChecker: ClipboardShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        onTrigger: {}
    )
    #expect(restored.binding == shortcut)

    restored.clearBinding()
    #expect(restored.binding == nil)
}

@Test("剪贴板快捷键忽略自动重复和双监听重复事件")
func clipboardShortcutEventGatePreventsRepeatedPresentation() {
    var gate = ClipboardShortcutEventGate()

    let firstAccepted = gate.accept(
        keyCode: 8,
        modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1,
        isARepeat: false
    )
    let duplicateAccepted = gate.accept(
        keyCode: 8,
        modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1.1,
        isARepeat: false
    )
    let repeatAccepted = gate.accept(
        keyCode: 8,
        modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1.5,
        isARepeat: true
    )

    #expect(firstAccepted)
    #expect(!duplicateAccepted)
    #expect(!repeatAccepted)
}

@Test("剪贴板快捷键拒绝与音量快捷键冲突")
@MainActor
func clipboardShortcutRejectsAppVolumeBinding() {
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = ClipboardShortcutService(
        conflictChecker: DefaultShortcutConflictChecker(
            systemProvider: ClipboardShortcutSystemProvider(),
            externalProbe: ClipboardShortcutExternalProbe()
        ),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        appVolumeBindingProvider: { shortcut },
        onTrigger: {}
    )

    #expect(throws: ClipboardShortcutError.appVolumeConflict) {
        try service.setBinding(shortcut)
    }
}

@MainActor
private struct ClipboardShortcutSystemProvider: SystemShortcutProviding {
    func contains(_ shortcut: GlobalShortcut) -> Bool { false }
}

@MainActor
private struct ClipboardShortcutExternalProbe: ExternalShortcutProbing {
    func contains(_ shortcut: GlobalShortcut) -> Bool { false }
}
