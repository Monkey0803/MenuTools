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
