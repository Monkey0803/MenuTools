import AppKit
import Testing
@testable import MenuTools

@Test("HUD 显示反馈后会自动隐藏")
@MainActor
func feedbackHUDShowsThenAutoHides() async throws {
    let controller = ClipboardFeedbackHUDController(dismissInterval: 0.05)
    #expect(!controller.isPresenting)
    #expect(controller.presentedFeedback == nil)

    controller.show(.pasteFailed)

    #expect(controller.isPresenting)
    #expect(controller.presentedFeedback == .pasteFailed)

    var waited = 0
    while controller.isPresenting, waited < 100 {
        try await Task.sleep(for: .milliseconds(20))
        waited += 1
    }

    #expect(!controller.isPresenting)
    #expect(controller.presentedFeedback == nil)
}

@Test("连续展示会以最后一次反馈为准并延长隐藏时间")
@MainActor
func feedbackHUDRestartsDismissCountdown() async throws {
    let controller = ClipboardFeedbackHUDController(dismissInterval: 0.2)
    controller.show(.copied)

    try await Task.sleep(for: .milliseconds(120))
    controller.show(.clipboardCleared)

    // 第二次展示后仍是可见状态，且内容已更新。
    #expect(controller.isPresenting)
    #expect(controller.presentedFeedback == .clipboardCleared)

    var waited = 0
    while controller.isPresenting, waited < 100 {
        try await Task.sleep(for: .milliseconds(20))
        waited += 1
    }
    #expect(!controller.isPresenting)
}

@Test("HUD 可以展示任意文案，例如快捷键失败的原因")
@MainActor
func feedbackHUDPresentsArbitraryMessage() async throws {
    let controller = ClipboardFeedbackHUDController(dismissInterval: 0.05)

    controller.show(message: "截图失败：需要屏幕录制权限", isSuccess: false)

    #expect(controller.isPresenting)
    #expect(controller.presentedMessage?.text == "截图失败：需要屏幕录制权限")
    #expect(controller.presentedMessage?.isSuccess == false)
    // 任意文案路径不记录剪贴板反馈，避免两套状态互相污染。
    #expect(controller.presentedFeedback == nil)

    var waited = 0
    while controller.isPresenting, waited < 100 {
        try await Task.sleep(for: .milliseconds(20))
        waited += 1
    }
    #expect(!controller.isPresenting)
    #expect(controller.presentedMessage == nil)
}

@Test("剪贴板反馈也会写入统一的展示内容")
@MainActor
func feedbackHUDPublishesUnifiedMessage() {
    let controller = ClipboardFeedbackHUDController(dismissInterval: 5)

    controller.show(.pasteFailed)

    #expect(controller.presentedMessage?.isSuccess == false)
    #expect(controller.presentedMessage?.text == L("clipboard.feedback.pasteFailed"))
    #expect(controller.presentedFeedback == .pasteFailed)
}
